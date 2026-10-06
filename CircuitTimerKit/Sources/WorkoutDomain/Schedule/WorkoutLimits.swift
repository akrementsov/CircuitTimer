/// Bounds every schedule is built within. The editor must apply the same normalization,
/// otherwise the user would see stages that never make it into the schedule.
public enum WorkoutLimits {
    public static let maxTrainingRounds = 99
    public static let maxStagesPerSection = 50
    public static let maxStageDuration: Duration = .seconds(5_999)

    /// Clamps and quantizes durations first, then drops empty stages, then keeps the first
    /// `maxStagesPerSection` usable ones. The order matters: a sub-millisecond stage must
    /// not take a slot from a real one.
    public static func normalizedStages(_ stages: [Stage]) -> [Stage] {
        let usable = stages.lazy
            .map { (stage: Stage) -> Stage in
                var stage = stage
                stage.duration = min(max(stage.duration, .zero), maxStageDuration).flooredToMilliseconds()
                return stage
            }
            .filter { $0.duration > .zero }

        return Array(usable.prefix(maxStagesPerSection))
    }

    public static func normalizedTrainingRounds(_ rounds: Int) -> Int {
        min(max(rounds, 0), maxTrainingRounds)
    }
}
