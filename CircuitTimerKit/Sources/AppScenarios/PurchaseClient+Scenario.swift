import Dependencies
import Foundation
import Purchases

#if DEBUG
extension PurchaseClient {
    /// The full version held in memory: it starts as `status`, a purchase or a restore unlocks it, and nothing reaches
    /// StoreKit.
    static func scenario(status: FullVersionStatus) -> Self {
        let store = ScenarioPurchases(status: status)
        return Self(
            currentStatus: { store.status },
            refreshStatus: { _ in store.status },
            changes: { store.changes() },
            offer: { FullVersionOffer(displayPrice: "$0.99") },
            purchase: {
                store.unlock()
                return .purchased
            },
            restore: {
                store.unlock()
                return .restored
            }
        )
    }
}

private final class ScenarioPurchases: Sendable {
    private struct State {
        var status: FullVersionStatus
        var nextSubscriber = 0
        var subscribers: [Int: AsyncStream<FullVersionStatus>.Continuation] = [:]
    }

    private let state: LockIsolated<State>

    init(status: FullVersionStatus) {
        state = LockIsolated(State(status: status))
    }

    var status: FullVersionStatus {
        state.status
    }

    func changes() -> AsyncStream<FullVersionStatus> {
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

    func unlock() {
        state.withValue { state in
            state.status = .full
            for subscriber in state.subscribers.values {
                subscriber.yield(.full)
            }
        }
    }
}
#endif
