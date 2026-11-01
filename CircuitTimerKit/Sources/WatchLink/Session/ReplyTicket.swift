import Foundation
import os

/// The one answer the other side waits for. A second answer does nothing.
final class ReplyTicket: Sendable {
    private let handler: OSAllocatedUnfairLock<((Data) -> Void)?>

    init(_ handler: @escaping (Data) -> Void) {
        self.handler = OSAllocatedUnfairLock(uncheckedState: handler)
    }

    func reply(_ data: Data) {
        // The handler runs outside the lock: WatchConnectivity may call back synchronously.
        let handler = handler.withLockUnchecked { handler in
            defer { handler = nil }
            return handler
        }
        handler?(data)
    }
}
