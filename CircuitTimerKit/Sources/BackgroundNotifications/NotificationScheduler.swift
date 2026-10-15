import Foundation
import os

final class NotificationScheduler: Sendable {
    static let prefix = "ct.cue."
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "BackgroundNotifications")

    enum Status: Sendable { case submitting, confirmed, failed }
    struct Item: Sendable {
        let id: String
        let notification: ScheduledNotification
        var status: Status
    }
    struct Owner: Sendable {
        var revision: Int
        var items: [String: Item] = [:]
        var issued: Set<String> = []
        var carriedFailures = 0
    }
    struct Retirement {
        let removed: [String]
        let expired: Int
    }
    struct Preparation {
        let additions: [Item]
        let removed: [String]
        let expired: Int
        let failures: Int
    }
    struct State: Sendable {
        var owners: [UUID: Owner] = [:]
        // Keep tombstones for this process: a delayed effect can attempt admission even after callbacks finish.
        var ended: Set<UUID> = []
        var serial = 0
        var sweep: OrphanSweep?
        var maySweep: @Sendable () -> Bool = { true }
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    let transport: NotificationTransport

    init(transport: NotificationTransport) { self.transport = transport }

    func sync(
        _ owner: UUID,
        revision: Int,
        plan: [ScheduledNotification],
        now: @escaping @Sendable () -> Date,
        clock: some Clock<Duration>
    ) async throws -> NotificationSyncReport {
        guard register(owner, revision: revision) else { return NotificationSyncReport(superseded: true) }
        guard let retired = retireObsolete(owner, revision: revision, plan: plan, at: now()) else {
            return NotificationSyncReport(superseded: true)
        }
        transport.removePending(retired.removed)
        // Pausing or disabling notifications must not depend on a settings callback arriving.
        if plan.isEmpty {
            guard let prepared = prepare(owner, revision: revision, plan: [], at: now()) else {
                return NotificationSyncReport(superseded: true)
            }
            return NotificationSyncReport(expired: retired.expired + prepared.expired, failed: prepared.failures)
        }
        issueSweepIfAllowed(clock: clock)
        let access: NotificationAccess
        do {
            access = try await transport.access(clock: clock)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.error("Notification settings failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let prepared = prepare(owner, revision: revision, plan: access.canDeliver ? plan : [], at: now())
        guard let prepared else { return NotificationSyncReport(superseded: true, canDeliver: access.canDeliver) }
        transport.removePending(prepared.removed)
        var expired = retired.expired + prepared.expired
        let batch = SubmissionBatch(count: prepared.additions.count)
        for item in prepared.additions {
            let interval = item.notification.fireDate.timeIntervalSince(now())
            guard interval > 0 else {
                expire(owner, item: item)
                expired += 1
                batch.complete()
                continue
            }
            guard isCurrent(owner, id: item.id) else { batch.complete(); continue }
            transport.add(item.id, owner, item.notification, interval) { [self] result in
                complete(owner, item: item, result: result, at: now())
                batch.complete()
            }
            // End can win between admission and the SDK call. Fence again without waiting for its callback.
            removeIfObsolete(owner, item: item, at: now())
        }
        var verified = true
        do {
            _ = try await batch.bridge.wait(timeout: .seconds(2), clock: clock)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.error("Notification submissions did not finish: \(error.localizedDescription, privacy: .public)")
            verified = false
        }
        let pending = CallbackBridge<[String]>()
        transport.pending { pending.resolve(.success($0)) }
        let identifiers: Set<String>?
        do {
            identifiers = Set(try await pending.wait(timeout: .milliseconds(500), clock: clock))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.error("Pending notifications could not be verified: \(error.localizedDescription, privacy: .public)")
            identifiers = nil
            verified = false
        }
        return report(
            owner,
            revision: revision,
            pending: identifiers,
            now: now(),
            initial: NotificationSyncReport(
                canDeliver: access.canDeliver,
                expired: expired,
                failed: prepared.failures,
                isVerified: verified,
                access: access
            )
        )
    }

    private func register(_ owner: UUID, revision: Int) -> Bool {
        state.withLock { state in
            guard !state.ended.contains(owner) else { return false }
            if let current = state.owners[owner], revision < current.revision { return false }
            if state.owners[owner] == nil { state.owners[owner] = Owner(revision: revision) }
            state.owners[owner]?.revision = revision
            return true
        }
    }

    private func retireObsolete(_ owner: UUID, revision: Int, plan: [ScheduledNotification], at now: Date) -> Retirement? {
        state.withLock { state in
            guard var current = state.owners[owner], current.revision == revision, !state.ended.contains(owner) else { return nil }
            let obsolete = current.items.values.filter { item in
                !plan.contains { item.notification.matches($0) } || (item.status == .failed && item.notification.fireDate > now)
            }
            for item in obsolete { current.items.removeValue(forKey: item.notification.key) }
            state.owners[owner] = current
            return Retirement(
                removed: obsolete.filter { $0.notification.fireDate > now }.map(\.id),
                expired: obsolete.filter { $0.notification.fireDate <= now }.count
            )
        }
    }

    private func prepare(_ owner: UUID, revision: Int, plan: [ScheduledNotification], at now: Date) -> Preparation? {
        state.withLock { state in
            guard var current = state.owners[owner], current.revision == revision, !state.ended.contains(owner) else { return nil }
            var retained: [String: Item] = [:]
            var additions: [Item] = []
            var expired = 0
            var seenKeys: Set<String> = []
            for notification in plan where seenKeys.insert(notification.key).inserted {
                guard notification.fireDate > now else {
                    if current.items[notification.key]?.notification.matches(notification) != true { expired += 1 }
                    continue
                }
                if let old = current.items[notification.key], old.status != .failed, old.notification.matches(notification) {
                    retained[notification.key] = old
                } else {
                    state.serial += 1
                    let id = "\(Self.prefix)\(owner.uuidString).\(notification.key).\(state.serial)"
                    let item = Item(id: id, notification: notification, status: .submitting)
                    retained[notification.key] = item
                    additions.append(item)
                    current.issued.insert(id)
                }
            }
            let keptIDs = Set(retained.values.map(\.id))
            let obsolete = current.items.values.filter { !keptIDs.contains($0.id) }
            let removed = obsolete.filter { $0.notification.fireDate > now }.map(\.id)
            expired += obsolete.filter { $0.notification.fireDate <= now }.count
            let failures = current.carriedFailures
            current.carriedFailures = 0
            current.items = retained
            state.owners[owner] = current
            return Preparation(additions: additions, removed: removed, expired: expired, failures: failures)
        }
    }

    private func isCurrent(_ owner: UUID, id: String) -> Bool {
        state.withLock { state in
            !state.ended.contains(owner) && state.owners[owner]?.items.values.contains(where: { $0.id == id }) == true
        }
    }

    private func complete(_ owner: UUID, item: Item, result: Result<Void, NotificationFailure>, at now: Date) {
        let stale = state.withLock { state in
            guard !state.ended.contains(owner), var current = state.owners[owner],
                  current.items[item.notification.key]?.id == item.id else { return true }
            switch result {
                case .success: current.items[item.notification.key]?.status = .confirmed
                case .failure:
                    current.items[item.notification.key]?.status = .failed
                    current.carriedFailures += 1
            }
            state.owners[owner] = current
            return false
        }
        if case let .failure(error) = result {
            Self.logger.error("Notification add failed: \(error.localizedDescription, privacy: .public)")
        }
        if stale { removeIfObsolete(owner, item: item, at: now) }
    }

    private func removeIfObsolete(_ owner: UUID, item: Item, at now: Date) {
        let shouldRemove = state.withLock { state in
            if state.ended.contains(owner) { return true }
            guard state.owners[owner]?.items[item.notification.key]?.id != item.id else { return false }
            // A due request may still be in iOS's delivery pipeline. Explicit end is the only unconditional teardown.
            return item.notification.fireDate > now
        }
        if shouldRemove {
            transport.removePending([item.id])
            transport.removeDelivered([item.id])
        }
    }

    private func expire(_ owner: UUID, item: Item) {
        state.withLock { state in
            guard state.owners[owner]?.items[item.notification.key]?.id == item.id else { return }
            state.owners[owner]?.items.removeValue(forKey: item.notification.key)
        }
    }

    private func report(
        _ owner: UUID,
        revision: Int,
        pending: Set<String>?,
        now: Date,
        initial: NotificationSyncReport
    ) -> NotificationSyncReport {
        let result = state.withLock { state -> (NotificationSyncReport, [String]) in
            guard !state.ended.contains(owner), var current = state.owners[owner], current.revision == revision else {
                return (NotificationSyncReport(superseded: true, canDeliver: initial.canDeliver), [])
            }
            var report = initial
            var remove: [String] = []
            for (key, item) in current.items {
                guard item.notification.fireDate > now else {
                    report.expired += 1
                    current.items.removeValue(forKey: key)
                    continue
                }
                if item.status == .failed { report.failed += 1; continue }
                guard let pending else { continue }
                if pending.contains(item.id) {
                    report.confirmedFuture += 1
                } else if item.notification.fireDate.timeIntervalSince(now) <= 1 {
                    report.imminentUnconfirmed += 1
                } else {
                    report.missing += 1
                    current.items.removeValue(forKey: key)
                    remove.append(item.id)
                }
            }
            report.failed = initial.failed + max(report.failed - initial.failed, current.carriedFailures)
            current.carriedFailures = 0
            state.owners[owner] = current
            return (report, remove)
        }
        transport.removePending(result.1)
        return result.0
    }

    func end(_ owner: UUID) {
        let ids = state.withLock { state in
            state.ended.insert(owner)
            return Array(state.owners.removeValue(forKey: owner)?.issued ?? [])
        }
        transport.removePending(ids)
        transport.removeDelivered(ids)
    }

    func removeDelivered(_ owner: UUID) {
        let ids = state.withLock { Array($0.owners[owner]?.issued ?? []) }
        transport.removeDelivered(ids)
    }
}

private final class SubmissionBatch: Sendable {
    let bridge = CallbackBridge<Bool>()
    private let remaining: OSAllocatedUnfairLock<Int>

    init(count: Int) {
        remaining = OSAllocatedUnfairLock(initialState: count)
        if count == 0 { bridge.resolve(.success(true)) }
    }

    func complete() {
        let finished = remaining.withLock { remaining in
            remaining -= 1
            return remaining == 0
        }
        if finished { bridge.resolve(.success(true)) }
    }
}
