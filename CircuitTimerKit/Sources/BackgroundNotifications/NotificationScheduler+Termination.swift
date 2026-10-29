import Foundation
import os

extension NotificationScheduler {
    /// Ends every owner and refuses any later one, then removes what they issued, all before it returns: iOS gives a
    /// terminating process no time it can count on.
    func beginTermination() {
        let ids = state.withLock { state in
            state.isTerminating = true
            state.ended.formUnion(state.owners.keys)
            let ids = state.owners.values.flatMap(\.issued)
            state.owners = [:]
            return ids
        }
        transport.removePending(ids)
        transport.removeDelivered(ids)
    }

    /// Removes every request of the module that iOS still lists after `beginTermination`, such as one whose add was
    /// already in flight. Removal happens in the callbacks, so it goes on after a cancelled caller stops waiting.
    func finishTermination(clock: some Clock<Duration>) async {
        let pending = CallbackBridge<Bool>()
        let delivered = CallbackBridge<Bool>()
        transport.pending { [transport] identifiers in
            transport.removePending(identifiers.filter { $0.hasPrefix(Self.prefix) })
            pending.resolve(.success(true))
        }
        transport.delivered { [transport] identifiers in
            transport.removeDelivered(identifiers.filter { $0.hasPrefix(Self.prefix) })
            delivered.resolve(.success(true))
        }
        do {
            _ = try await pending.wait(clock: clock)
            _ = try await delivered.wait(clock: clock)
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error("Removing notifications at termination failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
