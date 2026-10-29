import os

/// Closes once, synchronously, when iOS terminates the process, so a start racing the teardown admits no new session.
final class TerminationGate: Sendable {
    private let closed = OSAllocatedUnfairLock(initialState: false)

    var isClosed: Bool {
        closed.withLock { $0 }
    }

    func close() {
        closed.withLock { $0 = true }
    }
}
