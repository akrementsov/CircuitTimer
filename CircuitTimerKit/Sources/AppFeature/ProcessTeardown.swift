import BackgroundNotifications
import ComposableArchitecture
import Foundation
import os
import WorkoutActivity
import WorkoutHealth

/// What the app does while iOS terminates it: the card and the notifications of every open timer go, and the workout
/// session ends last. The run record stays, so the next launch offers to continue.
public struct ProcessTeardown: Sendable {
    /// The whole teardown, counted from before `begin()`; iOS gives `applicationWillTerminate` about five seconds.
    public static let budget: Duration = .seconds(2)
    static let notificationBarrier: Duration = .milliseconds(300)
    static let liveActivityLimit: Duration = .seconds(1)

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "Teardown")

    private let notifications: BackgroundNotificationClient
    private let liveActivity: LiveActivityClient
    private let health: WorkoutHealthClient
    private let clock: any Clock<Duration>

    public init(
        notifications: BackgroundNotificationClient,
        liveActivity: LiveActivityClient,
        health: WorkoutHealthClient,
        clock: any Clock<Duration>
    ) {
        self.notifications = notifications
        self.liveActivity = liveActivity
        self.health = health
        self.clock = clock
    }

    /// The process's own clients, as `CircuitTimerApp.init` reads them: the app delegate never sees the store's.
    public init() {
        @Dependency(\.backgroundNotifications) var notifications
        @Dependency(\.liveActivity) var liveActivity
        @Dependency(\.workoutHealth) var health
        @Dependency(\.continuousClock) var clock
        self.init(notifications: notifications, liveActivity: liveActivity, health: health, clock: clock)
    }

    /// Synchronous: from its return no owner syncs a notification or a card, and no workout session starts.
    public func begin() {
        notifications.beginTermination()
        liveActivity.beginTermination()
        health.beginTermination()
    }

    /// The card and the notifications go together, each within its own limit, so the session always gets what is
    /// left of the budget; ending it lets iOS end the process.
    public func run(at date: Date) async {
        async let activities = finishes(within: Self.liveActivityLimit, liveActivity.endAll)
        async let barrier = finishes(within: Self.notificationBarrier, notifications.finishTermination)
        if await !activities {
            Self.logger.notice("Live activities did not end within \(Self.liveActivityLimit, privacy: .public) at termination")
        }
        if await !barrier {
            Self.logger.notice("Notifications were not confirmed removed within \(Self.notificationBarrier, privacy: .public)")
        }
        await health.endAll(date)
    }

    /// `false` when `limit` passed first. The side that loses is cancelled, never awaited: `work` may be queued on an
    /// actor busy with a call that cancellation cannot interrupt.
    private func finishes(within limit: Duration, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        let (outcome, continuation) = AsyncStream<Bool>.makeStream()
        // Unstructured, unlike a task group, which would await both sides before it returns.
        // swiftlint:disable:next no_unstructured_task
        let worker = Task {
            await work()
            continuation.yield(true)
        }
        // The deadline's side, unstructured for the same reason.
        // swiftlint:disable:next no_unstructured_task
        let timer = Task { [clock] in
            do {
                try await clock.sleep(for: limit)
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("A teardown wait failed: \(String(reflecting: error), privacy: .public)")
            }
            continuation.yield(false)
        }
        defer {
            worker.cancel()
            timer.cancel()
            continuation.finish()
        }
        for await finished in outcome {
            return finished
        }
        return false
    }
}
