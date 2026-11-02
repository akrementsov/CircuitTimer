import Foundation
import WorkoutDomain

/// Wall and monotonic readings taken together, which the reducer measures clock jumps against.
struct ClockAnchor: Equatable, Sendable {
    let date: Date
    let instant: MonotonicInstant
    /// The run's committed total elapsed at `date`.
    let totalElapsed: Duration
}
