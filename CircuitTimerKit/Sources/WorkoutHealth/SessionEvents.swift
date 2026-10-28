import Foundation
import HealthKit

/// What a session's delegate reports, in the order HealthKit calls it: a failure always comes before its state change.
enum SessionEvent: Sendable {
    case changed(HKWorkoutSessionState)
    case failed(any Error)
}

/// Hands a session's delegate callbacks, which arrive on an anonymous serial queue, to the actor that owns the session.
/// The session holds its delegate weakly, so the owner keeps this object as long as it reads `stream`.
final class SessionEvents: NSObject, HKWorkoutSessionDelegate, Sendable {
    let stream: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation

    override init() {
        (stream, continuation) = AsyncStream.makeStream()
        super.init()
    }

    func finish() {
        continuation.finish()
    }

    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        continuation.yield(.changed(toState))
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        continuation.yield(.failed(error))
    }
}
