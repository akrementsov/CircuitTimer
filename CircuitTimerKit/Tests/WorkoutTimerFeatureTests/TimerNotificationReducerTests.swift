@testable import WorkoutTimerFeature

import BackgroundNotifications
import ComposableArchitecture
import Foundation
import Testing
import WorkoutActivity
import WorkoutDomain

@MainActor
struct TimerNotificationReducerTests {
    @Test
    func test_notificationRefresh_taskAndActiveReadAccessAndActiveRemovesDelivered() async {
        let clock = TestClock<Duration>()
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        state.notifications.projection = state.notificationProjection(at: origin, language: "en")
        let reads = LockIsolated(0)
        let removed = LockIsolated<[UUID]>([])
        let syncGate = AsyncStream<Void>.makeStream()
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.liveActivity = .previewValue
            $0.date = .constant(origin)
            $0.continuousClock = clock
            $0.preferredLocales = [Locale(identifier: "en")]
            $0.backgroundNotifications.access = {
                reads.withValue { $0 += 1 }
                return .authorized
            }
            $0.backgroundNotifications.removeDelivered = { owner in
                removed.withValue { $0.append(owner) }
            }
            $0.backgroundNotifications.sync = { _, _, _ in
                for await _ in syncGate.stream { break }
                return NotificationSyncReport()
            }
        }
        await store.send(.view(.task)) { $0.notifications.accessGeneration = 1 }
        await store.receive(.internal(.notificationAccessLoaded(generation: 1, .authorized))) {
            $0.notifications.access = .authorized
        }
        #expect(reads.value == 1)
        await store.send(.view(.scenePhaseChanged(.active))) {
            $0.isSceneActive = true
            $0.notifications.accessGeneration = 2
            $0.notifications.revision = 1
            $0.notifications.lastAttempt = MonotonicInstant(now: clock)
            $0.signals.last = SignalMoment($0)
        }
        await store.receive(.internal(.notificationAccessLoaded(generation: 2, .authorized)))
        syncGate.continuation.yield(())
        await store.receive(.internal(.notificationsSynced(revision: 1, report: NotificationSyncReport())))
        #expect(reads.value == 2)
        #expect(removed.value == [timerID])
    }

    @Test
    func test_notificationRefresh_disabledSkipsAccessAndDeliveredRemoval() async {
        let state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: false)
        let calls = LockIsolated(0)
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.liveActivity = .previewValue
            $0.date = .constant(origin)
            $0.backgroundNotifications.access = {
                calls.withValue { $0 += 1 }
                return .authorized
            }
            $0.backgroundNotifications.removeDelivered = { _ in calls.withValue { $0 += 1 } }
        }
        await store.send(.view(.task))
        await store.send(.view(.scenePhaseChanged(.active))) {
            $0.isSceneActive = true
            $0.signals.last = SignalMoment($0)
        }
        #expect(calls.value == 0)
    }

    @Test
    func test_notificationPreferencesChanged_soundOffResyncsSilentRequests() async {
        let clock = TestClock<Duration>()
        var state = WorkoutTimerFeature.State.fixture(.running, elapsed: 0)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        state.notifications.access = .authorized
        state.notifications.projection = state.notificationProjection(at: origin, language: "en")
        state.$isSoundOn = SharedReader(value: false)
        let plans = LockIsolated<[[ScheduledNotification]]>([])
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.liveActivity = .previewValue
            $0.date = .constant(origin)
            $0.continuousClock = clock
            $0.preferredLocales = [Locale(identifier: "en")]
            $0.backgroundNotifications.access = { throw CancellationError() }
            $0.backgroundNotifications.sync = { _, _, requests in
                plans.withValue { $0.append(requests) }
                return NotificationSyncReport()
            }
        }
        await store.send(.view(.notificationPreferencesChanged)) {
            $0.notifications.accessGeneration = 1
            $0.notifications.projection = $0.notificationProjection(at: origin, language: "en")
            $0.notifications.revision = 1
            $0.notifications.lastAttempt = MonotonicInstant(now: clock)
        }
        await store.receive(.internal(.notificationsSynced(revision: 1, report: NotificationSyncReport())))
        #expect(store.state.notifications.projection?.isAudible == false)
        #expect(plans.value.count == 1)
        #expect(plans.value.first?.allSatisfy { !$0.isAudible } == true)
        #expect(store.state.clockGeneration == 1)
    }

    @Test
    func test_notificationAccess_deliveryChangesClearAndRestoreWindowWithoutClockRestart() async {
        let clock = TestClock<Duration>()
        var state = WorkoutTimerFeature.State.fixture(.running, elapsed: 0)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        state.$isSoundOn = SharedReader(value: false)
        state.notifications.access = .authorized
        state.notifications.accessGeneration = 1
        state.notifications.projection = state.notificationProjection(at: origin, language: "en")
        let plans = LockIsolated<[[ScheduledNotification]]>([])
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.liveActivity = .previewValue
            $0.date = .constant(origin)
            $0.continuousClock = clock
            $0.preferredLocales = [Locale(identifier: "en")]
            $0.backgroundNotifications.sync = { _, _, requests in
                plans.withValue { $0.append(requests) }
                return NotificationSyncReport()
            }
        }
        let denied = NotificationAccess(authorization: .denied, showsAlerts: false, playsSound: false)
        await store.send(.internal(.notificationAccessLoaded(generation: 1, denied))) {
            $0.notifications.access = denied
            $0.notifications.projection = $0.notificationProjection(at: origin, language: "en")
            $0.notifications.revision = 1
            $0.notifications.lastAttempt = MonotonicInstant(now: clock)
        }
        await store.receive(.internal(.notificationsSynced(revision: 1, report: NotificationSyncReport())))
        #expect(plans.value == [[]])
        await store.send(.internal(.notificationAccessLoaded(generation: 1, .authorized))) {
            $0.notifications.access = .authorized
            $0.notifications.projection = $0.notificationProjection(at: origin, language: "en")
            $0.notifications.revision = 2
            $0.notifications.lastAttempt = MonotonicInstant(now: clock)
        }
        await store.receive(.internal(.notificationsSynced(revision: 2, report: NotificationSyncReport())))
        #expect(plans.value.count == 2)
        #expect(plans.value.last?.map(\.key) == ["stage.1", "finish"])
        #expect(store.state.clockGeneration == 1)
    }

    @Test
    func test_ticked_stageTransitionRefillsNotificationWindowWithoutClockRestart() async {
        let clock = TestClock<Duration>()
        let wall = LockIsolated(origin)
        var state = WorkoutTimerFeature.State.fixture(.running, elapsed: 9)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        state.$isSoundOn = SharedReader(value: false)
        state.notifications.access = .authorized
        state.notifications.projection = state.notificationProjection(at: origin, language: "en")
        let plans = LockIsolated<[[ScheduledNotification]]>([])
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.liveActivity = .previewValue
            $0.date = DateGenerator { wall.value }
            $0.continuousClock = clock
            $0.preferredLocales = [Locale(identifier: "en")]
            $0.backgroundNotifications.sync = { _, _, requests in
                plans.withValue { $0.append(requests) }
                return NotificationSyncReport()
            }
        }
        wall.setValue(moment(2))
        await clock.advance(by: .seconds(2))
        await store.send(.internal(.ticked(generation: 1, isFinal: false))) {
            $0.run.tick(at: moment(2))
            $0.snapshot = $0.run.snapshot(at: moment(2))
            $0.clockAnchor = ClockAnchor(
                date: moment(2), instant: MonotonicInstant(now: clock), totalElapsed: $0.snapshot.totalElapsed
            )
            $0.notifications.projection = $0.notificationProjection(at: moment(2), language: "en")
            $0.notifications.revision = 1
            $0.notifications.lastAttempt = MonotonicInstant(now: clock)
        }
        await store.receive(.internal(.notificationsSynced(revision: 1, report: NotificationSyncReport())))
        #expect(plans.value.last?.map(\.key) == ["finish"])
        #expect(store.state.clockGeneration == 1)
    }

    @Test
    func test_notificationPreferencesChanged_toggleOffCancelsReadAndClearsPreviousWindow() async throws {
        let clock = TestClock<Duration>()
        let preference = Shared(value: true)
        var state = WorkoutTimerFeature.State.fixture(.running, elapsed: 0)
        state.$isBackgroundNotificationsOn = SharedReader(preference)
        state.$isSoundOn = SharedReader(value: false)
        state.notifications.access = .authorized
        state.notifications.accessGeneration = 1
        state.notifications.projection = state.notificationProjection(at: origin, language: "ru")
        let started = AsyncStream<CheckedContinuation<NotificationAccess, Never>>.makeStream()
        let cancelled = AsyncStream<Void>.makeStream()
        let plans = LockIsolated<[[ScheduledNotification]]>([])
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.liveActivity = .previewValue
            $0.date = .constant(origin)
            $0.continuousClock = clock
            $0.preferredLocales = [Locale(identifier: "ru")]
            $0.backgroundNotifications.access = {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        started.continuation.yield(continuation)
                    }
                } onCancel: {
                    cancelled.continuation.yield(())
                }
            }
            $0.backgroundNotifications.sync = { _, _, requests in
                plans.withValue { $0.append(requests) }
                return NotificationSyncReport()
            }
        }
        var starts = started.stream.makeAsyncIterator()
        var cancellations = cancelled.stream.makeAsyncIterator()
        await store.send(.view(.task)) { $0.notifications.accessGeneration = 2 }
        let accessReply = try #require(await starts.next())
        preference.withLock { $0 = false }
        await store.send(.view(.notificationPreferencesChanged)) {
            $0.notifications.accessGeneration = 3
            $0.notifications.access = nil
            $0.notifications.projection = $0.notificationProjection(at: origin, language: "ru")
            $0.notifications.revision = 1
            $0.notifications.lastAttempt = MonotonicInstant(now: clock)
        }
        _ = try #require(await cancellations.next())
        accessReply.resume(returning: .authorized)
        await store.receive(.internal(.notificationsSynced(revision: 1, report: NotificationSyncReport())))
        await store.finish()
        #expect(plans.value == [[]])
        #expect(store.state.notifications.projection?.language == "ru")
        #expect(store.state.notifications.access == nil)
        #expect(store.state.notifications.accessGeneration == 3)
    }

    @Test
    func test_notificationPreferencesChanged_disabledWithoutHistoryDoesNothing() async {
        let state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: false)
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.liveActivity = .previewValue
            $0.date = .constant(origin)
        }
        await store.send(.view(.notificationPreferencesChanged))
        #expect(store.state.notifications.accessGeneration == 0)
        #expect(store.state.notifications.projection == nil)
    }

    @Test
    func test_notificationEffects_cancellationSendsNoResult() async {
        let clock = TestClock<Duration>()
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        state.notifications.projection = state.notificationProjection(at: origin, language: "en")
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.liveActivity = .previewValue
            $0.date = .constant(origin)
            $0.continuousClock = clock
            $0.preferredLocales = [Locale(identifier: "en")]
            $0.backgroundNotifications.access = { throw CancellationError() }
            $0.backgroundNotifications.sync = { _, _, _ in throw CancellationError() }
            $0.backgroundNotifications.removeDelivered = { _ in }
        }
        await store.send(.view(.task)) { $0.notifications.accessGeneration = 1 }
        await store.send(.view(.scenePhaseChanged(.active))) {
            $0.isSceneActive = true
            $0.notifications.accessGeneration = 2
            $0.notifications.revision = 1
            $0.notifications.lastAttempt = MonotonicInstant(now: clock)
            $0.signals.last = SignalMoment($0)
        }
        await store.finish()
        #expect(!store.state.notifications.hasSchedulingFailed)
    }

    enum NotificationEntry: CaseIterable, Sendable {
        case paused
        case waiting
        case countdown
        case finished
    }

    @Test(arguments: NotificationEntry.allCases)
    func test_notificationPhaseEntry_clearsPendingRequests(entry: NotificationEntry) async {
        let schedule = entry == .waiting ? Schedules.withPause : Schedules.workRest
        let phase: TimerPhase = entry == .countdown ? .idle : .running
        let elapsed: Double = switch entry {
            case .paused: 3
            case .waiting: 1
            case .countdown: 0
            case .finished: 12
        }
        var state = WorkoutTimerFeature.State.fixture(phase, schedule: schedule, elapsed: elapsed)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        state.$isSoundOn = SharedReader(value: false)
        state.notifications.access = .authorized
        state.notifications.projection = entry == .countdown
            ? WorkoutTimerFeature.NotificationProjection(
                events: [.init(key: "stage.1", epochMs: 1)],
                language: "en",
                isAudible: false,
                hasMore: false
            )
            : state.notificationProjection(at: origin, language: "en")
        let timer = TimerHarness(state, notifications: true)
        let plans = LockIsolated<[[ScheduledNotification]]>([])
        let syncGate = AsyncStream<Void>.makeStream()
        timer.store.dependencies.backgroundNotifications.sync = { _, _, requests in
            plans.withValue { $0.append(requests) }
            for await _ in syncGate.stream { break }
            return NotificationSyncReport()
        }
        if entry == .waiting {
            timer.moveWall(seconds: 2)
            await timer.clock.advance(by: .seconds(2))
        }
        let now = timer.now
        let action: WorkoutTimerFeature.Action = switch entry {
            case .paused, .countdown: .view(.playPauseButtonTapped)
            case .waiting: .internal(.ticked(generation: 1, isFinal: false))
            case .finished: .view(.nextButtonTapped)
        }
        await timer.send(action, saving: true) {
            switch entry {
                case .paused:
                    $0.run.pause(at: now)
                    $0.settle(at: now)
                    $0.clockGeneration = 2
                    $0.clockAnchor = nil
                    $0.requestedAwake = false
                    $0.awakeRevision = 2
                case .waiting:
                    $0.settle(at: now)
                    $0.clockGeneration = 2
                    $0.clockAnchor = nil
                    $0.requestedAwake = false
                    $0.awakeRevision = 2
                case .countdown:
                    $0.countdown = WorkoutTimerFeature.Countdown(.start)
                    $0.clockGeneration = 2
                    $0.requestedAwake = true
                    $0.awakeRevision = 3
                case .finished:
                    $0.run.skipToNextStage(at: now)
                    $0.settle(at: now)
                    $0.clockGeneration = 2
                    $0.clockAnchor = nil
                    $0.requestedAwake = false
                    $0.awakeRevision = 2
            }
            $0.notifications.projection = $0.notificationProjection(at: now, language: "en")
            $0.notifications.revision = 1
            $0.notifications.lastAttempt = MonotonicInstant(now: timer.clock)
        }
        syncGate.continuation.yield(())
        await timer.receive(.internal(.notificationsSynced(revision: 1, report: NotificationSyncReport())))
        #expect(plans.value == [[]])
        #expect(timer.store.state.notifications.projection?.events.isEmpty == true)
        await timer.cancelClockLoop()
    }

    @Test
    func test_scenePhaseChanged_backwardWallClock_rebasesNotificationDatesAndKeys() async throws {
        var state = WorkoutTimerFeature.State.fixture(.running)
        state.$isSoundOn = SharedReader(value: false)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        state.notifications.access = .authorized
        state.notifications.projection = state.notificationProjection(at: origin, language: "en")
        let timer = TimerHarness(state, notifications: true)
        timer.store.dependencies.continuousClock = SuspendingClock(base: timer.clock)
        let plans = LockIsolated<[[ScheduledNotification]]>([])
        let gate = AsyncStream<Void>.makeStream()
        timer.store.dependencies.backgroundNotifications.access = { throw CancellationError() }
        timer.store.dependencies.backgroundNotifications.sync = { _, _, requests in
            plans.withValue { $0.append(requests) }
            for await _ in gate.stream { break }
            return NotificationSyncReport()
        }

        await timer.send(.view(.scenePhaseChanged(.background)), saving: true) {
            $0.isInBackground = true
            $0.clockGeneration = 2
            $0.clockAnchor = timer.anchor(totalElapsed: .seconds(3))
        }
        await timer.clock.advance(by: .seconds(4))
        timer.moveWall(seconds: -10)
        let now = timer.now
        var expectedRun = timer.store.state.run
        expectedRun.rebase(at: now, keepingTotalElapsed: .seconds(7))
        let expected = expectedRun.upcomingTransitions(at: now, limit: 32)

        await timer.send(.view(.scenePhaseChanged(.active)), saving: true) {
            $0.isInBackground = false
            $0.run.rebase(at: now, keepingTotalElapsed: .seconds(7))
            $0.settle(at: now)
            $0.clockGeneration = 3
            $0.clockAnchor = timer.anchor(totalElapsed: .seconds(7))
            $0.notifications.accessGeneration = 1
            $0.notifications.projection = $0.notificationProjection(at: now, language: "en")
            $0.notifications.revision = 1
            $0.notifications.lastAttempt = MonotonicInstant(now: timer.clock)
        }
        gate.continuation.yield(())
        await timer.receive(.internal(.notificationsSynced(revision: 1, report: NotificationSyncReport())))
        let requests = try #require(plans.value.last)
        #expect(requests.map(\.fireDate) == expected.events.map(\.date))
        #expect(timer.store.state.notifications.projection?.events.map(\.epochMs) == expected.events.map(\.epochMs))
        #expect(requests.map(\.fireDate) == [moment(-7), moment(-2)])
        #expect(timer.store.state.clockGeneration == 3)
        await timer.cancelClockLoop()
    }

    @Test(arguments: [
        WorkoutTimerFeature.Action.View.task,
        .scenePhaseChanged(.active),
        .notificationPreferencesChanged
    ])
    func test_closeAlert_allowsNotificationRefreshActions(action: WorkoutTimerFeature.Action.View) async {
        let clock = TestClock<Duration>()
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        state.$isSoundOn = SharedReader(value: false)
        state.destination = .closeConfirmation(.closeConfirmation(restart: nil))
        let reads = LockIsolated(0)
        let plans = LockIsolated<[[ScheduledNotification]]>([])
        let store = TestStore(initialState: state) { WorkoutTimerFeature() } withDependencies: {
            $0.liveActivity = .previewValue
            $0.date = .constant(origin)
            $0.continuousClock = clock
            $0.preferredLocales = [Locale(identifier: "en")]
            $0.backgroundNotifications.access = {
                reads.withValue { $0 += 1 }
                throw CancellationError()
            }
            $0.backgroundNotifications.removeDelivered = { _ in }
            $0.backgroundNotifications.sync = { _, _, requests in
                plans.withValue { $0.append(requests) }
                return NotificationSyncReport()
            }
        }
        await store.send(.view(action)) {
            if action == .scenePhaseChanged(.active) { $0.isSceneActive = true }
            $0.notifications.accessGeneration = 1
            $0.notifications.projection = $0.notificationProjection(at: origin, language: "en")
            $0.notifications.revision = 1
            $0.notifications.lastAttempt = MonotonicInstant(now: clock)
        }
        await store.receive(.internal(.notificationsSynced(revision: 1, report: NotificationSyncReport())))
        #expect(reads.value == 1)
        #expect(plans.value == [[]])
        #expect(store.state.destination != nil)
    }
}
