import CloudKit
import CoreData
import Dependencies
import Foundation
import os

/// Decides once per launch whether the workouts store mirrors to iCloud, and follows what CloudKit reports about it:
/// the account, import and export failures, and finished imports that may have changed the store.
final class CloudSyncMonitor: Sendable {
    enum EventKind: Hashable, Sendable {
        case setup
        case `import`
        case export
    }

    private struct State {
        var decision: (isRequested: Bool, container: String?)?
        var isMirroring: Bool?
        var accountProblem: CloudSyncProblem?
        /// Tells the latest account read from an older one that answers late.
        var accountGeneration = 0
        /// An account change asked the list to read again once the status is known; the latest read does it, whichever
        /// started it, since an older read's answer is dropped.
        var announcesAccountRead = false
        var eventProblems: [EventKind: CloudSyncProblem] = [:]
        var nextSubscriber = 0
        var statusSubscribers: [Int: AsyncStream<CloudSyncStatus>.Continuation] = [:]
        var changeSubscribers: [Int: AsyncStream<Void>.Continuation] = [:]

        var status: CloudSyncStatus {
            let isRequested = decision?.isRequested ?? false
            return CloudSyncStatus(isRequested: isRequested, isMirroring: isMirroring, problem: problem(isRequested: isRequested))
        }

        /// A failed open while sync is on, then the account, then full storage, then any other failed event.
        private func problem(isRequested: Bool) -> CloudSyncProblem? {
            if isRequested, decision?.container == nil || isMirroring == false {
                return .syncFailed
            }
            guard isMirroring == true else { return nil }

            if let accountProblem {
                return accountProblem
            }
            let events = Set(eventProblems.values)
            if events.contains(.quotaExceeded) {
                return .quotaExceeded
            }
            return events.isEmpty ? nil : .syncFailed
        }

        /// Sends the status while the lock is held, so subscribers see changes in the order they happened.
        func publishStatus() {
            let status = status
            for subscriber in statusSubscribers.values {
                subscriber.yield(status)
            }
        }
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
        decide()
        state.withValue { state in
            state.isMirroring = isMirroring
            state.publishStatus()
        }
        refreshAccountIfMirroring(announcesChange: false)
    }

    /// The current status, then every change of it.
    func status() -> AsyncStream<CloudSyncStatus> {
        decide()
        let (stream, continuation) = AsyncStream.makeStream(of: CloudSyncStatus.self, bufferingPolicy: .bufferingNewest(1))
        let id = state.withValue { state in
            state.nextSubscriber += 1
            state.statusSubscribers[state.nextSubscriber] = continuation
            continuation.yield(state.status)
            return state.nextSubscriber
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withValue { _ = $0.statusSubscribers.removeValue(forKey: id) }
        }
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
            // Under the lock, so no caller sees the decision and opens the store before the observers are in place.
            if decision.container != nil {
                observe()
            }
            return (decision, true)
        }
        if isNew, decision.isRequested, decision.container == nil {
            Self.logger.fault("iCloud sync is on, but the app names no CloudKit container; the store stays local")
        }
        return decision
    }

    /// Registers before the store opens, so its first setup and import are seen. The tokens are dropped: the center
    /// keeps the observers as long as it lives, which for the live dependency is the whole process, and a handler of a
    /// monitor that is gone does nothing.
    private func observe() {
        _ = notificationCenter.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }

            self?.handle(event)
        }
        _ = notificationCenter.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
            self?.accountChanged()
        }
    }

    private func handle(_ event: NSPersistentCloudKitContainer.Event) {
        let kind: EventKind
        switch event.type {
            case .setup: kind = .setup
            case .import: kind = .import
            case .export: kind = .export
            @unknown default:
                if event.endDate != nil {
                    Self.logger.notice("Ignoring a CloudKit event of an unknown type \(event.type.rawValue)")
                }
                return
        }
        handle(kind: kind, isFinished: event.endDate != nil, succeeded: event.succeeded, error: event.error)
    }

    /// The parts of an event the monitor reads, taken apart so tests can report events:
    /// `NSPersistentCloudKitContainer.Event` has no public initializer.
    func handle(kind: EventKind, isFinished: Bool, succeeded: Bool, error: (any Error)?) {
        // An event is posted when it starts and again when it ends; only the end tells how it went.
        guard isFinished else { return }

        if succeeded {
            state.withValue { state in
                state.eventProblems.removeValue(forKey: kind)
                state.publishStatus()
            }
            if kind != .export {
                publishChange()
            }
            return
        }

        let verdict = CloudSyncClassification.verdict(for: error)
        let description = error.map { String(reflecting: $0) } ?? "no error"
        switch verdict {
            case .quotaExceeded:
                Self.logger.error("CloudKit \(String(describing: kind), privacy: .public) failed: iCloud storage is full")
                recordEventProblem(.quotaExceeded, for: kind)
            case .recheckAccount:
                Self.logger.notice("CloudKit \(String(describing: kind), privacy: .public) failed on the account: \(description, privacy: .public)")
                refreshAccountIfMirroring(announcesChange: false)
            case .transient:
                Self.logger.notice("CloudKit \(String(describing: kind), privacy: .public) is held back: \(description, privacy: .public)")
            case .cancelled:
                return
            case .failed:
                Self.logger.error("CloudKit \(String(describing: kind), privacy: .public) failed: \(description, privacy: .public)")
                recordEventProblem(.syncFailed, for: kind)
        }
    }

    private func recordEventProblem(_ problem: CloudSyncProblem, for kind: EventKind) {
        state.withValue { state in
            state.eventProblems[kind] = problem
            state.publishStatus()
        }
    }

    private func accountChanged() {
        // Failures belonged to the previous account. Signing out or switching accounts can remove the mirrored
        // workouts, so the list reads again now and once more after the status is known.
        state.withValue { state in
            state.eventProblems = [:]
            state.publishStatus()
        }
        publishChange()
        refreshAccountIfMirroring(announcesChange: true)
    }

    /// Reads the account only for a store that opened mirroring: creating a container without the iCloud
    /// entitlement traps, and a local store has no account to report.
    private func refreshAccountIfMirroring(announcesChange: Bool) {
        let read: (container: String, generation: Int)? = state.withValue { state in
            guard state.isMirroring == true, let container = state.decision?.container else { return nil }

            state.accountGeneration += 1
            state.announcesAccountRead = state.announcesAccountRead || announcesChange
            return (container, state.accountGeneration)
        }
        guard let read else { return }

        // Called synchronously from notifications and `storeOpened`; the read outlives them.
        // swiftlint:disable:next no_unstructured_task
        Task { [self, accountStatus] in
            let problem: CloudSyncProblem?
            do {
                switch try await accountStatus(read.container) {
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
            let announces = state.withValue { state in
                guard state.accountGeneration == read.generation else { return false }

                state.accountProblem = problem
                state.publishStatus()
                defer { state.announcesAccountRead = false }
                return state.announcesAccountRead
            }
            if announces {
                publishChange()
            }
        }
    }

    private func publishChange() {
        state.withValue { state in
            for subscriber in state.changeSubscribers.values {
                subscriber.yield()
            }
        }
    }
}
