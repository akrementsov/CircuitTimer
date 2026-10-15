import Dependencies
import DependenciesMacros
import Foundation
import os
import UIKit

@DependencyClient
public struct BackgroundNotificationClient: Sendable {
    public var installForegroundSuppression: @Sendable () -> Void
    public var access: @Sendable () async throws -> NotificationAccess
    public var requestAuthorization: @Sendable () async throws -> NotificationAccess
    public var sync: @Sendable (UUID, Int, [ScheduledNotification]) async throws -> NotificationSyncReport
    public var removeOrphans: @Sendable () async throws -> Bool
    public var removeDelivered: @Sendable (UUID) async -> Void
    public var end: @Sendable (UUID) async -> Void
    public var openSystemSettings: @Sendable () async -> Bool = { false }
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
            openSystemSettings: {
                @Dependency(\.continuousClock) var clock
                let bridge = CallbackBridge<Bool>()
                await MainActor.run {
                    guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else {
                        bridge.resolve(.success(false))
                        return
                    }
                    UIApplication.shared.open(url, options: [:]) { bridge.resolve(.success($0)) }
                }
                do {
                    return try await bridge.wait(timeout: .seconds(2), clock: clock)
                } catch is CancellationError {
                    return false
                } catch {
                    Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "BackgroundNotifications")
                        .error("Opening notification settings failed: \(error.localizedDescription, privacy: .public)")
                    return false
                }
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
        openSystemSettings: { true }
    )
    public static let testValue = Self()
}

extension DependencyValues {
    public var backgroundNotifications: BackgroundNotificationClient {
        get { self[BackgroundNotificationClient.self] }
        set { self[BackgroundNotificationClient.self] = newValue }
    }
}
