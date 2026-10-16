import Foundation
import os

/// Lets a caller wait a bounded time for work that keeps running after the wait gives up.
final class CompletionSignal: Sendable {
    private let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let completed = OSAllocatedUnfairLock(initialState: false)

    func complete() {
        completed.withLock { completed in
            guard !completed else { return }
            completed = true
            pair.continuation.yield()
            pair.continuation.finish()
        }
    }

    /// `false` when `timeout` passed first; a cancelled caller stops waiting at once.
    func wait(timeout: Duration, clock: any Clock<Duration>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [pair] in
                for await _ in pair.stream {
                    return true
                }
                // The stream ends without a value only when the waiting task is cancelled.
                return false
            }
            group.addTask {
                do {
                    try await clock.sleep(for: timeout)
                } catch {
                    // Only cancellation interrupts the sleep; the caller stops waiting either way.
                    return false
                }
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }
}
