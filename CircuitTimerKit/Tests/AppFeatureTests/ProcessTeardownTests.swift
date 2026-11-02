@testable import AppFeature

import BackgroundNotifications
import ComposableArchitecture
import Foundation
import Testing
import TestSupport
import WatchLink
import WorkoutActivity
import WorkoutHealth

@Suite(.timeLimit(.minutes(1)))
struct ProcessTeardownTests {
    private struct FakeError: Error {}

    /// A clock whose sleep fails at once with an error that is not cancellation.
    private struct FailingClock: Clock {
        let base = ManualClock()

        var now: ManualClock.Instant { base.now }
        var minimumResolution: Duration { base.minimumResolution }

        func sleep(until deadline: ManualClock.Instant, tolerance: Duration?) async throws {
            throw FakeError()
        }
    }

    private let calls = LockIsolated<[String]>([])
    private let healthEnds = LockIsolated<[Date]>([])
    private let clock = ManualClock()
    private let activityGate = Gate()
    private let notificationGate = Gate()
    private let watchGate = Gate()
    private static let date = Date(timeIntervalSince1970: 1_000)

    /// Waits for `gate` in a task of its own, so cancelling the caller does not end the wait.
    private static func ignoringCancellation(_ gate: Gate) async {
        await Task.detached { await gate.wait() }.value
    }

    private func teardown(
        endActivities: @escaping @Sendable () async -> Void = {},
        finishNotifications: @escaping @Sendable () async -> Void = {},
        finishWatch: @escaping @Sendable () async -> Void = {},
        clock: any Clock<Duration>
    ) -> ProcessTeardown {
        var notifications = BackgroundNotificationClient()
        notifications.beginTermination = { calls.withValue { $0.append("notifications") } }
        notifications.finishTermination = finishNotifications
        var liveActivity = LiveActivityClient()
        liveActivity.beginTermination = { calls.withValue { $0.append("liveActivity") } }
        liveActivity.endAll = endActivities
        var health = WorkoutHealthClient()
        health.beginTermination = { calls.withValue { $0.append("health") } }
        health.endAll = { date in healthEnds.withValue { $0.append(date) } }
        var watch = WatchCompanionClient()
        watch.beginTermination = { calls.withValue { $0.append("watch") } }
        watch.finishTermination = finishWatch
        return ProcessTeardown(
            notifications: notifications,
            liveActivity: liveActivity,
            health: health,
            watch: watch,
            clock: clock
        )
    }

    @Test
    func test_begin_closesEveryGateSynchronously() {
        teardown(clock: clock).begin()

        #expect(calls.value == ["notifications", "liveActivity", "health", "watch"])
    }

    /// The gates close synchronously; the watch's last state is written only in `run(at:)`.
    @Test
    func test_begin_writesNothingOnTheWatch() {
        let written = LockIsolated(false)

        teardown(finishWatch: { written.setValue(true) }, clock: clock).begin()

        #expect(!written.value)
    }

    @Test
    func test_run_endsCardsNotificationsAndTheWatchTogetherThenHealthLastWithTheDate() async {
        let activityStarted = Observed(false)
        let notificationsStarted = Observed(false)
        let watchStarted = Observed(false)
        let teardown = teardown(
            endActivities: { [activityGate] in
                activityStarted.setValue(true)
                await activityGate.wait()
            },
            finishNotifications: { [notificationGate] in
                notificationsStarted.setValue(true)
                await notificationGate.wait()
            },
            finishWatch: { [watchGate] in
                watchStarted.setValue(true)
                await watchGate.wait()
            },
            clock: clock
        )
        let running = Task { await teardown.run(at: Self.date) }
        // All three start before any finishes: each waits at its gate, which only the test opens.
        await activityStarted.wait { $0 }
        await notificationsStarted.wait { $0 }
        await watchStarted.wait { $0 }
        #expect(healthEnds.value.isEmpty)

        activityGate.open()
        notificationGate.open()
        watchGate.open()
        await running.value

        #expect(healthEnds.value == [Self.date])
    }

    @Test
    func test_run_workIgnoringCancellation_doesNotHoldHealthPastTheLimitsWhichRunTogether() async {
        let teardown = teardown(
            endActivities: { [activityGate] in await Self.ignoringCancellation(activityGate) },
            finishNotifications: { [notificationGate] in await Self.ignoringCancellation(notificationGate) },
            finishWatch: { [watchGate] in await Self.ignoringCancellation(watchGate) },
            clock: clock
        )
        let running = Task { await teardown.run(at: Self.date) }
        // Each limit sleeps on the clock, the watch's too; advancing before they all sleep would wake none.
        await clock.waitForSleeps(3)

        clock.advance(by: ProcessTeardown.notificationBarrier)
        #expect(healthEnds.value.isEmpty)
        // The limits count from the same start, so the card's limit ends the wait, not their sum, and the watch's write,
        // held past its own limit, does not hold Health either.
        clock.advance(by: ProcessTeardown.liveActivityLimit - ProcessTeardown.notificationBarrier)
        await running.value
        #expect(healthEnds.value == [Self.date])

        activityGate.open()
        notificationGate.open()
        watchGate.open()
    }

    @Test
    func test_run_clockFails_endsHealthWithoutWaitingForTheWork() async {
        let teardown = teardown(
            endActivities: { [activityGate] in await Self.ignoringCancellation(activityGate) },
            finishNotifications: { [notificationGate] in await Self.ignoringCancellation(notificationGate) },
            clock: FailingClock()
        )

        await teardown.run(at: Self.date)

        #expect(healthEnds.value == [Self.date])
        activityGate.open()
        notificationGate.open()
    }
}
