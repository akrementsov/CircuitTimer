import BackgroundExecution
import ComposableArchitecture
import Foundation
import os
import SettingsFeature
import WorkoutDomain
import WorkoutEditorFeature
import WorkoutStorage
import WorkoutTimerFeature

@Reducer
public struct AppFeature: Sendable {
    // An alert with actions needs a hand-written `Action`: with a macro-generated one the scoped
    // binding would drop the user's choice. See AGENTS.md › TCA.
    @Reducer
    public enum Destination {
        @ReducerCaseIgnored
        case alert(AlertState<Never>)
        @ReducerCaseIgnored
        case resumeRun(AlertState<ResumeRunChoice>)
        case timer(WorkoutTimerFeature)

        @CasePathable
        public enum Action: Equatable, Sendable {
            case alert(Never)
            case resumeRun(ResumeRunChoice)
            case timer(WorkoutTimerFeature.Action)
        }
    }

    public enum ResumeRunChoice: Equatable, Sendable {
        case resume
        case finish
    }

    /// Screens pushed onto the Workouts stack.
    @Reducer
    public enum Path {
        case editor(WorkoutEditorFeature)
    }

    /// A list change waiting to be written. Writes run one at a time, in the order the user made them.
    enum ListMutation: Equatable, Sendable {
        case delete(Workout.ID)
        case insert(Workout, after: Workout.ID)
        case reorder([Workout.ID])
    }

    /// A screen the user asked for while the list was being written or reloaded.
    enum DeferredScreen: Equatable, Sendable {
        case create
        /// Opens the workout's screen, read-only.
        case open(Workout.ID)
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
        public internal(set) var path = StackState<Path.State>()
        var pendingMutations: [ListMutation] = []
        /// Set when a write reports that storage no longer matches the list; reload once the queue drains.
        var needsReload = false
        /// A reload of a list that stays on screen meanwhile.
        var isReloading = false
        var deferredScreen: DeferredScreen?
        /// The launch's check for a run saved before the process was gone.
        var runRestore = RunRestore.idle
        /// Set once the timer's cover is on screen; a dismissal before that comes from the alert it replaced.
        var isTimerCoverUp = false

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
        case path(StackActionOf<Path>)
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
            case timerCoverAppeared
        }

