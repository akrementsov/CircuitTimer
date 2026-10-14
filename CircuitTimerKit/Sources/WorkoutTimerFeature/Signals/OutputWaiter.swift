import ComposableArchitecture

enum OutputEnd: Equatable, Sendable {
    case completed
    case stopped
    case failed
    case cancelled
}

/// A single output has one waiter; completion and cancellation race with first-wins semantics.
final class OutputWaiter: Sendable {
    private struct State {
        var continuation: CheckedContinuation<OutputEnd, Never>?
        var result: OutputEnd?
    }

    private let state = LockIsolated(State())

    func wait() async -> OutputEnd {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let result = state.withValue { state -> OutputEnd? in
                    if let result = state.result { return result }
                    state.continuation = continuation
                    return nil
                }
                if let result { continuation.resume(returning: result) }
            }
        } onCancel: {
            self.finish(.cancelled)
        }
    }

    func finish(_ result: OutputEnd) {
        let continuation = state.withValue { state -> CheckedContinuation<OutputEnd, Never>? in
            guard state.result == nil else { return nil }

            state.result = result
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: result)
    }
}
