@testable import AppFeature
@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain
import WorkoutEditorFeature
import WorkoutStorage

/// The timer session's endpoints that a test does not override stay unimplemented, so presenting the timer
/// must not touch the session; only a dismissal ends it.
@MainActor
@Suite
struct AppFeatureTimerTests {
    private struct WriteFailure: Error {}

    enum DroppedStart: CaseIterable {
        case missingWorkout
        case notPlayable
        case alertShown
        case editorPushed
        case settingsTab
    }

    private let first = makeWorkout(1)
    private let second = makeWorkout(2)
    /// Nothing to play: it has no stages.
    private let empty = Workout(id: UUID(fixture: 5), name: "Empty")

    @Test
    func test_startButtonTapped_idleQueue_presentsTimerWithNewIDTitleAndSchedule() async {
        let untitled = Workout(
            id: UUID(fixture: 3),
            name: "  ",
            warmUp: [makeStage(31)],
            training: [makeStage(32), makeStage(33, .rest)],
            trainingRounds: 2
        )
        let ends = LockIsolated<[UUID]>([])
        let store = makeStore(loaded([first, untitled])) {
            $0.timerSession.end = { owner in ends.withValue { $0.append(owner) } }
        }

        await store.send(.view(.startButtonTapped(untitled.id))) {
            // `make test` runs in English, so the catalog's English variant applies.
            $0.destination = .timer(
                WorkoutTimerFeature.State(id: UUID(0), title: "Untitled workout", schedule: WorkoutSchedule(workout: untitled))
            )
        }

        await closeTimer(store)
        #expect(ends.value == [UUID(0)])
    }

    @Test
    func test_startButtonTapped_whileLoading_opensTimerOnceListLoads() async {
        var state = AppFeature.State()
        state.workouts = .loading
        let ends = LockIsolated<[UUID]>([])
        let store = makeStore(state) {
            $0.timerSession.end = { owner in ends.withValue { $0.append(owner) } }
        }

        await store.send(.view(.startButtonTapped(second.id))) { $0.deferredScreen = .start(self.second.id) }
        await store.send(.internal(.workoutsLoaded(StoredWorkouts(workouts: [first, second])))) {
            $0.workouts = .loaded([self.first, self.second])
            $0.deferredScreen = nil
            $0.destination = .timer(Self.timer(UUID(0), for: self.second))
        }

        await closeTimer(store)
        #expect(ends.value == [UUID(0)])
    }

    @Test
    func test_startButtonTapped_whileWriting_opensTimerOnceQueueDrains() async {
        let clock = TestClock()
        let ends = LockIsolated<[UUID]>([])
        let store = makeStore(loaded([first, second])) {
            $0.workoutStorage.delete = { _ in
                try await clock.sleep(for: .seconds(1))
                return .applied
            }
            $0.timerSession.end = { owner in ends.withValue { $0.append(owner) } }
        }

        await store.send(.view(.deleteButtonTapped(first.id))) {
            $0.workouts = .loaded([self.second])
            $0.pendingMutations = [.delete(self.first.id)]
        }
        await store.send(.view(.startButtonTapped(second.id))) { $0.deferredScreen = .start(self.second.id) }
        await clock.advance(by: .seconds(1))
        await store.receive(\.internal.mutationFinished) {
            $0.pendingMutations = []
            $0.deferredScreen = nil
            $0.destination = .timer(Self.timer(UUID(0), for: self.second))
        }

        await closeTimer(store)
        #expect(ends.value == [UUID(0)])
    }

