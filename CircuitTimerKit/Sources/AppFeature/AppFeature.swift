import ComposableArchitecture
import Foundation
import os
import SettingsFeature
import WorkoutDomain
import WorkoutEditorFeature
import WorkoutStorage

@Reducer
public struct AppFeature: Sendable {
    @Reducer
    public enum Destination {
        case editor(WorkoutEditorFeature)
        case alert(AlertState<Never>)
    }

    /// A list change waiting to be written. Writes run one at a time, in the order the user made them.
    enum ListMutation: Equatable, Sendable {
        case delete(Workout.ID)
        case insert(Workout, after: Workout.ID)
        case reorder([Workout.ID])
    }

    /// An editor the user asked for while the list was being written or reloaded.
    enum DeferredEditor: Equatable, Sendable {
        case create
        case edit(Workout.ID)
    }

    public enum RootTab: Hashable, Sendable {
        case workouts
        case settings
    }

    @ObservableState
    public struct State: Equatable, Sendable {
        public var selectedTab: RootTab = .workouts
        public var settings = SettingsFeature.State()
        public var workouts: Content = .idle
        /// Stored records the list cannot show: unreadable workouts and extra copies of shown ones.
        public var hiddenRecordCount = 0
        @Presents public var destination: Destination.State?
        var pendingMutations: [ListMutation] = []
        /// Set when a write reports that storage no longer matches the list; reload once the queue drains.
        var needsReload = false
        var deferredEditor: DeferredEditor?

        public init() {}

        public var canAddWorkout: Bool {
            if case .loaded = workouts { true } else { false }
        }
    }

    public enum Content: Equatable, Sendable {
        case idle
        case loading
        case loaded(IdentifiedArrayOf<Workout>)
        case failed
    }

    public enum Action: ViewAction, Equatable, Sendable {
        case view(View)
        case `internal`(Internal)
        case destination(PresentationAction<Destination.Action>)
        case settings(SettingsFeature.Action)

        @CasePathable
        public enum View: Equatable, Sendable {
            case task
            case tabSelected(RootTab)
            case retryButtonTapped
            case addButtonTapped
            case workoutTapped(Workout.ID)
            case deleteButtonTapped(Workout.ID)
            case duplicateButtonTapped(Workout.ID)
            case workoutsMoved(IndexSet, Int)
            case workoutMovedUp(Workout.ID)
            case workoutMovedDown(Workout.ID)
        }

        @CasePathable
        public enum Internal: Equatable, Sendable {
            case workoutsLoaded(StoredWorkouts)
            case workoutsLoadingFailed
            case mutationFinished(WorkoutWriteOutcome)
            case mutationFailed
        }
    }

    private enum CancelID {
        case load
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "AppFeature")

