import CloudKit
import CoreData
import Dependencies
import Foundation
import os

/// Decides once per launch whether the workouts store mirrors to iCloud, and follows what CloudKit reports about it:
/// the account, import and export failures, and finished imports that may have changed the store.
final class CloudSyncMonitor: Sendable {
    private enum EventKind: Hashable, Sendable {
        case setup
        case `import`
        case export
    }

    private struct State {
        var decision: (isRequested: Bool, container: String?)?
        var isMirroring: Bool?
        var accountProblem: CloudSyncProblem?
        var eventProblems: [EventKind: CloudSyncProblem] = [:]
        var nextSubscriber = 0
        var statusSubscribers: [Int: AsyncStream<CloudSyncStatus>.Continuation] = [:]
        var changeSubscribers: [Int: AsyncStream<Void>.Continuation] = [:]
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "CloudSync")

    private let notificationCenter: NotificationCenter
    private let preference: @Sendable () -> Bool
    private let containerID: @Sendable () -> String?
    private let accountStatus: @Sendable (String) async throws -> CKAccountStatus
    private let state = LockIsolated(State())

    init(
        notificationCenter: NotificationCenter,
        preference: @escaping @Sendable () -> Bool,
        containerID: @escaping @Sendable () -> String?,
        accountStatus: @escaping @Sendable (String) async throws -> CKAccountStatus
    ) {
        self.notificationCenter = notificationCenter
        self.preference = preference
        self.containerID = containerID
        self.accountStatus = accountStatus
    }

    /// The container this launch mirrors to, or `nil` to keep the store local. The first call decides; a later
    /// change of the preference waits for the next launch, because an open store cannot change its mirroring.
    func mirroredContainer() -> String? {
        decide().container
    }

    func storeOpened(isMirroring: Bool) {
        let container = decide().container
        state.withValue { $0.isMirroring = isMirroring }
        publishStatus()
        // Creating a container without the iCloud entitlement traps, so only a store that opened mirroring reads it.
        if isMirroring, let container {
            refreshAccount(container)
        }
    }

    /// The current status, then every change of it.
    func status() -> AsyncStream<CloudSyncStatus> {
        decide()
        let (stream, continuation) = AsyncStream.makeStream(of: CloudSyncStatus.self, bufferingPolicy: .bufferingNewest(1))
        let id = state.withValue { state in
            state.nextSubscriber += 1
            state.statusSubscribers[state.nextSubscriber] = continuation
            return state.nextSubscriber
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withValue { _ = $0.statusSubscribers.removeValue(forKey: id) }
        }
        continuation.yield(currentStatus())
        return stream
    }

    /// One element whenever the store may hold what another device wrote, or lost what an account change removed.
    func remoteChanges() -> AsyncStream<Void> {
        decide()
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = state.withValue { state in
            state.nextSubscriber += 1
            state.changeSubscribers[state.nextSubscriber] = continuation
            return state.nextSubscriber
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withValue { _ = $0.changeSubscribers.removeValue(forKey: id) }
        }
        return stream
    }

    @discardableResult
    private func decide() -> (isRequested: Bool, container: String?) {
        let (decision, isNew) = state.withValue { state in
            if let decision = state.decision {
                return (decision, false)
            }
            let isRequested = preference()
            let decision = (isRequested: isRequested, container: isRequested ? containerID() : nil)
            state.decision = decision
            return (decision, true)
        }
        guard isNew else { return decision }

        if decision.isRequested, decision.container == nil {
            Self.logger.fault("iCloud sync is on, but the app names no CloudKit container; the store stays local")
        }
        if decision.container != nil {
            observe()
        }
        return decision
    }

