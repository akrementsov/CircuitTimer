import Foundation
import os

extension NotificationScheduler {
    func removeOrphans(clock: some Clock<Duration>) async throws -> Bool {
        let sweep = issueSweepIfAllowed(clock: clock)
        do {
            return try await sweep.wait(clock: clock)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.notice("Orphan notification cleanup is still unconfirmed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    func issueSweepIfAllowed<C: Clock<Duration>>(clock: C) -> OrphanSweep {
        let (sweep, start) = state.withLock { state in
            if let sweep = state.sweep, !state.maySweep() { return (sweep, false) }
            let sweep = OrphanSweep()
            let next = clock.now.advanced(by: .seconds(30))
            state.maySweep = { clock.now >= next }
            state.sweep = sweep
            return (sweep, true)
        }
        if start {
            transport.pending { [self] identifiers in
                let orphans = orphanIDs(in: identifiers)
                transport.removePending(orphans)
                sweep.completePending()
            }
            transport.delivered { [self] identifiers in
                let orphans = orphanIDs(in: identifiers)
                transport.removeDelivered(orphans)
                sweep.completeDelivered()
            }
        }
        return sweep
    }

    private func orphanIDs(in identifiers: [String]) -> [String] {
        state.withLock { state in
            identifiers.filter { identifier in
                guard identifier.hasPrefix(Self.prefix) else { return false }
                let suffix = identifier.dropFirst(Self.prefix.count)
                guard suffix.count >= 36, let owner = UUID(uuidString: String(suffix.prefix(36))) else { return true }
                return state.ended.contains(owner) || state.owners[owner] == nil
            }
        }
    }
}

/// Each caller has its own stream, so cancelling one cleanup waiter cannot cancel another.
final class OrphanSweep: Sendable {
    private struct State {
        var pending = false
        var delivered = false
        var waiters: [CallbackBridge<Bool>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait(clock: some Clock<Duration>) async throws -> Bool {
        let bridge = CallbackBridge<Bool>()
        let complete = state.withLock { state in
            guard !state.pending || !state.delivered else { return true }
            state.waiters.append(bridge)
            return false
        }
        if complete { bridge.resolve(.success(true)) }
        defer { state.withLock { $0.waiters.removeAll { $0 === bridge } } }
        return try await bridge.wait(timeout: .milliseconds(500), clock: clock)
    }

    func completePending() { complete(pending: true) }
    func completeDelivered() { complete(pending: false) }

    private func complete(pending: Bool) {
        let waiters = state.withLock { state in
            if pending { state.pending = true } else { state.delivered = true }
            guard state.pending && state.delivered else { return [CallbackBridge<Bool>]() }
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.resolve(.success(true)) }
    }
}
