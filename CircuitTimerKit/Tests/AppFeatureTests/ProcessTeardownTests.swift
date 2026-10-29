@testable import AppFeature

import BackgroundNotifications
import ComposableArchitecture
import Foundation
import Testing
import WorkoutActivity
import WorkoutHealth

@Suite(.timeLimit(.minutes(1)))
struct ProcessTeardownTests {
    private struct FakeError: Error {}

    /// A clock whose sleep fails at once with an error that is not cancellation.
    private struct FailingClock: Clock {
        let base = TestClock<Duration>()

        var now: TestClock<Duration>.Instant { base.now }
        var minimumResolution: Duration { base.minimumResolution }

        func sleep(until deadline: TestClock<Duration>.Instant, tolerance: Duration?) async throws {
            throw FakeError()
        }
    }

    private let calls = LockIsolated<[String]>([])
    private let healthEnds = LockIsolated<[Date]>([])
    private let clock = TestClock<Duration>()
    private let activityGate = Gate()
    private let notificationGate = Gate()
    private static let date = Date(timeIntervalSince1970: 1_000)

    /// Waits for `gate` in a task of its own, so cancelling the caller does not end the wait.
    private static func ignoringCancellation(_ gate: Gate) async {
        await Task.detached { await gate.wait() }.value
    }

    private func teardown(
        endActivities: @escaping @Sendable () async -> Void = {},
        finishNotifications: @escaping @Sendable () async -> Void = {},
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
        return ProcessTeardown(notifications: notifications, liveActivity: liveActivity, health: health, clock: clock)
    }

    @Test
    func test_begin_closesEveryGateSynchronously() {
        teardown(clock: clock).begin()

        #expect(calls.value == ["notifications", "liveActivity", "health"])
    }

    @Test
    func test_run_endsCardsAndNotificationsTogetherThenHealthLastWithTheDate() async {
        let activityStarted = LockIsolated(false)
        let notificationsStarted = LockIsolated(false)
        let teardown = teardown(
            endActivities: { [activityGate] in
                activityStarted.setValue(true)
                await activityGate.wait()
            },
            finishNotifications: { [notificationGate] in
                notificationsStarted.setValue(true)
                await notificationGate.wait()
            },
            clock: clock
        )
        let running = Task { await teardown.run(at: Self.date) }
        await Task.megaYield()
        #expect(activityStarted.value)
        #expect(notificationsStarted.value)
        #expect(healthEnds.value.isEmpty)

        activityGate.open()
        notificationGate.open()
        await running.value

        #expect(healthEnds.value == [Self.date])
    }

    @Test
    func test_run_workIgnoringCancellation_doesNotHoldHealthPastTheLimitsWhichRunTogether() async {
        let teardown = teardown(
            endActivities: { [activityGate] in await Self.ignoringCancellation(activityGate) },
            finishNotifications: { [notificationGate] in await Self.ignoringCancellation(notificationGate) },
            clock: clock
        )
        let running = Task { await teardown.run(at: Self.date) }
        await Task.megaYield()

        await clock.advance(by: ProcessTeardown.notificationBarrier)
        #expect(healthEnds.value.isEmpty)
        // Both limits count from the same start, so the card's limit ends the wait, not the sum of the two.
        await clock.advance(by: ProcessTeardown.liveActivityLimit - ProcessTeardown.notificationBarrier)
        await running.value
        #expect(healthEnds.value == [Self.date])

        activityGate.open()
        notificationGate.open()
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
