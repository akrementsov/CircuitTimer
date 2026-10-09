import Foundation

// The only place where `Date` and `Duration` are converted into each other.
// Everything inside the domain counts whole milliseconds.

extension Duration {
    /// Truncates to whole milliseconds. Non-positive values become zero and values beyond
    /// `Int64.max` milliseconds saturate, so arbitrary input never traps.
    func flooredToMilliseconds() -> Duration {
        guard self > .zero else { return .zero }

        let (seconds, attoseconds) = components
        guard seconds < Int64.max / 1_000 else { return .milliseconds(Int64.max) }

        return .milliseconds(seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
    }

    /// Whole milliseconds of a value already inside the domain range.
    ///
    /// The value must be normalized by `WorkoutLimits` or otherwise far below `Int64.max`
    /// milliseconds; larger values overflow.
    public var inMilliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }
}

extension Date {
    /// Upper bound that keeps the millisecond conversion far from `Int64` overflow.
    private static let maxElapsedSeconds: TimeInterval = 10_000_000_000

    /// Whole milliseconds elapsed since `start`; zero when `start` is in the future, and capped
    /// at 10¹⁰ seconds so the result never overflows.
    ///
    /// Callers outside the domain use it to measure wall-clock time without converting `Date`
    /// and `Duration` themselves.
    ///
    /// `Date` arithmetic in `Double` lands a hair below an exact millisecond boundary about
    /// half of the time, so a 1 µs tolerance is added before truncating. With it,
    /// `start.adding(d).elapsed(since: start) == d` for whole-millisecond `d` and dates of the
    /// current epoch, where `Double` still resolves well below a microsecond.
    public func elapsed(since start: Date) -> Duration {
        let seconds = timeIntervalSince(start)
        guard seconds.isFinite, seconds > 0 else { return .zero }

        let clamped = min(seconds, Self.maxElapsedSeconds)
        return .milliseconds(Int64((clamped * 1_000 + 0.001).rounded(.down)))
    }

    func adding(_ duration: Duration) -> Date {
        addingTimeInterval(TimeInterval(duration.inMilliseconds) / 1_000)
    }
}
