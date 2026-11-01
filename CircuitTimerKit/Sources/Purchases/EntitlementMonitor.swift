import Dependencies
import Foundation

/// Knows whether the process owns the full version, from StoreKit only: nothing is stored on the device. It listens to
/// transaction updates for the rest of the process from its first use, and orders its answers by the read that
/// started them, so a late read never overwrites a newer purchase or refund.
final class EntitlementMonitor: Sendable {
    private struct State {
        var status: FullVersionStatus = .unknown
        /// The newest read started; only its answer is published.
        var latestRead = 0
        var isStarted = false
        var nextSubscriber = 0
        var subscribers: [Int: AsyncStream<FullVersionStatus>.Continuation] = [:]

        /// Sends a change while the lock is held, so subscribers see changes in the order they happened.
        mutating func publish(_ status: FullVersionStatus) {
            guard self.status != status else { return }

            self.status = status
            for subscriber in subscribers.values {
                subscriber.yield(status)
            }
        }
    }

    private let transport: StoreTransport
    private let sleep: @Sendable (Duration) async throws -> Void
    private let state = LockIsolated(State())

    init(transport: StoreTransport, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.transport = transport
        self.sleep = sleep
    }

    var currentStatus: FullVersionStatus {
        startIfNeeded()
        return state.status
    }

    /// The current status at once, then every change of it.
    func changes() -> AsyncStream<FullVersionStatus> {
        startIfNeeded()
        let (stream, continuation) = AsyncStream.makeStream(of: FullVersionStatus.self, bufferingPolicy: .bufferingNewest(1))
        let id = state.withValue { state in
            state.nextSubscriber += 1
            state.subscribers[state.nextSubscriber] = continuation
            continuation.yield(state.status)
            return state.nextSubscriber
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withValue { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    /// The first known status, or the current one after `timeout`. A cancelled caller gets the current one at once;
    /// the read itself goes on and publishes later.
    func refreshStatus(timeout: Duration) async -> FullVersionStatus {
        let known = await withTaskGroup(of: FullVersionStatus?.self) { group in
            group.addTask { [self] in
                for await status in changes() where status != .unknown {
                    return status
                }
                return nil
            }
            group.addTask { [sleep] in
                do {
                    try await sleep(timeout)
                    return nil
                } catch {
                    // Cancelled: the other child answered, or the caller went away and gets the current status.
                    return nil
                }
            }
            let first = await group.next().flatMap { $0 }
            group.cancelAll()
            return first
        }
        return known ?? currentStatus
    }

    func offer() async throws -> FullVersionOffer {
        startIfNeeded()
        return try await transport.offer()
    }

    func purchase() async throws -> PurchaseOutcome {
        startIfNeeded()
        let outcome = try await transport.purchase()
        if outcome == .purchased {
            state.withValue { state in
                // Reads already under way started before the purchase; their answers are older.
                state.latestRead += 1
                state.publish(.full)
            }
        }
        return outcome
    }

    func restore() async throws -> RestoreOutcome {
        startIfNeeded()
        guard try await transport.sync() else { return .cancelled }

        // A read that a newer one overtook may be outdated either way; read until an answer is the newest.
        var read = await reconcile()
        while !read.isNewest {
            read = await reconcile()
        }
        return read.isEntitled ? .restored : .nothingFound
    }

    /// Reads the entitlement and publishes it while this read is still the newest one started; returns its own answer
    /// and whether it was the newest.
    @discardableResult
    private func reconcile() async -> (isEntitled: Bool, isNewest: Bool) {
        let read = state.withValue { state in
            state.latestRead += 1
            return state.latestRead
        }
        let isEntitled = await transport.isEntitled()
        let isNewest = state.withValue { state in
            guard state.latestRead == read else { return false }

            state.publish(isEntitled ? .full : .free)
            return true
        }
        return (isEntitled, isNewest)
    }

    private func startIfNeeded() {
        let isFirstUse = state.withValue { state in
            defer { state.isStarted = true }
            return !state.isStarted
        }
        guard isFirstUse else { return }

        // Outlives every caller: StoreKit delivers updates, such as an approved Ask to Buy or a refund, only to a
        // running listener.
        // swiftlint:disable:next no_unstructured_task
        Task { [weak self, transport] in
            await transport.listen { [weak self] in
                await self?.reconcile()
            }
        }
        // Outlives every caller: the first answer serves the whole process.
        // swiftlint:disable:next no_unstructured_task
        Task { [weak self] in
            await self?.reconcile()
        }
    }
}