    private func observe() {
        let center = notificationCenter
        // The monitor follows CloudKit for the rest of the process; no caller owns these loops.
        // swiftlint:disable:next no_unstructured_task
        Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await notification in center.notifications(named: NSPersistentCloudKitContainer.eventChangedNotification) {
                        guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                            as? NSPersistentCloudKitContainer.Event else { continue }

                        self?.handle(event)
                    }
                }
                group.addTask {
                    for await _ in center.notifications(named: .CKAccountChanged) {
                        self?.accountChanged()
                    }
                }
            }
        }
    }

    private func handle(_ event: NSPersistentCloudKitContainer.Event) {
        // An event is posted when it starts and again when it ends; only the end tells how it went.
        guard event.endDate != nil else { return }

        let kind: EventKind
        switch event.type {
            case .setup: kind = .setup
            case .import: kind = .import
            case .export: kind = .export
            @unknown default:
                Self.logger.notice("Ignoring a CloudKit event of an unknown type \(event.type.rawValue)")
                return
        }

        if event.succeeded {
            state.withValue { _ = $0.eventProblems.removeValue(forKey: kind) }
            publishStatus()
            if kind != .export {
                publishChange()
            }
            return
        }

        let verdict = CloudSyncClassification.verdict(for: event.error)
        let description = event.error.map { String(reflecting: $0) } ?? "no error"
        switch verdict {
            case .quotaExceeded:
                Self.logger.error("CloudKit \(String(describing: kind), privacy: .public) failed: iCloud storage is full")
                state.withValue { $0.eventProblems[kind] = .quotaExceeded }
            case .recheckAccount:
                Self.logger.notice("CloudKit \(String(describing: kind), privacy: .public) failed on the account: \(description, privacy: .public)")
                if let container = state.value.decision?.container {
                    refreshAccount(container)
                }
            case .transient:
                Self.logger.notice("CloudKit \(String(describing: kind), privacy: .public) is held back: \(description, privacy: .public)")
            case .failed:
                Self.logger.error("CloudKit \(String(describing: kind), privacy: .public) failed: \(description, privacy: .public)")
                state.withValue { $0.eventProblems[kind] = .syncFailed }
        }
        publishStatus()
    }

    private func accountChanged() {
        // Signing out or switching accounts can remove the mirrored workouts, so the list reads again now and once
        // more after the status is known.
        publishChange()
        if let container = state.value.decision?.container {
            refreshAccount(container)
        }
    }

    private func refreshAccount(_ container: String) {
        // Called synchronously from notifications and `storeOpened`; the read outlives them.
        // swiftlint:disable:next no_unstructured_task
        Task { [self, accountStatus] in
            let problem: CloudSyncProblem?
            do {
                switch try await accountStatus(container) {
                    case .available, .couldNotDetermine:
                        problem = nil
                    case .noAccount:
                        problem = .noAccount
                    case .restricted:
                        problem = .restricted
                    case .temporarilyUnavailable:
                        problem = .temporarilyUnavailable
                    @unknown default:
                        Self.logger.notice("Unknown iCloud account status")
                        problem = nil
                }
            } catch {
                // Without a status the account is not blamed; a failing import or export still shows.
                Self.logger.error("Failed to read the iCloud account status: \(String(reflecting: error), privacy: .public)")
                problem = nil
            }
            state.withValue { $0.accountProblem = problem }
            publishStatus()
            publishChange()
        }
    }

    private func currentStatus() -> CloudSyncStatus {
        state.withValue { state in
            let isRequested = state.decision?.isRequested ?? false
            let problem: CloudSyncProblem?
            if isRequested, state.decision?.container == nil || state.isMirroring == false {
                problem = .syncFailed
            } else if state.isMirroring == true {
                let events = Set(state.eventProblems.values)
                problem = state.accountProblem
                    ?? (events.contains(.quotaExceeded) ? .quotaExceeded : events.isEmpty ? nil : .syncFailed)
            } else {
                problem = nil
            }
            return CloudSyncStatus(isRequested: isRequested, isMirroring: state.isMirroring, problem: problem)
        }
    }

    private func publishStatus() {
        let status = currentStatus()
        for subscriber in state.value.statusSubscribers.values {
            subscriber.yield(status)
        }
    }

    private func publishChange() {
        for subscriber in state.value.changeSubscribers.values {
            subscriber.yield()
        }
    }
}
