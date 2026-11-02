import Foundation
import os

/// One answer, given at most once, that a caller waits for a bounded time; the work that gives it may outlive the
/// wait.
final class OneAnswer<Value: Sendable>: Sendable {
    private let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let given = OSAllocatedUnfairLock<[Value]>(initialState: [])

    /// `false` when an answer was already given, by the work or by the wait that gave up.
    @discardableResult
    func give(_ value: Value) -> Bool {
        let isFirst = given.withLock { given in
            guard given.isEmpty else { return false }
            given = [value]
            return true
        }
        if isFirst {
            pair.continuation.yield()
            pair.continuation.finish()
        }
        return isFirst
    }

    /// The answer given within `timeout`; otherwise `fallback`, which closes the answer so a later one is refused.
    /// A cancelled caller stops waiting at once.
    func wait(timeout: Duration, clock: any Clock<Duration>, otherwise fallback: Value) async -> Value {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [pair] in
                for await _ in pair.stream {
                    return
                }
            }
            group.addTask {
                do {
                    try await clock.sleep(for: timeout)
                } catch is CancellationError {
                    return
                } catch {
                    Logger.watchLink.error("A bounded wait failed: \(String(reflecting: error), privacy: .public)")
                }
            }
            await group.next()
            group.cancelAll()
        }
        give(fallback)
        return given.withLock { $0.first } ?? fallback
    }
}
