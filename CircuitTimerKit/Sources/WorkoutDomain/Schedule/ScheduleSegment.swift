/// A non-empty slice of the schedule covering one round of one section; drives sectioned progress.
public struct ScheduleSegment: Hashable, Sendable {
    public let section: WorkoutSectionKind
    public let round: Int
    public let range: Range<Duration>

    /// Fraction of this segment covered at `totalElapsed`, clamped to `0...1`.
    public func progress(at totalElapsed: Duration) -> Double {
        if totalElapsed <= range.lowerBound {
            return 0
        }
        if totalElapsed >= range.upperBound {
            return 1
        }
        return (totalElapsed - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
}
