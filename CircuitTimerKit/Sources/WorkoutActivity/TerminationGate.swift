import os

/// Closes once, synchronously, when iOS terminates the process, so no activity is requested or updated after the
/// teardown has begun.
final class TerminationGate: Sendable {
    private let closed = OSAllocatedUnfairLock(initialState: false)

    var isClosed: Bool {
        closed.withLock { $0 }
    }

    func close() {
        closed.withLock { $0 = true }
    }
}
