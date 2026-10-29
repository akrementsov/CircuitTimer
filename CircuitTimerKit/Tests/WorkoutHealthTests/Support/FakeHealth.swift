@testable import WorkoutHealth

import Dependencies
import Foundation

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
    let calls = LockIsolated<[Call]>([])
    private let events = AsyncStream<SessionEvent>.makeStream()

    init(activityID: UUID) {
        self.activityID = activityID
    }

    var handle: SessionHandle {
        SessionHandle(
            activityID: { self.activityID },
            observe: {
                self.calls.withValue { $0.append(.observe) }
                return self.events.stream
            },
            start: { date in self.calls.withValue { $0.append(.start(date)) } },
            stop: { date in self.calls.withValue { $0.append(.stop(date)) } },
            end: { self.calls.withValue { $0.append(.end) } },
            release: {
                self.calls.withValue { $0.append(.release) }
                self.events.continuation.finish()
            }
        )
    }

    /// Buffered until the session is observed, as HealthKit would deliver it to the delegate.
    func report(_ event: SessionEvent) {
        events.continuation.yield(event)
    }
}

/// HealthKit as a test sets it up. Recovery waits until the test answers it.
final class FakeHealth: Sendable {
    let canHoldSessions = LockIsolated(true)
    /// Consumed one per `create` before any succeeds.
    let createFailures = LockIsolated<[FakeError]>([])
    /// Every session `create` made, in order; the n-th has activity `UUID(fixture: n)`.
    let created = LockIsolated<[FakeSession]>([])
    let recoveries = LockIsolated(0)
    /// Every workout `save` received, in order.
    let saved = LockIsolated<[HealthWorkout]>([])
    /// Consumed one per `save` before any succeeds.
    let saveFailures = LockIsolated<[FakeError]>([])
    /// While set, a save waits until the test finishes it.
    let saveGate = LockIsolated<AsyncStream<Void>?>(nil)
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
                if let gate = self.saveGate.value {
                    for await _ in gate {}
                }
                if let failure = self.saveFailures.withValue({ $0.isEmpty ? nil : $0.removeFirst() }) {
                    throw failure
                }
            }
        )
    }

    func answerRecovery(_ answer: Result<FakeSession?, any Error>) {
        recovery.continuation.yield(answer)
    }

    func session(_ index: Int) -> FakeSession {
        created.value[index]
    }
}