    @Test
    func test_deferredStart_afterDivergence_opensTimerWithReloadedWorkout() async {
        let renamed = makeWorkout(2, name: "Reloaded")
        var state = loaded([first, second])
        state.pendingMutations = [.reorder([second.id, first.id])]
        state.deferredScreen = .start(second.id)
        let ends = LockIsolated<[UUID]>([])
        let store = makeStore(state) {
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: [makeWorkout(1), renamed]) }
            $0.timerSession.end = { owner in ends.withValue { $0.append(owner) } }
        }

        await store.send(.internal(.mutationFinished(.storeDiverged))) {
            $0.pendingMutations = []
            $0.workouts = .loading
        }
        await store.receive(\.internal.workoutsLoaded) {
            $0.workouts = .loaded([makeWorkout(1), renamed])
            $0.deferredScreen = nil
            $0.destination = .timer(Self.timer(UUID(0), for: renamed))
        }

        await closeTimer(store)
        #expect(ends.value == [UUID(0)])
    }

    @Test(arguments: DroppedStart.allCases)
    func test_deferredStart_screenCannotOpen_isDroppedWithoutPresenting(reason: DroppedStart) async {
        var state = loaded([first, empty])
        state.pendingMutations = [.delete(UUID(fixture: 99))]
        state.deferredScreen = .start(first.id)
        switch reason {
            case .missingWorkout:
                state.deferredScreen = .start(UUID(fixture: 99))
            case .notPlayable:
                state.deferredScreen = .start(empty.id)
            case .alertShown:
                state.destination = .alert(.mutationFailed)
            case .editorPushed:
                state.path.append(.editor(WorkoutEditorFeature.State(editing: first)))
            case .settingsTab:
                state.selectedTab = .settings
        }
        let store = makeStore(state)

        await store.send(.internal(.mutationFinished(.applied))) {
            $0.pendingMutations = []
            $0.deferredScreen = nil
        }
    }

    @Test
    func test_startButtonTapped_notPlayableOrTimerShown_presentsNothing() async {
        let ends = LockIsolated<[UUID]>([])
        let store = makeStore(loaded([first, empty])) {
            $0.timerSession.end = { owner in ends.withValue { $0.append(owner) } }
        }

        await store.send(.view(.startButtonTapped(empty.id)))
        await store.send(.view(.startButtonTapped(first.id))) {
            $0.destination = .timer(Self.timer(UUID(0), for: self.first))
        }
        await store.send(.view(.startButtonTapped(first.id)))

        await closeTimer(store)
        #expect(ends.value == [UUID(0)])
    }

    @Test
    func test_deleteButtonTapped_pendingStart_clearsOnlyStartOfDeletedWorkout() async {
        var state = loaded([first, second])
        state.pendingMutations = [.reorder([second.id, first.id])]
        state.deferredScreen = .start(first.id)
        let store = makeStore(state)

        await store.send(.view(.deleteButtonTapped(second.id))) {
            $0.workouts = .loaded([self.first])
            $0.pendingMutations.append(.delete(self.second.id))
        }
        #expect(store.state.deferredScreen == .start(first.id))
        await store.send(.view(.deleteButtonTapped(first.id))) {
            $0.workouts = .loaded([])
            $0.pendingMutations.append(.delete(self.first.id))
            $0.deferredScreen = nil
        }
    }

    @Test
    func test_mutationFailed_timerShown_keepsTimerAndClearsQueueAndReloads() async {
        let clock = TestClock()
        let third = makeWorkout(3)
        let fourth = makeWorkout(4)
        let ends = LockIsolated<[UUID]>([])
        let store = makeStore(loaded([first, second, third, fourth])) {
            $0.workoutStorage.delete = { id in
                try await clock.sleep(for: .seconds(1))
                if id == third.id { return .storeDiverged }
                throw WriteFailure()
            }
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: [makeWorkout(1), makeWorkout(2), makeWorkout(4)]) }
            $0.timerSession.end = { owner in ends.withValue { $0.append(owner) } }
        }

        await store.send(.view(.startButtonTapped(first.id))) {
            $0.destination = .timer(Self.timer(UUID(0), for: self.first))
        }
        await store.send(.view(.deleteButtonTapped(third.id))) {
            $0.workouts = .loaded([self.first, self.second, fourth])
            $0.pendingMutations = [.delete(third.id)]
        }
        await store.send(.view(.deleteButtonTapped(fourth.id))) {
            $0.workouts = .loaded([self.first, self.second])
            $0.pendingMutations = [.delete(third.id), .delete(fourth.id)]
        }
        await store.send(.view(.startButtonTapped(second.id))) { $0.deferredScreen = .start(self.second.id) }
        await clock.advance(by: .seconds(1))
        await store.receive(\.internal.mutationFinished) {
            $0.pendingMutations = [.delete(fourth.id)]
            $0.needsReload = true
        }
        await clock.advance(by: .seconds(1))
        await store.receive(\.internal.mutationFailed) {
            $0.pendingMutations = []
            $0.needsReload = false
            $0.deferredScreen = nil
            $0.workouts = .loading
        }
        await store.receive(\.internal.workoutsLoaded) {
            $0.workouts = .loaded([makeWorkout(1), makeWorkout(2), makeWorkout(4)])
        }

        await closeTimer(store)
        #expect(ends.value == [UUID(0)])
    }

    @Test
    func test_closeConfirmationFinish_presentedTimer_endsSessionInChildAndParentAndDismisses() async {
        let calls = LockIsolated<[SessionCall]>([])
        let ended = LockIsolated<Set<UUID>>([])
        let store = makeStore(loaded([first])) {
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
            $0.timerSession.requestAwake = { owner, awake, revision in
                calls.withValue { $0.append(.requestAwake(owner, awake: awake, revision: revision)) }
            }
            $0.timerSession.end = { owner in
                calls.withValue { $0.append(.end(owner)) }
                ended.withValue { _ = $0.insert(owner) }
            }
            // Not recorded: the countdown loop may be cancelled before it asks.
            $0.timerSession.isEnded = { owner in ended.value.contains(owner) }
        }
        let id = UUID(0)

        await store.send(.view(.startButtonTapped(first.id))) {
            $0.destination = .timer(Self.timer(id, for: self.first))
        }
        await store.send(.destination(.presented(.timer(.view(.task))))) {
            $0.$destination[case: \.timer]?.clockGeneration = 1
            $0.$destination[case: \.timer]?.requestedAwake = true
            $0.$destination[case: \.timer]?.awakeRevision = 1
        }
        await store.send(.destination(.presented(.timer(.view(.closeButtonTapped))))) {
            $0.$destination[case: \.timer]?.countdown = nil
            $0.$destination[case: \.timer]?.clockGeneration = 2
            $0.$destination[case: \.timer]?.requestedAwake = false
            $0.$destination[case: \.timer]?.awakeRevision = 2
            $0.$destination[case: \.timer]?.destination = .closeConfirmation(.closeConfirmation(restart: .start))
        }
        await store.send(.destination(.presented(.timer(.destination(.presented(.closeConfirmation(.finish))))))) {
            $0.$destination[case: \.timer]?.destination = nil
        }
        await store.receive(\.destination.dismiss) { $0.destination = nil }
        await store.finish()

        // Each vote is its own effect, so only the revisions order them.
        let votes = calls.value.filter { !$0.isEnd }.sorted { $0.revision < $1.revision }
        #expect(votes == [.requestAwake(id, awake: true, revision: 1), .requestAwake(id, awake: false, revision: 2)])
        #expect(calls.value.filter(\.isEnd) == [.end(id), .end(id)])
        #expect(calls.value.suffix(2) == [.end(id), .end(id)])
    }

    @Test
    func test_destinationDismiss_presentedTimer_endsSessionOnce() async {
        let ends = LockIsolated<[UUID]>([])
        let store = makeStore(loaded([first])) {
            $0.timerSession.end = { owner in ends.withValue { $0.append(owner) } }
        }

        await store.send(.view(.startButtonTapped(first.id))) {
            $0.destination = .timer(Self.timer(UUID(0), for: self.first))
        }
        await closeTimer(store)

        #expect(ends.value == [UUID(0)])
    }

    @Test
    func test_destinationDismiss_alert_endsNoSession() async {
        var state = loaded([first])
        state.destination = .alert(.mutationFailed)
        let store = makeStore(state)

        await store.send(.destination(.dismiss)) { $0.destination = nil }
    }

    /// A presented timer keeps the presentation's effect running until it is dismissed.
    private func closeTimer(_ store: TestStoreOf<AppFeature>) async {
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
    }

    private static func timer(_ id: UUID, for workout: Workout) -> WorkoutTimerFeature.State {
        WorkoutTimerFeature.State(id: id, title: workout.name, schedule: WorkoutSchedule(workout: workout))
    }
}

private enum SessionCall: Equatable {
    case requestAwake(UUID, awake: Bool, revision: Int)
    case end(UUID)

    var isEnd: Bool {
        if case .end = self { true } else { false }
    }

    var revision: Int {
        if case let .requestAwake(_, _, revision) = self { revision } else { 0 }
    }
}