    @Dependency(\.uuid) private var uuid
    @Dependency(\.workoutStorage) private var workoutStorage

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(\.settings, action: \.settings) {
            SettingsFeature()
        }
        Reduce { state, action in
            switch action {
                case let .view(action):
                    reduce(into: &state, action)
                case let .internal(action):
                    reduce(into: &state, action)
                case let .destination(.presented(.editor(.delegate(.saved(workout))))):
                    workoutSaved(workout, &state)
                case .destination, .settings:
                    .none
            }
        }
        .ifLet(\.$destination, action: \.destination)
    }

    private func reduce(into state: inout State, _ action: Action.View) -> Effect<Action> {
        switch action {
            case .task:
                guard state.workouts == .idle else { return .none }

                return loadWorkouts(&state)
            case let .tabSelected(tab):
                guard tab != state.selectedTab else {
                    // A tap on the selected tab returns it to its root.
                    switch tab {
                        case .workouts:
                            // The list pushes no screens yet.
                            break
                        case .settings:
                            state.settings.popToRoot()
                    }
                    return .none
                }

                state.selectedTab = tab
                // An editor requested on the list must not open over another tab once the write finishes.
                state.deferredEditor = nil
                return .none
            case .retryButtonTapped:
                return loadWorkouts(&state)
            case .addButtonTapped:
                return openEditor(.create, &state)
            case let .workoutTapped(id):
                return openEditor(.edit(id), &state)
            case let .deleteButtonTapped(id):
                guard case var .loaded(workouts) = state.workouts, workouts.remove(id: id) != nil else { return .none }

                state.workouts = .loaded(workouts)
                if state.deferredEditor == .edit(id) {
                    state.deferredEditor = nil
                }
                return enqueue(.delete(id), &state)
            case let .duplicateButtonTapped(id):
                guard
                    case var .loaded(workouts) = state.workouts,
                    let index = workouts.index(id: id)
                else { return .none }

                let copy = duplicate(workouts[index])
                workouts.insert(copy, at: index + 1)
                state.workouts = .loaded(workouts)
                return enqueue(.insert(copy, after: id), &state)
            case let .workoutsMoved(source, destination):
                guard case var .loaded(workouts) = state.workouts else { return .none }

                let order = workouts.ids
                workouts.move(fromOffsets: source, toOffset: destination)
                // A drop in place still reports a move; there is nothing to write.
                guard workouts.ids != order else { return .none }

                return reorder(workouts, &state)
            case let .workoutMovedUp(id):
                guard
                    case var .loaded(workouts) = state.workouts,
                    let index = workouts.indexMovableUp(id)
                else { return .none }

                workouts.swapAt(index, index - 1)
                return reorder(workouts, &state)
            case let .workoutMovedDown(id):
                guard
                    case var .loaded(workouts) = state.workouts,
                    let index = workouts.indexMovableDown(id)
                else { return .none }

                workouts.swapAt(index, index + 1)
                return reorder(workouts, &state)
        }
    }

    private func reduce(into state: inout State, _ action: Action.Internal) -> Effect<Action> {
        switch action {
            case let .workoutsLoaded(stored):
                // Storage already returns unique identifiers; uniquing keeps a contract slip from crashing the list.
                state.workouts = .loaded(IdentifiedArray(stored.workouts, uniquingIDsWith: { first, _ in first }))
                state.hiddenRecordCount = stored.hiddenRecordCount
                return presentDeferredEditor(&state)
            case .workoutsLoadingFailed:
                state.workouts = .failed
                state.deferredEditor = nil
                return .none
            case let .mutationFinished(outcome):
                if outcome == .storeDiverged {
                    state.needsReload = true
                }
                if !state.pendingMutations.isEmpty {
                    state.pendingMutations.removeFirst()
                }
                if let next = state.pendingMutations.first {
                    return write(next)
                }
                if state.needsReload {
                    // The reload presents a deferred editor once the list is current.
                    state.needsReload = false
                    return loadWorkouts(&state)
                }
                return presentDeferredEditor(&state)
            case .mutationFailed:
                // Later writes were derived from a list that storage did not accept; drop them and resync.
                state.pendingMutations = []
                state.needsReload = false
                state.deferredEditor = nil
                state.destination = .alert(.mutationFailed)
                return loadWorkouts(&state)
        }
    }

    /// Opens the editor now, or once pending writes and reloads are done so it never shows a stale list.
    private func openEditor(_ request: DeferredEditor, _ state: inout State) -> Effect<Action> {
        state.deferredEditor = request
        guard state.pendingMutations.isEmpty, case .loaded = state.workouts else { return .none }

        return presentDeferredEditor(&state)
    }

    private func presentDeferredEditor(_ state: inout State) -> Effect<Action> {
        guard let request = state.deferredEditor else { return .none }

        // A request that cannot open now is dropped rather than kept for a surprise later.
        state.deferredEditor = nil
        guard state.destination == nil else { return .none }

        switch request {
            case .create:
                state.destination = .editor(WorkoutEditorFeature.State(newWorkoutID: uuid(), firstStageID: uuid()))
            case let .edit(id):
                // The workout may be gone by now; then there is nothing to edit.
                guard case let .loaded(workouts) = state.workouts, let workout = workouts[id: id] else { return .none }

                state.destination = .editor(WorkoutEditorFeature.State(editing: workout))
        }
        return .none
    }

    private func reorder(_ workouts: IdentifiedArrayOf<Workout>, _ state: inout State) -> Effect<Action> {
        state.workouts = .loaded(workouts)
        return enqueue(.reorder(Array(workouts.ids)), &state)
    }

    private func enqueue(_ mutation: ListMutation, _ state: inout State) -> Effect<Action> {
        state.pendingMutations.append(mutation)
        guard state.pendingMutations.count == 1 else { return .none }

        return write(mutation)
    }

    private func write(_ mutation: ListMutation) -> Effect<Action> {
        .run { [workoutStorage] send in
            do {
                let outcome = switch mutation {
                    case let .delete(id): try await workoutStorage.delete(id: id)
                    case let .insert(workout, anchor): try await workoutStorage.insert(workout: workout, after: anchor)
                    case let .reorder(ids): try await workoutStorage.reorder(ids: ids)
                }
                await send(.internal(.mutationFinished(outcome)))
            } catch is CancellationError {
                // Only the root store going away cancels a write, and the queue goes with it.
                return
            } catch {
                Self.logger.error("Failed to write a list change: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.mutationFailed))
            }
        }
    }

    private func duplicate(_ workout: Workout) -> Workout {
        var copy = Workout(id: uuid(), name: String(localized: "workouts.duplicate.name \(workout.displayName)", bundle: .module))
        copy.trainingRounds = workout.trainingRounds
        copy.pauseAfterWarmUp = workout.pauseAfterWarmUp
        copy.pauseAfterTraining = workout.pauseAfterTraining
        for section in WorkoutSectionKind.allCases {
            copy[section] = workout[section].map { stage in
                Stage(id: uuid(), name: stage.name, duration: stage.duration, intensity: stage.intensity)
            }
        }
        return copy
    }

    /// Storage appends a new workout, so a new one goes to the end here too.
    private func workoutSaved(_ workout: Workout, _ state: inout State) -> Effect<Action> {
        guard case var .loaded(workouts) = state.workouts else { return loadWorkouts(&state) }

        workouts[id: workout.id] = workout
        state.workouts = .loaded(workouts)
        return .none
    }

    private func loadWorkouts(_ state: inout State) -> Effect<Action> {
        state.workouts = .loading
        return .run { [workoutStorage] send in
            do {
                let stored = try await workoutStorage.fetchAll()
                await send(.internal(.workoutsLoaded(stored)))
            } catch is CancellationError {
                // Superseded by a newer load; not a failure.
                return
            } catch {
                Self.logger.error("Failed to load workouts: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.workoutsLoadingFailed))
            }
        }
        .cancellable(id: CancelID.load, cancelInFlight: true)
    }
}

extension AppFeature.Destination.State: Equatable, Sendable {}
extension AppFeature.Destination.Action: Equatable, Sendable {}

extension AlertState where Action == Never {
    static var mutationFailed: Self {
        AlertState {
            TextState("workouts.mutationFailed.title", bundle: .module)
        }
    }
}

/// One edge rule for the reducer and the rows' VoiceOver move actions:
/// the index of `id` when it can move one place, otherwise `nil`.
extension IdentifiedArray {
    func indexMovableUp(_ id: ID) -> Int? {
        guard let index = index(id: id), index > startIndex else { return nil }

        return index
    }

    func indexMovableDown(_ id: ID) -> Int? {
        guard let index = index(id: id), index < endIndex - 1 else { return nil }

        return index
    }
}
