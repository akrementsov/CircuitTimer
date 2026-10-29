@testable import AppFeature
@testable import WorkoutEditorFeature

import BackgroundNotifications
import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain
import WorkoutHealth
import WorkoutStorage
import WorkoutTimerFeature

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppHealthPermissionTests {
    private struct ReadFailure: Error {}

    private let workout = makeWorkout(1)
    private let renamed = makeWorkout(1, name: "Renamed")
    /// Nothing to play: it has no stages.
    private let empty = Workout(id: UUID(fixture: 5), name: "Empty")

    /// The workout's screen on the Workouts stack, as Start finds it.
    private func opened(
        _ workout: Workout? = nil,
        isStarting: Bool = false,
        _ configure: (inout AppFeature.State) -> Void = { _ in }
    ) throws -> (AppFeature.State, StackElementID) {
        var state = loaded([workout ?? self.workout])
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: workout ?? self.workout)))
        let id = try #require(state.path.ids.last)
        state.path[id: id, case: \.editor]?.isStarting = isStarting
        configure(&state)
        return (state, id)
    }

    private func store(
        _ state: AppFeature.State,
        notificationsEnabled: Bool = false,
        healthAccess: HealthAccess? = nil,
        dependencies: (inout DependencyValues) -> Void = { _ in }
    ) -> TestStoreOf<AppFeature> {
        makeStore(state, notificationsEnabled: notificationsEnabled, healthAccess: healthAccess) {
            $0.timerSession.end = { _ in }
            dependencies(&$0)
        }
    }

    private func start(_ id: StackElementID, _ workout: Workout? = nil) -> AppFeature.Action {
        .path(.element(id: id, action: .editor(.delegate(.startRequested(workout ?? self.workout)))))
    }

    private func intent(_ id: StackElementID, generation: Int = 1) -> AppFeature.StartIntent {
        var intent = AppFeature.StartIntent(generation: generation, editorID: id, workout: workout)
        intent.stage = .health
        return intent
    }

    private func timer(_ workout: Workout? = nil) -> WorkoutTimerFeature.State {
        let workout = workout ?? self.workout
        return WorkoutTimerFeature.State(
            id: UUID(0),
            workoutID: workout.id,
            title: workout.name,
            workoutName: workout.name,
            schedule: WorkoutSchedule(workout: workout)
        )
    }

    private func closeTimer(_ store: TestStoreOf<AppFeature>) async {
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
    }

    // MARK: - The main path

    @Test
    func test_start_healthNotDetermined_readsAsksAndOpensTheTimer() async throws {
        let (state, id) = try opened()
        let sheet = AsyncStream<Void>.makeStream()
        let store = store(state, healthAccess: .notDetermined) {
            $0.workoutHealth.access = { .notDetermined }
            $0.workoutHealth.requestAuthorization = { for await _ in sheet.stream {} }
        }

        // A cached `notDetermined` may have been answered in Settings since, so it is read again.
        await store.send(start(id)) {
            $0.startGeneration = 1
            $0.startIntent = self.intent(id)
            $0.healthAccess = nil
        }
        await store.receive(\.internal.healthAccessQueried) {
            $0.healthAccess = .notDetermined
            $0.isHealthRequestOutstanding = true
        }
        #expect(store.state.destination == nil)
        sheet.continuation.finish()
        await store.receive(\.internal.healthPermissionAnswered) {
            $0.isHealthRequestOutstanding = false
            $0.healthAccess = .determined
            $0.startIntent = nil
            $0.destination = .timer(self.timer())
        }
        await closeTimer(store)
    }

    @Test
    func test_start_afterNotifications_handsTheSameIntentToHealth() async throws {
        let (state, id) = try opened()
        let store = store(state, notificationsEnabled: true) {
            $0.backgroundNotifications.access = { .authorized }
            $0.workoutHealth.access = { .determined }
        }

        await store.send(start(id)) {
            $0.startGeneration = 1
            $0.startIntent = AppFeature.StartIntent(generation: 1, editorID: id, workout: self.workout)
        }
        await store.receive(\.internal.notificationAccessQueried) {
            $0.notificationAccess = .authorized
            $0.startIntent?.stage = .health
        }
        await store.receive(\.internal.healthAccessQueried) {
            $0.healthAccess = .determined
            $0.startIntent = nil
            $0.destination = .timer(self.timer())
        }
        await closeTimer(store)
    }

    @Test(arguments: [HealthAccess.unavailable, .determined])
    func test_start_readAccessThatNeedsNoSheet_cachesItAndOpensTheTimer(access: HealthAccess) async throws {
        let (state, id) = try opened()
        let store = store(state) { $0.workoutHealth.access = { access } }

        await store.send(start(id)) {
            $0.startGeneration = 1
            $0.startIntent = self.intent(id)
        }
        await store.receive(\.internal.healthAccessQueried) {
            $0.healthAccess = access
            $0.startIntent = nil
            $0.destination = .timer(self.timer())
        }
        await closeTimer(store)
    }

    enum KnownAccess: CaseIterable, Sendable {
        case requestOutstanding
        case determined
        case unavailable
    }

    @Test(arguments: KnownAccess.allCases)
    func test_start_accessKnownOrAskedAlready_opensTheTimerWithoutReading(known: KnownAccess) async throws {
        let (state, id) = try opened { $0.isHealthRequestOutstanding = known == .requestOutstanding }
        let access: HealthAccess = switch known {
            case .requestOutstanding: .notDetermined
            case .determined: .determined
            case .unavailable: .unavailable
        }
        let store = store(state, healthAccess: access)

        await store.send(start(id)) {
            $0.destination = .timer(self.timer())
        }
        await closeTimer(store)
    }

    @Test
    func test_start_inactiveScene_asksOnlyOnceTheSceneIsActive() async throws {
        let (state, id) = try opened { $0.isSceneActive = false }
        let requests = LockIsolated(0)
        let store = store(state) {
            $0.workoutHealth.access = { .notDetermined }
            $0.workoutHealth.requestAuthorization = { requests.withValue { $0 += 1 } }
        }

        await store.send(start(id)) {
            $0.startGeneration = 1
            $0.startIntent = self.intent(id)
        }
        await store.receive(\.internal.healthAccessQueried) { $0.healthAccess = .notDetermined }
        #expect(requests.value == 0)

        await store.send(.view(.scenePhaseChanged(.active))) {
            $0.isSceneActive = true
            $0.isHealthRequestOutstanding = true
        }
        await store.receive(\.internal.healthPermissionAnswered) {
            $0.isHealthRequestOutstanding = false
            $0.healthAccess = .determined
            $0.startIntent = nil
            $0.destination = .timer(self.timer())
        }
        #expect(requests.value == 1)
        await closeTimer(store)
    }

    // MARK: - Failures and cancellation

    @Test
    func test_start_accessReadFails_opensTheTimerAndCachesNothing() async throws {
        let (state, id) = try opened()
        let store = store(state) { $0.workoutHealth.access = { throw ReadFailure() } }

        await store.send(start(id)) {
            $0.startGeneration = 1
            $0.startIntent = self.intent(id)
        }
        await store.receive(\.internal.healthAccessQueried) {
            $0.startIntent = nil
            $0.destination = .timer(self.timer())
        }
        #expect(store.state.healthAccess == nil)
        await closeTimer(store)
    }

    @Test
    func test_start_requestFails_opensTheTimerWithoutCachingAnAnswer() async throws {
        let (state, id) = try opened()
        let store = store(state) {
            $0.workoutHealth.access = { .notDetermined }
            $0.workoutHealth.requestAuthorization = { throw ReadFailure() }
        }

        await store.send(start(id)) {
            $0.startGeneration = 1
            $0.startIntent = self.intent(id)
        }
        await store.receive(\.internal.healthAccessQueried) {
            $0.healthAccess = .notDetermined
            $0.isHealthRequestOutstanding = true
        }
        await store.receive(\.internal.healthPermissionAnswered) {
            $0.isHealthRequestOutstanding = false
            $0.startIntent = nil
            $0.destination = .timer(self.timer())
        }
        await closeTimer(store)
    }

    @Test
    func test_start_tabChangedDuringTheRead_freesStartAndTheNextStartReadsAgain() async throws {
        let (state, id) = try opened(isStarting: true)
        let reads = LockIsolated(0)
        let blocked = AsyncStream<Void>.makeStream()
        let store = store(state) {
            $0.workoutHealth.access = {
                let read = reads.withValue {
                    $0 += 1
                    return $0
                }
                guard read > 1 else {
                    for await _ in blocked.stream {}
                    throw CancellationError()
                }
                return .determined
            }
        }

        await store.send(start(id)) {
            $0.startGeneration = 1
            $0.startIntent = self.intent(id)
        }
        await store.send(.view(.tabSelected(.settings))) {
            $0.selectedTab = .settings
            $0.path[id: id, case: \.editor]?.isStarting = false
            $0.startIntent = nil
            $0.startGeneration = 2
        }
        #expect(store.state.destination == nil)
        #expect(store.state.healthAccess == nil)

        await store.send(.view(.tabSelected(.workouts))) { $0.selectedTab = .workouts }
        await store.send(start(id)) {
            $0.startGeneration = 3
            $0.startIntent = self.intent(id, generation: 3)
        }
        await store.receive(\.internal.healthAccessQueried) {
            $0.healthAccess = .determined
            $0.startIntent = nil
            $0.destination = .timer(self.timer())
        }
        #expect(reads.value == 2)
        await closeTimer(store)
    }

    // MARK: - Refused starts

    @Test(arguments: [false, true])
    func test_start_refusedWithoutAnIntent_freesStart(isPresenting: Bool) async throws {
        let shown = isPresenting ? workout : empty
        let (state, id) = try opened(shown, isStarting: true) {
            if isPresenting { $0.destination = .alert(.mutationFailed) }
        }
        let store = store(state)

        await store.send(start(id, shown)) {
            $0.path[id: id, case: \.editor]?.isStarting = false
        }
    }

    @Test
    func test_start_refusedWhileAnIntentHoldsStart_leavesItAlone() async throws {
        let (state, id) = try opened(isStarting: true) {
            $0.destination = .permissionStalled(.permissionStalled)
            $0.startGeneration = 1
        }
        var withIntent = state
        withIntent.startIntent = intent(id)
        let store = store(withIntent)

        await store.send(start(id))
    }

    @Test
    func test_healthAccessQueried_presentationAppeared_freesStartAndDropsTheIntent() async throws {
        let (state, id) = try opened(isStarting: true) {
            $0.destination = .permissionStalled(.permissionStalled)
            $0.startGeneration = 1
        }
        var withIntent = state
        withIntent.startIntent = intent(id)
        let store = store(withIntent)

        await store.send(.internal(.healthAccessQueried(generation: 1, .determined))) {
            $0.healthAccess = .determined
            $0.path[id: id, case: \.editor]?.isStarting = false
            $0.startIntent = nil
            $0.startGeneration = 2
        }
    }

    // MARK: - Stale and late answers

    @Test
    func test_healthAccessQueried_staleGenerationOrAnotherStage_isIgnored() async throws {
        let (state, id) = try opened { $0.startGeneration = 2 }
        var health = state
        health.startIntent = intent(id, generation: 2)
        let store = store(health)

        await store.send(.internal(.healthAccessQueried(generation: 1, .determined)))

        var notifications = state
        notifications.startIntent = AppFeature.StartIntent(generation: 2, editorID: id, workout: workout)
        let other = self.store(notifications)
        await other.send(.internal(.healthAccessQueried(generation: 2, .determined)))
    }

    @Test
    func test_healthPermissionAnswered_staleAnswer_onlyUpdatesTheCache() async {
        var state = loaded([workout])
        state.isHealthRequestOutstanding = true
        state.startGeneration = 3
        let store = store(state, healthAccess: .notDetermined)

        await store.send(.internal(.healthPermissionAnswered(generation: 1, succeeded: true))) {
            $0.isHealthRequestOutstanding = false
            $0.healthAccess = .determined
        }
    }

    @Test
    func test_notificationEvents_afterTheHandOverToHealth_areIgnored() async throws {
        let (state, id) = try opened { $0.startGeneration = 1 }
        var withIntent = state
        withIntent.startIntent = intent(id)
        let store = store(withIntent)

        await store.send(.internal(.notificationPermissionStalled(generation: 1)))
        await store.send(.internal(.startIntentConfirmed(generation: 1)))
        // The answer still updates the cache, as a late system answer does.
        await store.send(.internal(.notificationPermissionAnswered(generation: 1, .authorized))) {
            $0.notificationAccess = .authorized
        }
        #expect(store.state.startIntent == intent(id))
        #expect(store.state.destination == nil)
    }

    // MARK: - A stalled stage

    @Test
    func test_stall_freesStartAndANewStartOpensTheTimerWithoutHealth() async throws {
        let (state, id) = try opened(isStarting: true)
        let clock = TestClock()
        let sheet = AsyncStream<Void>.makeStream()
        let store = store(state) {
            $0.continuousClock = clock
            $0.workoutHealth.access = { .notDetermined }
            $0.workoutHealth.requestAuthorization = { for await _ in sheet.stream {} }
        }
        await store.send(start(id)) {
            $0.startGeneration = 1
            $0.startIntent = self.intent(id)
        }
        await store.receive(\.internal.healthAccessQueried) {
            $0.healthAccess = .notDetermined
            $0.isHealthRequestOutstanding = true
        }

        // Before the stall a second Start goes nowhere: the first still holds the button.
        await store.send(start(id))
        await clock.advance(by: .seconds(10))
        await store.receive(\.internal.healthStalled) {
            $0.startIntent?.hasStalled = true
            $0.path[id: id, case: \.editor]?.isStarting = false
        }
        await store.send(start(id)) {
            $0.startIntent = nil
            $0.startGeneration = 2
            $0.destination = .timer(self.timer())
        }

        // The late answer opens no second timer.
        sheet.continuation.finish()
        await store.receive(\.internal.healthPermissionAnswered) {
            $0.isHealthRequestOutstanding = false
            $0.healthAccess = .determined
        }
        await closeTimer(store)
    }

    @Test
    func test_stallDuringTheRead_lateNotDeterminedOrActiveScene_showsNoSheet() async throws {
        let (state, id) = try opened(isStarting: true)
        let clock = TestClock()
        let read = AsyncStream<HealthAccess>.makeStream()
        let requests = LockIsolated(0)
        let store = store(state) {
            $0.continuousClock = clock
            $0.workoutHealth.access = {
                for await access in read.stream { return access }
                throw CancellationError()
            }
            $0.workoutHealth.requestAuthorization = { requests.withValue { $0 += 1 } }
        }
        await store.send(start(id)) {
            $0.startGeneration = 1
            $0.startIntent = self.intent(id)
        }
        await clock.advance(by: .seconds(10))
        await store.receive(\.internal.healthStalled) {
            $0.startIntent?.hasStalled = true
            $0.path[id: id, case: \.editor]?.isStarting = false
        }

        read.continuation.yield(.notDetermined)
        await store.receive(\.internal.healthAccessQueried) { $0.healthAccess = .notDetermined }
        await store.send(.view(.scenePhaseChanged(.background))) { $0.isSceneActive = false }
        await store.send(.view(.scenePhaseChanged(.active))) { $0.isSceneActive = true }
        await clock.advance(by: .seconds(10))

        #expect(requests.value == 0)
        #expect(store.state.destination == nil)
    }

    @Test
    func test_stallTimer_leavingTheSceneCancelsItAndReturningStartsItAgain() async throws {
        let (state, id) = try opened(isStarting: true)
        let clock = TestClock()
        let sheet = AsyncStream<Void>.makeStream()
        let store = store(state) {
            $0.continuousClock = clock
            $0.workoutHealth.access = { .notDetermined }
            $0.workoutHealth.requestAuthorization = { for await _ in sheet.stream {} }
        }
        await store.send(start(id)) {
            $0.startGeneration = 1
            $0.startIntent = self.intent(id)
        }
        await store.receive(\.internal.healthAccessQueried) {
            $0.healthAccess = .notDetermined
            $0.isHealthRequestOutstanding = true
        }

        await clock.advance(by: .seconds(9))
        await store.send(.view(.scenePhaseChanged(.background))) { $0.isSceneActive = false }
        await clock.advance(by: .seconds(10))
        await store.send(.view(.scenePhaseChanged(.active))) { $0.isSceneActive = true }
        await clock.advance(by: .seconds(9))
        #expect(store.state.startIntent?.hasStalled == false)

        await clock.advance(by: .seconds(1))
        await store.receive(\.internal.healthStalled) {
            $0.startIntent?.hasStalled = true
            $0.path[id: id, case: \.editor]?.isStarting = false
        }
        await clock.advance(by: .seconds(30))

        sheet.continuation.finish()
        await store.receive(\.internal.healthPermissionAnswered) {
            $0.isHealthRequestOutstanding = false
            $0.healthAccess = .determined
            $0.startIntent = nil
            $0.destination = .timer(self.timer())
        }
        await closeTimer(store)
    }

    @Test
    func test_workoutsLoaded_afterAStall_showsTheStoredVersionAndTheLateAnswerIsStale() async throws {
        let (state, id) = try opened {
            $0.healthAccess = .notDetermined
            $0.isHealthRequestOutstanding = true
            $0.isReloading = true
            $0.startGeneration = 1
        }
        var stalled = state
        stalled.startIntent = intent(id)
        stalled.startIntent?.hasStalled = true
        let store = store(stalled, healthAccess: .notDetermined)

        await store.send(.internal(.workoutsLoaded(StoredWorkouts(workouts: [renamed])))) {
            $0.isReloading = false
            $0.workouts = .loaded([self.renamed])
            $0.path[id: id] = .editor(WorkoutEditorFeature.State(viewing: self.renamed))
            $0.startIntent = nil
            $0.startGeneration = 2
        }
        await store.send(.internal(.healthPermissionAnswered(generation: 1, succeeded: true))) {
            $0.isHealthRequestOutstanding = false
            $0.healthAccess = .determined
        }
        #expect(store.state.destination == nil)
    }

    @Test
    func test_launch_endsHealthSessionsOfAnEarlierProcessOnce() async {
        let orphanEnds = LockIsolated(0)
        let store = store(AppFeature.State()) {
            $0.workoutHealth.endOrphans = { orphanEnds.withValue { $0 += 1 } }
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: []) }
        }

        await store.send(.view(.task)) {
            $0.workouts = .loading
            $0.runRestore = .reading
        }
        await store.receive(.internal(.runRecordLoaded(nil))) { $0.runRestore = .resolved }
        await store.receive(\.internal.workoutsLoaded) { $0.workouts = .loaded([]) }
        await store.send(.view(.task))
        await store.finish()

        #expect(orphanEnds.value == 1)
    }
}
