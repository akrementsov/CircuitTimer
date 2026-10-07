import ComposableArchitecture
import Foundation
import os
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

    @ObservableState
    public struct State: Equatable, Sendable {
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

        @CasePathable
        public enum View: Equatable, Sendable {
            case task
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
        Reduce { state, action in
            switch action {
                case let .view(action):
                    reduce(into: &state, action)
                case let .internal(action):
                    reduce(into: &state, action)
                case let .destination(.presented(.editor(.delegate(.saved(workout))))):
                    workoutSaved(workout, &state)
                case .destination:
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
                return move(source, to: destination, &state)
            case let .workoutMovedUp(id):
                guard
                    case let .loaded(workouts) = state.workouts,
                    workouts.canMoveUp(id),
                    let index = workouts.index(id: id)
                else { return .none }

                return move(IndexSet(integer: index), to: index - 1, &state)
            case let .workoutMovedDown(id):
                guard
                    case let .loaded(workouts) = state.workouts,
                    workouts.canMoveDown(id),
                    let index = workouts.index(id: id)
                else { return .none }

                // `move(fromOffsets:toOffset:)` counts the destination before removal.
                return move(IndexSet(integer: index), to: index + 2, &state)
        }
    }

    private func move(_ source: IndexSet, to destination: Int, _ state: inout State) -> Effect<Action> {
        guard case var .loaded(workouts) = state.workouts else { return .none }

        workouts.move(fromOffsets: source, toOffset: destination)
        state.workouts = .loaded(workouts)
        return enqueue(.reorder(Array(workouts.ids)), &state)
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
        var copy = Workout(id: uuid(), name: String(localized: "workouts.duplicate.name \(workout.name)", bundle: .module))
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

extension IdentifiedArray where Element == Workout, ID == Workout.ID {
    /// The list and VoiceOver's move actions share one edge rule.
    func canMoveUp(_ id: Workout.ID) -> Bool {
        guard let index = index(id: id) else { return false }

        return index > startIndex
    }

    func canMoveDown(_ id: Workout.ID) -> Bool {
        guard let index = index(id: id) else { return false }

        return index < endIndex - 1
    }
}
