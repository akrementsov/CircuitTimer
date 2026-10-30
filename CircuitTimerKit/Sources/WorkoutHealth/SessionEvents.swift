import Foundation
import HealthKit

/// What a session's delegate reports, in the order HealthKit calls it: a failure always comes before its state change.
enum SessionEvent: Sendable {
    /// `date` is when the session changed, as HealthKit reports it.
    case changed(HKWorkoutSessionState, date: Date)
    case failed(any Error)
}

/// Hands a session's delegate callbacks, which arrive on an anonymous serial queue, to the actor that owns the session.
/// The session holds its delegate weakly; its `SessionHandle` keeps this object.
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
        continuation.yield(.changed(toState, date: date))
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        continuation.yield(.failed(error))
    }
}
