import Foundation

/// A reading of an injected monotonic clock that can live in a feature's `State`.
///
/// One clock instance per state that holds readings: the feature's `continuousClock` dependency stays the same for
/// its lifetime. A reading checks only the type of its instant, so it cannot tell two clocks of one type apart.
public struct MonotonicInstant: Equatable, Sendable {
    private let base: any InstantProtocol<Duration>

    // Members generic over the clock did not compile where a reducer passes its `continuousClock` dependency
    // (`any Clock<Duration>`), so these take the existential and open it in local generic functions.

    public init(now clock: any Clock<Duration>) {
        func read<C: Clock<Duration>>(_ clock: C) -> any InstantProtocol<Duration> {
            clock.now
        }
        base = read(clock)
    }

    public func instant<C: Clock<Duration>>(for clock: C) throws -> C.Instant {
        guard let instant = base as? C.Instant else { throw ClockMismatch() }

        return instant
    }

    private struct ClockMismatch: Error {}

    /// Time from this reading to `clock.now`; nil when the reading was taken on a clock of another type.
    public func duration(toNowOf clock: any Clock<Duration>) -> Duration? {
        func measure<C: Clock<Duration>>(_ clock: C) -> Duration? {
            guard let instant = base as? C.Instant else { return nil }

            return instant.duration(to: clock.now)
        }
        return measure(clock)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        func isEqual<I: InstantProtocol<Duration>>(_ instant: I) -> Bool {
            (rhs.base as? I) == instant
        }
        return isEqual(lhs.base)
    }
}
