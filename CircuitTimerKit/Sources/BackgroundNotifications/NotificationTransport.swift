import Foundation
import os
import UIKit
import UserNotifications

/// Only Sendable values cross the callback boundary; SDK objects stay inside their callbacks.
struct NotificationTransport: Sendable {
    var settings: @Sendable (@escaping @Sendable (NotificationAccess) -> Void) -> Void
    var authorize: @Sendable (@escaping @Sendable (Result<Void, NotificationFailure>) -> Void) -> Void
    var add: @Sendable (
        String, UUID, ScheduledNotification, TimeInterval,
        @escaping @Sendable (Result<Void, NotificationFailure>) -> Void
    ) -> Void
    var pending: @Sendable (@escaping @Sendable ([String]) -> Void) -> Void
    var delivered: @Sendable (@escaping @Sendable ([String]) -> Void) -> Void
    var removePending: @Sendable ([String]) -> Void
    var removeDelivered: @Sendable ([String]) -> Void

    func access(clock: some Clock<Duration>) async throws -> NotificationAccess {
        let bridge = CallbackBridge<NotificationAccess>()
        settings { bridge.resolve(.success($0)) }
        return try await bridge.wait(timeout: .milliseconds(500), clock: clock)
    }

    static let live = Self(
        settings: { completion in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let authorization: NotificationAccess.Authorization
                switch settings.authorizationStatus {
                    case .notDetermined: authorization = .notDetermined
                    case .denied: authorization = .denied
                    case .authorized: authorization = .authorized
                    case .provisional: authorization = .provisional
                    case .ephemeral: authorization = .ephemeral
                    @unknown default: authorization = .denied
                }
                completion(NotificationAccess(
                    authorization: authorization,
                    showsAlerts: settings.alertSetting == .enabled,
                    playsSound: settings.soundSetting == .enabled
                ))
            }
        },
        authorize: { completion in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error { completion(.failure(.system(error.localizedDescription))) } else { completion(.success(())) }
            }
        },
        add: { identifier, owner, notification, interval, completion in
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.threadIdentifier = owner.uuidString
            content.interruptionLevel = .active
            content.sound = notification.isAudible ? .default : nil
            // The scheduler checks expiry immediately before this call. Never move an expired event into the future.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request) { error in
                if let error { completion(.failure(.system(error.localizedDescription))) } else { completion(.success(())) }
            }
        },
        pending: { completion in
            UNUserNotificationCenter.current().getPendingNotificationRequests { completion($0.map(\.identifier)) }
        },
        delivered: { completion in
            UNUserNotificationCenter.current().getDeliveredNotifications { completion($0.map { $0.request.identifier }) }
        },
        removePending: { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: $0) },
        removeDelivered: { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0) }
    )
}

final class NotificationRuntime: Sendable {
    let scheduler = NotificationScheduler(transport: .live)
    private let delegate = ForegroundNotificationDelegate()
    private let installed = OSAllocatedUnfairLock(initialState: false)

    func install() {
        let shouldInstall = installed.withLock { installed in
            guard !installed else { return false }
            installed = true
            return true
        }
        if shouldInstall { UNUserNotificationCenter.current().delegate = delegate }
    }
}

private final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(notification.request.identifier.hasPrefix(NotificationScheduler.prefix) ? [] : [.banner, .list, .sound])
    }
}
