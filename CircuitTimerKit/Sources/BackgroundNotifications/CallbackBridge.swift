import Foundation
import os

/// Finishing the stream releases a cancelled caller even when an SDK callback never returns.
final class CallbackBridge<Value: Sendable>: Sendable {
    private let pair = AsyncStream<Result<Value, NotificationFailure>>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let resolved = OSAllocatedUnfairLock(initialState: false)

    func resolve(_ result: Result<Value, NotificationFailure>) {
        resolved.withLock { resolved in
            guard !resolved else { return }
            resolved = true
            pair.continuation.yield(result)
            pair.continuation.finish()
        }
    }

    func wait(timeout: Duration? = nil, clock: some Clock<Duration>) async throws -> Value {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { [pair] in
                for await result in pair.stream {
                    try Task.checkCancellation()
                    return try result.get()
                }
                throw CancellationError()
            }
            if let timeout {
                group.addTask {
                    try await clock.sleep(for: timeout)
                    throw NotificationFailure.timedOut
                }
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }
}
