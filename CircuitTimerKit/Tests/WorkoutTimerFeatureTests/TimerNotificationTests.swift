@testable import WorkoutTimerFeature

import BackgroundNotifications
import ComposableArchitecture
import Foundation
import Testing
import WorkoutActivity
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
        #expect(requests.allSatisfy { $0.title == "Workout" })
    }

    @Test
    func test_notificationProjection_manualPause_stopsAtPause() {
        let state = WorkoutTimerFeature.State.fixture(.running, schedule: Schedules.withPause, elapsed: 0)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        #expect(state.notificationProjection(at: origin, language: "en").events.map(\.key) == ["stage.1"])
    }

    @Test
    func test_notificationRequests_unnamedStagesUseEnglishFallbackAndFinishBody() throws {
        let workout = Workout(
            id: timerWorkoutID,
            training: [
                makeStage(1, seconds: 2, name: ""),
                makeStage(2, seconds: 2, .rest, name: " ")
            ]
        )
        let state = WorkoutTimerFeature.State.fixture(
            .running,
            schedule: WorkoutSchedule(workout: workout),
            elapsed: 0
        )
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        let requests = state.notificationRequests(at: origin, language: "en")
        #expect(requests.map(\.key) == ["stage.1", "finish"])
        #expect(requests.first?.body.contains("Rest") == true)
        #expect(requests.last?.body == "Workout finished.")
        #expect(state.run.schedule.stages.first.map(WorkoutTimerFeature.State.displayName) == "Work")
        #expect(state.run.schedule.stages.dropFirst().first.map(WorkoutTimerFeature.State.displayName) == "Rest")
        let pause = try #require(Schedules.withPause.stages.first { $0.kind == .pause })
        #expect(WorkoutTimerFeature.State.displayName(pause) == "Pause")
    }

    @Test
    func test_notificationProjection_unavailable_isEmpty() {
        for reason in 0..<4 {
            var state = WorkoutTimerFeature.State.fixture(.running)
            state.$isBackgroundNotificationsOn = SharedReader(value: reason != 0)
            if reason == 1 { state.countdown = WorkoutTimerFeature.Countdown(.resume) }
            if reason == 2 {
                state.notifications.access = NotificationAccess(authorization: .denied, showsAlerts: false, playsSound: false)
            }
            let projection = state.notificationProjection(at: origin, language: "en")
            if reason == 3 {
                #expect(projection.events.map(\.key) == ["stage.1", "finish"])
            } else {
                #expect(projection.events.isEmpty)
                #expect(!projection.hasMore)
            }
        }
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
            $0.liveActivity = .previewValue
            $0.date = .constant(origin)
            $0.preferredLocales = [Locale(identifier: "en")]
        }
        await store.send(.internal(.notificationsSynced(revision: 1, report: NotificationSyncReport()))) {
            $0.notifications.completedRevision = 1
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
            $0.liveActivity = .previewValue
            $0.date = .constant(origin)
            $0.preferredLocales = [Locale(identifier: "en")]
        }
        await store.send(.internal(.notificationsSynced(revision: 1, report: NotificationSyncReport()))) {
            $0.notifications.completedRevision = 1
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
            $0.liveActivity = .previewValue
            $0.date = .constant(origin)
            $0.preferredLocales = [Locale(identifier: "en")]
        }
        await store.send(.internal(.notificationsSynced(revision: 1, report: NotificationSyncReport(imminentUnconfirmed: 1)))) {
            $0.notifications.completedRevision = 1
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
            $0.liveActivity = .previewValue
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
            $0.notifications.completedRevision = 2
            $0.notifications.needsRetry = false
        }
        #expect(calls.value == 1)
        #expect(store.state.clockGeneration == 1)
        #expect(store.state.notifications.hasSchedulingFailed)
    }

    @Test(arguments: ["ru", "en"])
    func test_notifications_preferredContentLanguageChanged_updatesProjectionKey(language: String) async {
        let clock = TestClock<Duration>()
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        state.notifications.access = .authorized
        let previousLanguage = language == "ru" ? "en" : "ru"
        state.notifications.projection = state.notificationProjection(at: origin, language: previousLanguage)
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.liveActivity = .previewValue
            $0.date = .constant(origin)
            $0.continuousClock = clock
            $0.preferredLocales = language == "ru" ? [Locale(identifier: "ru")] : []
            $0.backgroundNotifications.sync = { _, _, _ in NotificationSyncReport() }
        }
        await store.send(.internal(.cueFinished(revision: 0, CueResult()))) {
            $0.notifications.projection = $0.notificationProjection(at: origin, language: language)
            $0.notifications.revision = 1
            $0.notifications.lastAttempt = MonotonicInstant(now: clock)
        }
        await store.receive(.internal(.notificationsSynced(revision: 1, report: NotificationSyncReport()))) {
            $0.notifications.completedRevision = 1
        }
        #expect(store.state.notifications.projection?.language == language)
        #expect(store.state.clockGeneration == 1)
    }

    @Test
    func test_notificationResult_oldRevision_doesNotClearFailure() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: false)
        state.notifications.revision = 2
        state.notifications.hasSchedulingFailed = true
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.liveActivity = .previewValue
            $0.date = .constant(origin)
            $0.preferredLocales = [Locale(identifier: "en")]
        }
        await store.send(.internal(.notificationsSynced(revision: 1, report: nil)))
    }

    @Test
    func test_notificationsSynced_failedCurrentReport_setsFailureAndRetry() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: false)
        state.notifications.revision = 1
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.liveActivity = .previewValue
            $0.date = .constant(origin)
        }
        await store.send(.internal(.notificationsSynced(revision: 1, report: nil))) {
            $0.notifications.completedRevision = 1
            $0.notifications.hasSchedulingFailed = true
            $0.notifications.needsRetry = true
        }
    }

    @Test
    func test_notificationsSynced_supersededCurrentReport_isIgnored() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: false)
        state.notifications.revision = 1
        state.notifications.hasSchedulingFailed = true
        state.notifications.needsRetry = true
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.liveActivity = .previewValue
            $0.date = .constant(origin)
        }
        await store.send(.internal(.notificationsSynced(revision: 1, report: NotificationSyncReport(superseded: true))))
        #expect(store.state.notifications.hasSchedulingFailed)
        #expect(store.state.notifications.needsRetry)
    }

    @Test
    func test_notificationAccess_latestReadFailed_clearsStalePermissionAndShowsUnknown() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        state.notifications.access = .authorized
        state.notifications.accessGeneration = 1
        state.notifications.projection = state.notificationProjection(at: origin, language: "en")
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.liveActivity = .previewValue
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
            $0.liveActivity = .previewValue
            $0.date = .constant(origin)
            $0.preferredLocales = [Locale(identifier: "en")]
        }
        let access = NotificationAccess(authorization: .authorized, showsAlerts: true, playsSound: true)
        await store.send(.internal(.notificationAccessLoaded(generation: 1, access)))
    }

    @Test
    func test_notificationAccess_oldGeneration_whileEnabled_keepsCurrentCoverage() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        state.notifications.access = .authorized
        state.notifications.accessGeneration = 2
        state.notifications.projection = state.notificationProjection(at: origin, language: "en")
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.liveActivity = .previewValue
            $0.date = .constant(origin)
            $0.preferredLocales = [Locale(identifier: "en")]
        }
        let denied = NotificationAccess(authorization: .denied, showsAlerts: false, playsSound: false)
        await store.send(.internal(.notificationAccessLoaded(generation: 1, denied)))
        #expect(store.state.notifications.access == .authorized)
        #expect(store.state.notifications.access?.canDeliver == true)
        #expect(store.state.notificationFootnote == nil)
    }

    @Test
    func test_notificationFootnote_prioritizesPermissionThenScheduling() {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: false)
        state.notifications.hasSchedulingFailed = true
        #expect(state.notificationFootnote == nil)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        #expect(state.notificationFootnote == "timer.notifications.unknown")
        state.notifications.access = NotificationAccess(authorization: .notDetermined, showsAlerts: false, playsSound: false)
        #expect(state.notificationFootnote == "timer.notifications.notAsked")
        state.notifications.access = NotificationAccess(authorization: .denied, showsAlerts: false, playsSound: false)
        #expect(state.notificationFootnote == "timer.notifications.denied")
        state.notifications.access = NotificationAccess(authorization: .authorized, showsAlerts: false, playsSound: true)
        #expect(state.notificationFootnote == "timer.notifications.alertsOff")
        state.notifications.access = .authorized
        #expect(state.notificationFootnote == "timer.notifications.failed")
        state.notifications.hasSchedulingFailed = false
        #expect(state.notificationFootnote == nil)
    }

    @Test(arguments: [false, true])
    func test_notificationsSynced_unknownAccessLearnsBlockedStatusWithoutRetry(alertsDisabled: Bool) async {
        let clock = TestClock<Duration>()
        let access = NotificationAccess(
            authorization: alertsDisabled ? .authorized : .denied,
            showsAlerts: false,
            playsSound: false
        )
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        state.notifications.accessGeneration = 1
        state.notifications.revision = 1
        state.notifications.needsRetry = true
        state.notifications.lastAttempt = MonotonicInstant(now: clock)
        state.notifications.projection = state.notificationProjection(at: origin, language: "en")
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.liveActivity = .previewValue
            $0.date = .constant(origin)
            $0.continuousClock = clock
            $0.preferredLocales = [Locale(identifier: "en")]
        }
        let report = NotificationSyncReport(access: access)
        await store.send(.internal(.notificationsSynced(revision: 1, report: report))) {
            $0.notifications.completedRevision = 1
            $0.notifications.access = access
            $0.notifications.accessGeneration = 2
            $0.notifications.needsRetry = false
        }
        #expect(store.state.notificationFootnote == (alertsDisabled ? "timer.notifications.alertsOff" : "timer.notifications.denied"))
        await store.send(.internal(.notificationAccessLoaded(generation: 1, nil)))
        await clock.advance(by: .seconds(10))
        await store.send(.internal(.cueFinished(revision: 0, CueResult())))
        await store.finish()
        #expect(!store.state.notifications.hasSchedulingFailed)
        #expect(store.state.notifications.revision == 1)
    }

    @Test
    func test_notificationsSynced_blockedWithoutAccess_doesNotInventPermissionStatus() {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        state.notifications.revision = 1
        WorkoutTimerFeature().notificationsSynced(revision: 1, report: NotificationSyncReport(canDeliver: false), &state)
        #expect(state.notifications.access == nil)
        #expect(!state.notifications.needsRetry)
        #expect(!state.notifications.hasSchedulingFailed)
    }

    @Test
    func test_notificationsSynced_accessSnapshot_doesNotReplaceKnownPermission() {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        state.notifications.access = .authorized
        state.notifications.revision = 1
        let denied = NotificationAccess(authorization: .denied, showsAlerts: false, playsSound: false)
        WorkoutTimerFeature().notificationsSynced(revision: 1, report: NotificationSyncReport(access: denied), &state)
        #expect(state.notifications.access == .authorized)
    }

    @Test
    func test_syncNotifications_beforeClockAppears_hasNoEffect() async {
        let state = WorkoutTimerFeature.State.appearing()
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        let calls = LockIsolated(0)
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.liveActivity = .previewValue
            $0.date = .constant(origin)
            $0.cues = .previewValue
            $0.backgroundNotifications.sync = { _, _, _ in
                calls.withValue { $0 += 1 }
                return NotificationSyncReport()
            }
        }
        await store.send(.view(.notificationPreferencesChanged))
        await store.finish()
        #expect(calls.value == 0)
        #expect(store.state.notifications.projection == nil)
    }

}
