import Foundation

/// A reading of the injected monotonic clock that can live in `State`.
///
/// One clock instance per timer session: the feature's `continuousClock` dependency stays the same for its
/// lifetime. A reading checks only the type of its instant, so it cannot tell two clocks of one type apart.
struct MonotonicInstant: Equatable, Sendable {
    private let base: any InstantProtocol<Duration>

    // The clocks arrive as `any Clock<Duration>`; an initializer or a method generic over the clock does not open
    // that existential, so local generic functions do.

    init(now clock: any Clock<Duration>) {
        func read<C: Clock<Duration>>(_ clock: C) -> any InstantProtocol<Duration> {
            clock.now
        }
        base = read(clock)
    }

    /// Time from this reading to `clock.now`; nil when the reading was taken on a clock of another type.
    func duration(toNowOf clock: any Clock<Duration>) -> Duration? {
        func measure<C: Clock<Duration>>(_ clock: C) -> Duration? {
            guard let instant = base as? C.Instant else { return nil }

            return instant.duration(to: clock.now)
        }
        return measure(clock)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        func isEqual<I: InstantProtocol<Duration>>(_ instant: I) -> Bool {
            (rhs.base as? I) == instant
        }
        return isEqual(lhs.base)
    }
}

/// Wall and monotonic readings taken together, which the reducer measures clock jumps against.
struct ClockAnchor: Equatable, Sendable {
    let date: Date
    let instant: MonotonicInstant
    /// The run's committed total elapsed at `date`.
    let totalElapsed: Duration
}
