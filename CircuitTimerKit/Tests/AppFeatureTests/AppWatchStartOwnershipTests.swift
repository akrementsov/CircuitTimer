@testable import AppFeature
@testable import WorkoutEditorFeature

import ComposableArchitecture
import Foundation
import PurchaseFeature
import Testing
import WatchLink
import WorkoutDomain
import WorkoutStorage

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppWatchStartOwnershipTests {
    private let fixture = WatchStartFixture()

    @Test(arguments: [false, true])
    func test_refreshOpenWorkout_watchAllowsRefreshWhileEditorIntentHoldsOriginal(watch: Bool) async throws {
        let clock = TestClock<Duration>()
        var state = fixture.pending(clock)
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: fixture.workout)))
        let id = try #require(state.path.ids.last)
        if !watch {
            state.startIntent = .init(generation: 1, origin: .editor(id), workout: fixture.workout, stage: .health)
        }
        var renamed = fixture.workout
        renamed.name = "Renamed in iCloud"
        let store = makeStore(state) { $0.continuousClock = clock }
        await store.send(.internal(.workoutsLoaded(StoredWorkouts(workouts: [renamed])))) {
            $0.workouts = .loaded([renamed])
            if watch { $0.path[id: id] = .editor(WorkoutEditorFeature.State(viewing: renamed)) }
        }
        #expect(store.state.startIntent?.workout == fixture.workout)
        await store.finish()
    }

    @Test(arguments: [false, true])
    func test_watchIntent_reloadOrMutationInProgress_usesCurrentLoadedRecord(mutation: Bool) async {
        let clock = TestClock<Duration>()
        var state = fixture.pending(clock)
        state.isReloading = !mutation
        if mutation { state.pendingMutations = [.delete(makeWorkout(2).id)] }
        let store = makeStore(state, healthAccess: nil) { $0.continuousClock = clock; $0.timerSession.end = { _ in } }
        await store.send(.internal(.healthAccessQueried(generation: 1, .determined))) {
            $0.healthAccess = .determined
            $0.startIntent = nil
            $0.destination = .timer(self.fixture.timer)
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
    }

    enum RecordChange: CaseIterable, Sendable { case gone, notPlayable, fingerprint }
    enum Guard: CaseIterable, Sendable { case admission, scene, tail }

    @Test(arguments: RecordChange.allCases, Guard.allCases)
    func test_watchIntent_invalidCurrentRecord_cancelsAtEveryBoundary(change: RecordChange, boundary: Guard) async {
        let clock = TestClock<Duration>()
        var state = fixture.pending(clock, stage: boundary == .admission ? .admitting : .health)
        switch change {
            case .gone: state.workouts = .loaded([])
            case .notPlayable: state.workouts = .loaded([Workout(id: fixture.workout.id, name: "Empty")])
            case .fingerprint:
                var changed = fixture.workout
                changed.training[0].duration = .seconds(20)
                state.workouts = .loaded([changed])
        }
        let store = makeStore(state) { $0.continuousClock = clock }
        let action: AppFeature.Action = switch boundary {
            case .admission: .internal(.watchStartAdmitted(generation: 1, true))
            case .scene: .view(.scenePhaseChanged(.inactive))
            case .tail: .internal(.notificationCleanupFinished(true))
        }
        await store.send(action) {
            if boundary == .scene { $0.isSceneActive = false }
            $0.startIntent = nil
            $0.startGeneration = 2
        }
        #expect(store.state.destination == nil)
        await store.finish()
    }

    @Test
    func test_editDuringWatchStart_cancelsIntentAndKeepsDraftChanges() async throws {
        let clock = TestClock<Duration>()
        var state = fixture.pending(clock)
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: fixture.workout)))
        let id = try #require(state.path.ids.last)
        let store = makeStore(state) { $0.continuousClock = clock }
        await store.send(.path(.element(id: id, action: .editor(.view(.editButtonTapped))))) {
            $0.path[id: id, case: \.editor]?.phase = .editing
            $0.startIntent = nil
            $0.startGeneration = 2
        }
        await store.send(.path(.element(id: id, action: .editor(.view(.nameChanged("My draft")))))) {
            $0.path[id: id, case: \.editor]?.draft.name = "My draft"
        }
        await store.send(.internal(.healthPermissionAnswered(generation: 1, succeeded: true))) { $0.healthAccess = .determined }
        #expect(store.state.path[id: id, case: \.editor]?.draft.name == "My draft")
        #expect(store.state.destination == nil)
        await store.finish()
    }

    @Test
    func test_createDraftDuringWatchStart_cancelsIntentAndKeepsNewEditor() async {
        let clock = TestClock<Duration>()
        let store = makeStore(fixture.pending(clock)) { $0.continuousClock = clock }
        await store.send(.view(.addButtonTapped)) {
            $0.path.append(.editor(WorkoutEditorFeature.State(
                newWorkoutID: UUID(0), warmUpStageID: UUID(1), trainingStageID: UUID(2), coolDownStageID: UUID(3)
            )))
            $0.startIntent = nil
            $0.startGeneration = 2
        }
        #expect(store.state.path[id: 0, case: \.editor]?.phase == .new)
        await store.finish()
    }

    @Test
    func test_purchaseDuringWatchStart_cancelsWithoutReplacingSheet() async {
        let clock = TestClock<Duration>()
        var state = fixture.pending(clock)
        state.fullVersion = .free
        state.settings.$isICloudSyncOn.withLock { $0 = true }
        let store = makeStore(state) { $0.continuousClock = clock }
        await store.send(.settings(.delegate(.fullVersionRequested(.buy)))) {
            $0.startIntent = nil
            $0.startGeneration = 2
            $0.destination = .purchase(PurchaseFeature.State(entry: .browse, iCloudOutlook: .startsNextLaunch))
        }
        await store.finish()
    }

    @Test(arguments: [false, true])
    func test_expiry_dismissesOnlyOwnStallAlert(ownAlert: Bool) async {
        let clock = TestClock<Duration>()
        var state = fixture.pending(clock, stage: .notifications)
        state.destination = ownAlert ? .permissionStalled(.permissionStalled) : .alert(.mutationFailed)
        let store = makeStore(state) { $0.continuousClock = clock }
        await store.send(.internal(.watchStartExpired(generation: 1))) {
            $0.startIntent = nil
            $0.startGeneration = 2
            if ownAlert { $0.destination = nil }
        }
        #expect(ownAlert ? store.state.destination == nil : store.state.destination?.is(\.alert) == true)
        await store.finish()
    }

    @Test(arguments: [false, true])
    func test_stalledWatchHealth_localStartBypassesHealthOrFailedTakeoverRetiresBoth(local: Bool) async throws {
        let clock = TestClock<Duration>()
        var state = fixture.pending(clock)
        state.startIntent?.hasStalled = true
        state.isHealthRequestOutstanding = true
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: fixture.workout)))
        let id = try #require(state.path.ids.last)
        let store = makeStore(state, healthAccess: nil) {
            $0.continuousClock = clock
            $0.timerSession.end = { _ in }
            $0.workoutHealth.access = { Issue.record("Takeover read Health"); return .determined }
            $0.watchCompanion.startHandled = { _, _ in false }
        }
        if local {
            await store.send(.path(.element(id: id, action: .editor(.delegate(.startRequested(fixture.workout)))))) {
                $0.startIntent = nil
                $0.startGeneration = 2
                $0.destination = .timer(self.fixture.timer)
            }
        } else {
            await store.send(.internal(.watchStartRequested(fixture.request))) {
                $0.startGeneration = 3
                $0.startIntent = .init(
                    generation: 3,
                    origin: .watch(requestID: 7),
                    workout: self.fixture.workout,
                    stage: .admitting,
                    skipsHealth: true,
                    acceptedAt: MonotonicInstant(now: clock)
                )
            }
            await store.receive(.internal(.watchStartAdmitted(generation: 3, false))) {
                $0.startIntent = nil
                $0.startGeneration = 4
            }
        }
        await store.send(.internal(.healthAccessQueried(generation: 1, .notDetermined)))
        await store.send(.internal(.healthPermissionAnswered(generation: 1, succeeded: true))) {
            $0.healthAccess = .determined
            $0.isHealthRequestOutstanding = false
        }
        if local { await store.send(.destination(.dismiss)) { $0.destination = nil } }
        await clock.advance(by: .seconds(31))
        await store.finish()
    }
}
