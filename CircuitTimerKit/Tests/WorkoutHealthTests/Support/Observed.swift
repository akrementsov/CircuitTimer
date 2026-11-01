import os

/// A value a test reads and waits on: `wait(until:)` returns once a change makes the condition hold.
final class Observed<Value: Sendable>: Sendable {
    private struct Waiter: Sendable {
        let isReady: @Sendable (Value) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State: Sendable {
        var value: Value
        var waiters: [Waiter] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ value: Value) {
        state = OSAllocatedUnfairLock(initialState: State(value: value))
    }

    var value: Value {
        state.withLock { $0.value }
    }

    func setValue(_ newValue: Value) {
        withValue { $0 = newValue }
    }

    @discardableResult
    func withValue<Result: Sendable>(_ change: @Sendable (inout Value) -> Result) -> Result {
        let (result, ready) = state.withLock { state in
            let result = change(&state.value)
            let value = state.value
            let ready = state.waiters.filter { $0.isReady(value) }
            state.waiters.removeAll { $0.isReady(value) }
            return (result, ready.map(\.continuation))
        }
        for continuation in ready {
            continuation.resume()
        }
        return result
    }

    func wait(until isReady: @escaping @Sendable (Value) -> Bool) async {
        await withCheckedContinuation { continuation in
            let isReadyNow = state.withLock { state in
                guard !isReady(state.value) else { return true }

                state.waiters.append(Waiter(isReady: isReady, continuation: continuation))
                return false
            }
            if isReadyNow {
                continuation.resume()
            }
        }
    }
}
