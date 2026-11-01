@testable import WorkoutHealth

import Dependencies
import Foundation
import os

/// A fixed date in whole seconds.
let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// A date `seconds` after `origin`.
func moment(_ seconds: Double) -> Date {
    origin.addingTimeInterval(seconds)
}

extension UUID {
    /// Deterministic identifiers for fixtures.
    init(fixture number: Int) {
        let high = UInt8(truncatingIfNeeded: number >> 8)
        let low = UInt8(truncatingIfNeeded: number)
        self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, high, low))
    }
}

struct FakeError: Error {}

/// A workout session a test drives: it records what `WorkoutSessions` asks of it and reports what the test sends.
final class FakeSession: Sendable {
    enum Call: Hashable, Sendable {
        case observe
        case start(Date)
        case stop(Date)
        case end
        case release

        var isStart: Bool {
            if case .start = self { true } else { false }
        }
    }

    let activityID: UUID
    let calls = Observed<[Call]>([])
    private let events = EventDelivery()

    init(activityID: UUID) {
        self.activityID = activityID
    }

    var handle: SessionHandle {
        SessionHandle(
            activityID: { self.activityID },
            observe: {
                self.calls.withValue { $0.append(.observe) }
                return self.events.stream()
            },
            start: { date in self.calls.withValue { $0.append(.start(date)) } },
            stop: { date in self.calls.withValue { $0.append(.stop(date)) } },
            end: { self.calls.withValue { $0.append(.end) } },
            release: {
                self.calls.withValue { $0.append(.release) }
                self.events.finish()
            }
        )
    }

    /// Buffered until the session is observed, as HealthKit would deliver it to the delegate.
    func report(_ event: SessionEvent) {
        events.send(event)
    }

    /// Returns once `WorkoutSessions` has handled every event reported so far.
    func waitUntilHandled() async {
        await events.waitUntilHandled()
    }

    /// Returns once `WorkoutSessions` has asked the session for `call`.
    func waitFor(_ call: Call) async {
        await calls.wait { $0.contains(call) }
    }
}

/// The events of one session. Its stream asks for the next event only once the observer has handled the one before,
/// as `WorkoutSessions` does in its watch loop, so each request counts the events handled so far. Once the session is
/// released nothing is left to handle: `WorkoutSessions` releases a session last, and a cancelled watch asks for nothing.
private final class EventDelivery: Sendable {
    private struct HandledWaiter: Sendable {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State: Sendable {
        var buffer: [SessionEvent] = []
        var isFinished = false
        var isCancelled = false
        var consumer: CheckedContinuation<SessionEvent?, Never>?
        var sent = 0
        var requests = 0
        var waiters: [HandledWaiter] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func stream() -> AsyncStream<SessionEvent> {
        // Like any `AsyncStream`, it ends when the task iterating it is cancelled.
        AsyncStream(unfolding: { await self.next() }, onCancel: { self.cancel() })
    }

    func send(_ event: SessionEvent) {
        let consumer = state.withLock { state -> CheckedContinuation<SessionEvent?, Never>? in
            guard !state.isFinished else { return nil }

            state.sent += 1
            if let consumer = state.consumer {
                state.consumer = nil
                return consumer
            }
            state.buffer.append(event)
            return nil
        }
        consumer?.resume(returning: event)
    }

    /// Ends the stream; events sent afterwards are dropped, as HealthKit's are once the delegate is gone.
    func finish() {
        let (consumer, waiters) = state.withLock { state in
            state.isFinished = true
            defer {
                state.consumer = nil
                state.waiters = []
            }
            return (state.consumer, state.waiters)
        }
        consumer?.resume(returning: nil)
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }

    private func cancel() {
        let consumer = state.withLock { state in
            state.isCancelled = true
            defer { state.consumer = nil }
            return state.consumer
        }
        consumer?.resume(returning: nil)
    }

    func waitUntilHandled() async {
        await withCheckedContinuation { continuation in
            let isHandled = state.withLock { state in
                guard !state.isFinished, state.sent > 0, state.requests - 1 < state.sent else { return true }

                state.waiters.append(HandledWaiter(count: state.sent, continuation: continuation))
                return false
            }
            if isHandled {
                continuation.resume()
            }
        }
    }

    private func next() async -> SessionEvent? {
        await withCheckedContinuation { continuation in
            let (ready, event) = state.withLock { state -> ([CheckedContinuation<Void, Never>], SessionEvent??) in
                state.requests += 1
                let handled = state.requests - 1
                let ready = state.waiters.filter { $0.count <= handled }.map(\.continuation)
                state.waiters.removeAll { $0.count <= handled }
                if !state.buffer.isEmpty {
                    return (ready, .some(state.buffer.removeFirst()))
                }
                if state.isFinished || state.isCancelled {
                    return (ready, .some(nil))
                }
                state.consumer = continuation
                return (ready, nil)
            }
            for waiter in ready {
                waiter.resume()
            }
            if let event {
                continuation.resume(returning: event)
            }
        }
    }
}

/// HealthKit as a test sets it up. Recovery waits until the test answers it.
final class FakeHealth: Sendable {
    let canHoldSessions = LockIsolated(true)
    /// Consumed one per `create` before any succeeds.
    let createFailures = LockIsolated<[FakeError]>([])
    /// Every session `create` made, in order; the n-th has activity `UUID(fixture: n)`.
    let created = LockIsolated<[FakeSession]>([])
    let recoveries = Observed(0)
    /// Every workout `save` received, in order.
    let saved = Observed<[HealthWorkout]>([])
    /// Consumed one per `save` before any succeeds.
    let saveFailures = LockIsolated<[any Error]>([])
    /// Saves that returned or threw.
    let finishedSaves = Observed(0)
    /// While set, every save waits until `releaseSaves`.
    private let heldSaves = LockIsolated<[AsyncStream<Void>.Continuation]?>(nil)
    private let recovery = AsyncStream<Result<FakeSession?, any Error>>.makeStream()

    var transport: SessionTransport {
        SessionTransport(
            canHoldSessions: { self.canHoldSessions.value },
            create: {
                if let failure = self.createFailures.withValue({ $0.isEmpty ? nil : $0.removeFirst() }) {
                    throw failure
                }
                return self.created.withValue { created in
                    let session = FakeSession(activityID: UUID(fixture: created.count + 1))
                    created.append(session)
                    return session.handle
                }
            },
            recover: {
                self.recoveries.withValue { $0 += 1 }
                for await answer in self.recovery.stream {
                    return try answer.get()?.handle
                }
                return nil
            },
            save: { workout in
                self.saved.withValue { $0.append(workout) }
                let hold = self.heldSaves.withValue { held -> AsyncStream<Void>? in
                    guard held != nil else { return nil }

                    let (stream, continuation) = AsyncStream<Void>.makeStream()
                    held?.append(continuation)
                    return stream
                }
                if let hold {
                    for await _ in hold {}
                }
                defer { self.finishedSaves.withValue { $0 += 1 } }
                if let failure = self.saveFailures.withValue({ $0.isEmpty ? nil : $0.removeFirst() }) {
                    throw failure
                }
            }
        )
    }

    /// Holds every save from now on until `releaseSaves`.
    func holdSaves() {
        heldSaves.withValue { $0 = $0 ?? [] }
    }

    func releaseSaves() {
        heldSaves.withValue { held in
            for continuation in held ?? [] {
                continuation.finish()
            }
            held = nil
        }
    }

    func answerRecovery(_ answer: Result<FakeSession?, any Error>) {
        recovery.continuation.yield(answer)
    }

    func session(_ index: Int) -> FakeSession {
        created.value[index]
    }
}
