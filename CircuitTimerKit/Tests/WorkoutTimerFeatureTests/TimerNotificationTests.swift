@testable import WorkoutTimerFeature

import BackgroundNotifications
import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain

@MainActor
struct TimerNotificationTests {
    @Test
    func test_notificationProjection_running_containsStageAndFinishWithoutLastSeconds() throws {
        let state = WorkoutTimerFeature.State.fixture(.running, elapsed: 0)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        let projection = state.notificationProjection(at: origin, language: "en")
        #expect(projection.events.map(\.key) == ["stage.1", "finish"])
        #expect(!projection.hasMore)
        let requests = state.notificationRequests(at: origin, language: "en")
        #expect(requests.count == 2)
        #expect(requests.map(\.fireDate) == [moment(10), moment(15)])
        #expect(requests.first?.body.contains("Stage 2") == true)
    }

    @Test
    func test_notificationProjection_manualPause_stopsAtPause() {
        let state = WorkoutTimerFeature.State.fixture(.running, schedule: Schedules.withPause, elapsed: 0)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        #expect(state.notificationProjection(at: origin, language: "en").events.map(\.key) == ["stage.1"])
    }

    @Test
    func test_notificationProjection_disabled_isEmpty() {
        let state = WorkoutTimerFeature.State.fixture(.running)
        state.$isBackgroundNotificationsOn = SharedReader(value: false)
        #expect(state.notificationProjection(at: origin, language: "en").events.isEmpty)
    }

    @Test
    func test_notificationProjection_largeSchedule_limitsWindowAndAddsReopenToLastRealEvent() {
        let workout = Workout(
            id: timerWorkoutID,
            training: [makeStage(1, seconds: 10), makeStage(2, seconds: 5, .rest)],
            trainingRounds: 30
        )
        let state = WorkoutTimerFeature.State.fixture(.running, schedule: WorkoutSchedule(workout: workout), elapsed: 0)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        let projection = state.notificationProjection(at: origin, language: "en")
        let requests = state.notificationRequests(at: origin, language: "en")
        #expect(projection.events.count == 32)
        #expect(projection.hasMore)
        #expect(requests.count == 32)
        #expect(requests.last?.body.contains("CircuitTimer") == true)
        #expect(requests.dropLast().allSatisfy { !$0.body.contains("CircuitTimer") })
    }

