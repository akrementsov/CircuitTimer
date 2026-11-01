import Dependencies
import os

/// A clock that moves only when a test advances it. A sleep is registered before it suspends, so `waitForSleeps` sees
/// it and the `advance` that follows always wakes it. Unlike `TestClock`, nothing here yields to background-priority
/// tasks, which a loaded runner starves for seconds at a time.
final class ManualClock: Clock, Sendable {
    typealias Duration = Swift.Duration
    typealias Instant = TestClock<Swift.Duration>.Instant

    private struct Sleeper: Sendable {
        let number: Int
        let deadline: Instant
        let wake: AsyncStream<Never>.Continuation
    }

    private struct SleepWaiter: Sendable {
        let pending: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State: Sendable {
        var now = Instant()
        var sleepers: [Sleeper] = []
        var sleepCount = 0
        var waiters: [SleepWaiter] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var now: Instant {
        state.withLock { $0.now }
    }

    var minimumResolution: Duration {
        .zero
    }

    func sleep(until deadline: Instant, tolerance _: Duration?) async throws {
        try Task.checkCancellation()
        let (stream, wake) = AsyncStream<Never>.makeStream()
        let (number, ready) = state.withLock { state -> (Int?, [CheckedContinuation<Void, Never>]) in
            guard deadline > state.now else { return (nil, []) }

            state.sleepCount += 1
            state.sleepers.append(Sleeper(number: state.sleepCount, deadline: deadline, wake: wake))
            let pending = state.sleepers.count
            let ready = state.waiters.filter { $0.pending <= pending }.map(\.continuation)
            state.waiters.removeAll { $0.pending <= pending }
            return (state.sleepCount, ready)
        }
        for continuation in ready {
            continuation.resume()
        }
        guard let number else { return }

        // Ends when `advance` reaches the deadline, or at once when the task is cancelled.
        for await _ in stream {}
        state.withLock { $0.sleepers.removeAll { $0.number == number } }
        try Task.checkCancellation()
    }

    /// Moves the clock and wakes every sleep it reaches.
    func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due {
            sleeper.wake.finish()
        }
    }

    /// Returns once `pending` sleeps wait on the clock at the same time.
    func waitForSleeps(_ pending: Int = 1) async {
        await withCheckedContinuation { continuation in
            let isReady = state.withLock { state in
                guard state.sleepers.count < pending else { return true }

                state.waiters.append(SleepWaiter(pending: pending, continuation: continuation))
                return false
            }
            if isReady {
                continuation.resume()
            }
        }
    }
}
