@testable import AppFeature
@testable import WorkoutEditorFeature
@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain
import WorkoutStorage

/// The timer session's endpoints that a test does not override stay unimplemented, so presenting the timer
/// must not touch the session; only a dismissal ends it.
@MainActor
@Suite
struct AppFeatureTimerTests {
    private struct WriteFailure: Error {}

    private let first = makeWorkout(1)
    private let second = makeWorkout(2)
    /// Nothing to play: it has no stages.
    private let empty = Workout(id: UUID(fixture: 5), name: "Empty")

    @Test
    func test_startRequested_openWorkout_presentsTimerWithNewIDTitleAndScheduleAndPops() async {
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

        // `make test` runs in English, so the catalog's English variant applies.
        await start(
            untitled,
            in: store,
            timer: WorkoutTimerFeature.State(
                id: UUID(0),
                workoutID: untitled.id,
                title: "Untitled workout",
                schedule: WorkoutSchedule(workout: untitled),
                sceneSessionID: "scene-session"
            )
        )

        await closeTimer(store)
        #expect(ends.value == [UUID(0)])
    }

    @Test
    func test_startRequested_notPlayableAlertOrTimerShown_presentsNothing() async throws {
        var notPlayable = loaded([first, empty])
        notPlayable.path.append(.editor(WorkoutEditorFeature.State(viewing: empty)))
        let notPlayableID = try #require(notPlayable.path.ids.first)
        let notPlayableStore = makeStore(notPlayable)
        await notPlayableStore.send(.path(.element(id: notPlayableID, action: .editor(.delegate(.startRequested(empty))))))

        var alertShown = loaded([first])
        alertShown.destination = .alert(.mutationFailed)
        alertShown.path.append(.editor(WorkoutEditorFeature.State(viewing: first)))
        let alertShownID = try #require(alertShown.path.ids.first)
        let alertShownStore = makeStore(alertShown)
        await alertShownStore.send(.path(.element(id: alertShownID, action: .editor(.delegate(.startRequested(first))))))

        var timerShown = loaded([first])
        timerShown.destination = .timer(Self.timer(UUID(fixture: 7), for: first))
        timerShown.path.append(.editor(WorkoutEditorFeature.State(viewing: first)))
        let timerShownID = try #require(timerShown.path.ids.first)
        let ends = LockIsolated<[UUID]>([])
        let timerShownStore = makeStore(timerShown) {
            $0.timerSession.end = { owner in ends.withValue { $0.append(owner) } }
        }
        await timerShownStore.send(.path(.element(id: timerShownID, action: .editor(.delegate(.startRequested(first))))))

        await closeTimer(timerShownStore)
        #expect(ends.value == [UUID(fixture: 7)])
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

        await start(first, in: store)
        await store.send(.view(.deleteButtonTapped(third.id))) {
            $0.workouts = .loaded([self.first, self.second, fourth])
            $0.pendingMutations = [.delete(third.id)]
        }
        await store.send(.view(.deleteButtonTapped(fourth.id))) {
            $0.workouts = .loaded([self.first, self.second])
            $0.pendingMutations = [.delete(third.id), .delete(fourth.id)]
        }
        await store.send(.view(.workoutTapped(second.id))) { $0.deferredScreen = .open(self.second.id) }
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
            $0.isReloading = true
        }
        await store.receive(\.internal.workoutsLoaded) {
            $0.isReloading = false
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

        await start(first, in: store)
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

        await start(first, in: store)
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

    @Test
    func test_timerCoverAppeared_emptyStack_changesNothing() async {
        var state = loaded([first])
        state.destination = .timer(Self.timer(UUID(fixture: 7), for: first))
        let store = makeStore(state) { $0.timerSession.end = { _ in } }

        await store.send(.view(.timerCoverAppeared))

        await closeTimer(store)
    }

    /// The user's route: the workout's screen opens, Start presents the timer, and the stack empties under the cover.
    /// The timer takes the store's first UUID: a read-only screen draws none.
    private func start(_ workout: Workout, in store: TestStoreOf<AppFeature>, timer: WorkoutTimerFeature.State? = nil) async {
        await store.send(.view(.workoutTapped(workout.id))) {
            $0.path[id: 0] = .editor(WorkoutEditorFeature.State(viewing: workout))
        }
        await store.send(.path(.element(id: 0, action: .editor(.view(.startButtonTapped))))) {
            $0.path[id: 0, case: \.editor]?.isStarting = true
        }
        await store.receive(.path(.element(id: 0, action: .editor(.delegate(.startRequested(workout)))))) {
            $0.destination = .timer(timer ?? Self.timer(UUID(0), for: workout))
        }
        await store.send(.view(.timerCoverAppeared)) { $0.path = StackState() }
    }

    /// A presented timer keeps the presentation's effect running until it is dismissed.
    private func closeTimer(_ store: TestStoreOf<AppFeature>) async {
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
    }

    private static func timer(_ id: UUID, for workout: Workout) -> WorkoutTimerFeature.State {
        WorkoutTimerFeature.State(
            id: id,
            workoutID: workout.id,
            title: workout.name,
            schedule: WorkoutSchedule(workout: workout),
            sceneSessionID: "scene-session"
        )
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