        @CasePathable
        public enum Internal: Equatable, Sendable {
            case workoutsLoaded(StoredWorkouts)
            case workoutsLoadingFailed
            case mutationFinished(WorkoutWriteOutcome)
            case mutationFailed
            case runRecordLoaded(StoredRunRecord?)
            case runRecordLoadingFailed(RunRecordLoadFailure)
            case runRecordReadTimedOut
            /// Sent after the resume alert has gone, so the timer's cover never overlaps it.
            case resumeRunConfirmed
            case runFinishFailed
            case timerPresentationFailed
        }
    }

    enum CancelID {
        case load
        case readRunRecord
        case readRunRecordTimeout
    }

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "AppFeature")

    @Dependency(\.backgroundTask) var backgroundTask
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date) var date
    @Dependency(\.timerSession) private var timerSession
    @Dependency(\.uuid) private var uuid
    @Dependency(\.workoutRunRecord) var workoutRunRecord
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
                case let .path(.element(id: _, action: .editor(.delegate(.saved(workout))))):
                    workoutSaved(workout, &state)
                case let .path(.element(id: _, action: .editor(.delegate(.startRequested(workout))))):
                    startWorkout(workout, &state)
                case let .destination(.presented(.resumeRun(choice))):
                    resumeRunChosen(choice, &state)
                case .destination(.dismiss):
                    destinationDismissed(&state)
                case .destination, .path, .settings:
                    .none
            }
        }
        .ifLet(\.$destination, action: \.destination)
        .forEach(\.path, action: \.path)
    }

    private func reduce(into state: inout State, _ action: Action.View) -> Effect<Action> {
        switch action {
            case .task:
                guard state.workouts == .idle else { return .none }

                // Read the saved run before loading the list, where a viable run is offered for continuation.
                state.workouts = .loading
                return readRunRecord(&state)
            case let .tabSelected(tab):
                if tab == state.selectedTab {
                    // A tap on the selected tab returns it to its root.
                    switch tab {
                        case .workouts:
                            // Only a read-only screen leaves, through its own Back. An editor may have a field focused
                            // whose last edit reaches the draft only through the view: a re-tap would drop that edit
                            // or leave without the discard dialog.
                            guard
                                let id = state.path.ids.last,
                                state.path[id: id, case: \.editor]?.phase == .viewing
                            else { return .none }

                            return .send(.path(.element(id: id, action: .editor(.view(.backButtonTapped)))))
                        case .settings:
                            state.settings.popToRoot()
                            return .none
                    }
                }

                state.selectedTab = tab
                // Leaving the list drops its pending screen request, so it does not open when the user comes back.
                state.deferredScreen = nil
                return .none
            case .retryButtonTapped:
                return loadWorkouts(&state)
            case .addButtonTapped:
                return openScreen(.create, &state)
            case let .workoutTapped(id):
                return openScreen(.open(id), &state)
            case let .deleteButtonTapped(id):
                guard case var .loaded(workouts) = state.workouts, workouts.remove(id: id) != nil else { return .none }

                state.workouts = .loaded(workouts)
                if state.deferredScreen == .open(id) {
                    state.deferredScreen = nil
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
            case .timerCoverAppeared:
                state.isTimerCoverUp = true
                // Under the cover, so the pop is not seen; closing the timer lands on the list.
                state.path.removeAll()
                return .none
        }
    }

    private func reduce(into state: inout State, _ action: Action.Internal) -> Effect<Action> {
        switch action {
            case let .workoutsLoaded(stored):
                state.isReloading = false
                // A write made on the shown list during the reload may be missing from what was read: read again once
                // the queue drains instead of dropping the write from the list.
                if !state.pendingMutations.isEmpty {
                    state.needsReload = true
                    return .none
                }
                // Defensive: the write that overtook this read normally cancels it with a newer load.
                if state.needsReload {
                    state.needsReload = false
                    return loadWorkouts(&state)
                }
                // Storage already returns unique identifiers; uniquing keeps a contract slip from crashing the list.
                state.workouts = .loaded(IdentifiedArray(stored.workouts, uniquingIDsWith: { first, _ in first }))
                state.hiddenRecordCount = stored.hiddenRecordCount
                // A continuation prompt takes precedence over any deferred screen.
                let restore = resolveRestore(&state)
                return .merge(restore, presentDeferredScreen(&state))
            case .workoutsLoadingFailed:
                state.isReloading = false
                state.workouts = .failed
                state.deferredScreen = nil
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
                    // The reload presents a deferred screen once the list is current.
                    state.needsReload = false
                    return loadWorkouts(&state)
                }
                // A reload still in flight presents it when it lands.
                return state.isReloading ? .none : presentDeferredScreen(&state)
            case .mutationFailed:
                // Later writes were derived from a list that storage did not accept; drop them and resync.
                state.pendingMutations = []
                state.needsReload = false
                state.deferredScreen = nil
                // A presented timer is never replaced: it would close without ending its session. No write starts under
                // the cover yet, so this guard is defensive; the reload still resyncs the list.
                if state.destination?.is(\.timer) != true {
                    state.destination = .alert(.mutationFailed)
                }
                return loadWorkouts(&state)
            case let .runRecordLoaded(stored):
                return runRecordLoaded(stored, &state)
            case let .runRecordLoadingFailed(failure):
                return runRecordLoadingFailed(failure, &state)
            case .runRecordReadTimedOut:
                return runRecordReadTimedOut(&state)
            case .resumeRunConfirmed:
                return resumeRunConfirmed(&state)
            case .timerPresentationFailed:
                if state.destination == nil {
                    state.destination = .alert(.timerNotPresented)
                }
                return .none
            case .runFinishFailed:
                // Shown only over the list; the run may be offered again at the next launch.
                if state.destination == nil {
                    state.destination = .alert(.runNotFinished)
                }
                return .none
        }
    }

    /// Opens the screen now, or once pending writes and reloads are done so it never shows a stale workout.
    private func openScreen(_ request: DeferredScreen, _ state: inout State) -> Effect<Action> {
        state.deferredScreen = request
        guard state.pendingMutations.isEmpty, !state.isReloading, case .loaded = state.workouts else { return .none }

        return presentDeferredScreen(&state)
    }

    private func presentDeferredScreen(_ state: inout State) -> Effect<Action> {
        guard let request = state.deferredScreen else { return .none }

        // A request that cannot open now is dropped rather than kept for a surprise later.
        state.deferredScreen = nil
        // An empty stack also drops a second tap made while the editor is being pushed, and an empty destination
        // one made while the timer is being presented.
        guard state.destination == nil, state.path.isEmpty, state.selectedTab == .workouts else { return .none }

        switch request {
            case .create:
                state.path.append(.editor(WorkoutEditorFeature.State(newWorkoutID: uuid(), firstStageID: uuid())))
            case let .open(id):
                // The workout may be gone by now; then there is nothing to show.
                guard case let .loaded(workouts) = state.workouts, let workout = workouts[id: id] else { return .none }

                state.path.append(.editor(WorkoutEditorFeature.State(viewing: workout)))
        }
        return .none
    }

    /// Presents the timer over the tab bar; the Workouts stack returns to the list once the cover is up.
    private func startWorkout(_ workout: Workout, _ state: inout State) -> Effect<Action> {
        // The workout's screen offers Start only for a playable workout and never under a presentation.
        guard state.destination == nil else {
            Self.logger.error("Refused to start a workout while something is presented")
            return .none
        }
        guard workout.isPlayable else {
            Self.logger.error("Refused to start a workout with nothing to play")
            return .none
        }
        state.destination = .timer(timerState(for: workout))
        return .none
    }

    // A timer's state is built only here and in `restoredTimerState`, so both get the same identifiers and title.

    private func timerState(for workout: Workout) -> WorkoutTimerFeature.State {
        WorkoutTimerFeature.State(
            id: uuid(),
            workoutID: workout.id,
            title: workout.displayName,
            schedule: WorkoutSchedule(workout: workout)
        )
    }

    /// A timer over a saved run already settled at `now`.
    func restoredTimerState(for workout: Workout, run: WorkoutRun, at now: Date) -> WorkoutTimerFeature.State {
        WorkoutTimerFeature.State(id: uuid(), workoutID: workout.id, title: workout.displayName, restoring: run, at: now)
    }

    private func reorder(_ workouts: IdentifiedArrayOf<Workout>, _ state: inout State) -> Effect<Action> {
        state.workouts = .loaded(workouts)
        return enqueue(.reorder(Array(workouts.ids)), &state)
    }

    private func enqueue(_ mutation: ListMutation, _ state: inout State) -> Effect<Action> {
        state.pendingMutations.append(mutation)
        // The reload in flight may read storage before this write lands, whichever answers first.
        if state.isReloading {
            state.needsReload = true
        }
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

    private func destinationDismissed(_ state: inout State) -> Effect<Action> {
        switch state.destination {
            case let .timer(timer):
                // The timer closes itself after ending its session and clearing its run, but a system dismissal, such as
                // a back button the timer failed to hide, skips that; doing both again here is harmless. The second clear
                // also retries one that failed: its revision is newer than the timer's, and older than any write of a
                // timer started later. A dismissal before the cover appeared is not the user's: the run stays saved.
                let isCoverUp = state.isTimerCoverUp
                state.isTimerCoverUp = false
                let end = Effect<Action>.run { [timerSession, id = timer.id] _ in
                    await timerSession.end(owner: id)
                }
                guard isCoverUp else {
                    Self.logger.error("The timer was dismissed before its cover appeared; its run stays saved")
                    let notice: Effect<Action> = timer.snapshot.status == .idle
                        ? .none
                        : .send(.internal(.timerPresentationFailed))
                    return .merge(end, notice)
                }
                return .merge(end, discardRunRecord())
            case .resumeRun:
                // Gone without a choice: this launch moves on, and the record stays, so the next launch asks again.
                state.runRestore = .resolved
                return .none
            case .alert, nil:
                return .none
        }
    }

    /// Storage appends a new workout, so a new one goes to the end here too.
    private func workoutSaved(_ workout: Workout, _ state: inout State) -> Effect<Action> {
        guard case var .loaded(workouts) = state.workouts else { return loadWorkouts(&state) }

        workouts[id: workout.id] = workout
        state.workouts = .loaded(workouts)
        return .none
    }

    func loadWorkouts(_ state: inout State) -> Effect<Action> {
        // A shown list stays until the new one arrives: a spinner in its place would flash, and a push right after the
        // reload would carry the spinner's picture of the tab bar on iOS 26.
        if case .loaded = state.workouts {
            state.isReloading = true
        } else {
            state.workouts = .loading
        }
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
extension AppFeature.Path.State: Equatable, Sendable {}
extension AppFeature.Path.Action: Equatable, Sendable {}

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