    @Test
    func test_notificationsSynced_emptyCleanPlan_keepsSchedulingFailure() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: false)
        state.notifications.hasSchedulingFailed = true
        state.notifications.projection = state.notificationProjection(at: origin, language: "en")
        state.notifications.revision = 1
        state.notifications.needsRetry = true
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.date = .constant(origin)
            $0.preferredLocales = [Locale(identifier: "en")]
        }
        await store.send(.internal(.notificationsSynced(revision: 1, report: NotificationSyncReport()))) {
            $0.notifications.needsRetry = false
        }
        #expect(store.state.notifications.hasSchedulingFailed)
    }

    @Test
    func test_notificationsSynced_nonemptyVerifiedPlan_clearsSchedulingFailure() async {
        var state = WorkoutTimerFeature.State.fixture(.running)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        state.notifications.hasSchedulingFailed = true
        state.notifications.projection = state.notificationProjection(at: origin, language: "en")
        state.notifications.revision = 1
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.date = .constant(origin)
            $0.preferredLocales = [Locale(identifier: "en")]
        }
        await store.send(.internal(.notificationsSynced(revision: 1, report: NotificationSyncReport()))) {
            $0.notifications.hasSchedulingFailed = false
        }
    }

    @Test
    func test_notificationsSynced_imminentUnconfirmed_keepsFailureAndDoesNotHotLoop() async {
        var state = WorkoutTimerFeature.State.fixture(.running)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        state.notifications.projection = state.notificationProjection(at: origin, language: "en")
        state.notifications.revision = 1
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.date = .constant(origin)
            $0.preferredLocales = [Locale(identifier: "en")]
        }
        await store.send(.internal(.notificationsSynced(revision: 1, report: NotificationSyncReport(imminentUnconfirmed: 1)))) {
            $0.notifications.hasSchedulingFailed = true
            $0.notifications.needsRetry = true
        }
        await store.finish()
    }

    @Test
    func test_notifications_retryClock_retriesAfterTenSecondsWithoutRestartingTimer() async {
        let clock = TestClock<Duration>()
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        state.notifications.access = .authorized
        state.notifications.projection = state.notificationProjection(at: origin, language: "en")
        state.notifications.revision = 1
        state.notifications.needsRetry = true
        state.notifications.hasSchedulingFailed = true
        state.notifications.lastAttempt = MonotonicInstant(now: clock)
        let calls = LockIsolated(0)
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.date = .constant(origin)
            $0.preferredLocales = [Locale(identifier: "en")]
            $0.continuousClock = clock
            $0.backgroundNotifications.sync = { _, _, _ in
                calls.withValue { $0 += 1 }
                return NotificationSyncReport()
            }
        }
        await store.send(.internal(.cueFinished(revision: 0, CueResult())))
        await clock.advance(by: .seconds(9))
        await store.send(.internal(.cueFinished(revision: 0, CueResult())))
        #expect(calls.value == 0)
        await clock.advance(by: .seconds(1))
        await store.send(.internal(.cueFinished(revision: 0, CueResult()))) {
            $0.notifications.revision = 2
            $0.notifications.lastAttempt = MonotonicInstant(now: clock)
        }
        await store.receive(.internal(.notificationsSynced(revision: 2, report: NotificationSyncReport()))) {
            $0.notifications.needsRetry = false
        }
        #expect(calls.value == 1)
        #expect(store.state.clockGeneration == 1)
        #expect(store.state.notifications.hasSchedulingFailed)
    }

    @Test
    func test_notifications_preferredContentLanguageChanged_updatesProjectionKey() async {
        let clock = TestClock<Duration>()
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        state.notifications.access = .authorized
        state.notifications.projection = state.notificationProjection(at: origin, language: "en")
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.date = .constant(origin)
            $0.continuousClock = clock
            $0.preferredLocales = [Locale(identifier: "ru")]
            $0.backgroundNotifications.sync = { _, _, _ in NotificationSyncReport() }
        }
        await store.send(.internal(.cueFinished(revision: 0, CueResult()))) {
            $0.notifications.projection = $0.notificationProjection(at: origin, language: "ru")
            $0.notifications.revision = 1
            $0.notifications.lastAttempt = MonotonicInstant(now: clock)
        }
        await store.receive(.internal(.notificationsSynced(revision: 1, report: NotificationSyncReport())))
        #expect(store.state.notifications.projection?.language == "ru")
        #expect(store.state.clockGeneration == 1)
    }

    @Test
    func test_notificationResult_oldRevision_doesNotClearFailure() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: false)
        state.notifications.revision = 2
        state.notifications.hasSchedulingFailed = true
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.date = .constant(origin)
            $0.preferredLocales = [Locale(identifier: "en")]
        }
        await store.send(.internal(.notificationsSynced(revision: 1, report: nil)))
    }

    @Test
    func test_notificationAccess_latestReadFailed_clearsStalePermissionAndShowsUnknown() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        state.notifications.access = .authorized
        state.notifications.accessGeneration = 1
        state.notifications.projection = state.notificationProjection(at: origin, language: "en")
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.date = .constant(origin)
            $0.preferredLocales = [Locale(identifier: "en")]
        }
        await store.send(.internal(.notificationAccessLoaded(generation: 1, nil))) {
            $0.notifications.access = nil
        }
        #expect(store.state.notificationFootnote == "timer.notifications.unknown")
    }

    @Test
    func test_notificationAccess_oldGeneration_doesNotOverwriteCurrentAccess() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: false)
        state.notifications.accessGeneration = 2
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.date = .constant(origin)
            $0.preferredLocales = [Locale(identifier: "en")]
        }
        let access = NotificationAccess(authorization: .authorized, showsAlerts: true, playsSound: true)
        await store.send(.internal(.notificationAccessLoaded(generation: 1, access)))
    }
}
