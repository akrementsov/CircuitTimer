import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
public struct BackgroundNotificationClient: Sendable {
    public var installForegroundSuppression: @Sendable () -> Void
    public var access: @Sendable () async throws -> NotificationAccess
    public var requestAuthorization: @Sendable () async throws -> NotificationAccess
    public var sync: @Sendable (UUID, Int, [ScheduledNotification]) async throws -> NotificationSyncReport
    public var removeOrphans: @Sendable () async throws -> Bool
    public var removeDelivered: @Sendable (UUID) async -> Void
    public var end: @Sendable (UUID) async -> Void
    /// Synchronous, so the app delegate ends every owner and refuses later syncs before it returns from termination.
    public var beginTermination: @Sendable () -> Void
    /// Removes what `beginTermination` could not: requests whose adds were in flight. Has no timeout of its own;
    /// cancelling stops the wait at once.
    public var finishTermination: @Sendable () async -> Void
}

extension BackgroundNotificationClient: DependencyKey {
    public static let liveValue: Self = {
        let runtime = NotificationRuntime()
        return Self(
            installForegroundSuppression: { runtime.install() },
            access: {
                @Dependency(\.continuousClock) var clock
                return try await runtime.scheduler.transport.access(clock: clock)
            },
            requestAuthorization: {
                @Dependency(\.continuousClock) var clock
                let bridge = CallbackBridge<Bool>()
                runtime.scheduler.transport.authorize { result in bridge.resolve(result.map { true }) }
                _ = try await bridge.wait(clock: clock)
                return try await runtime.scheduler.transport.access(clock: clock)
            },
            sync: { owner, revision, plan in
                @Dependency(\.date) var date
                @Dependency(\.continuousClock) var clock
                let dates = date
                return try await runtime.scheduler.sync(owner, revision: revision, plan: plan, now: { dates.now }, clock: clock)
            },
            removeOrphans: {
                @Dependency(\.continuousClock) var clock
                return try await runtime.scheduler.removeOrphans(clock: clock)
            },
            removeDelivered: { runtime.scheduler.removeDelivered($0) },
            end: { runtime.scheduler.end($0) },
            beginTermination: { runtime.scheduler.beginTermination() },
            finishTermination: {
                @Dependency(\.continuousClock) var clock
                await runtime.scheduler.finishTermination(clock: clock)
            }
        )
    }()

    public static let previewValue = Self(
        installForegroundSuppression: {},
        access: { .authorized },
        requestAuthorization: { .authorized },
        sync: { _, _, _ in NotificationSyncReport() },
        removeOrphans: { true },
        removeDelivered: { _ in },
        end: { _ in },
        beginTermination: {},
        finishTermination: {}
    )
    public static let testValue = Self()
}

extension DependencyValues {
    public var backgroundNotifications: BackgroundNotificationClient {
        get { self[BackgroundNotificationClient.self] }
        set { self[BackgroundNotificationClient.self] = newValue }
    }
}
