/// Bounds every schedule is built within. The editor must apply the same normalization,
/// otherwise the user would see stages that never make it into the schedule.
public enum WorkoutLimits {
    public static let maxTrainingRounds = 99
    public static let maxStagesPerSection = 50
    public static let maxStageDuration: Duration = .seconds(5_999)
    /// Characters a typed workout or stage name may have, as in the original app.
    public static let maxNameLength = 30

    /// A name as typed over `previous`: kept within the limit, or when it does not grow a longer name stored before
    /// the limit; otherwise `previous`, so an edit past the limit, a long paste included, is rejected whole.
    public static func limitedName(_ name: String, previous: String) -> String {
        name.count <= maxNameLength || name.count <= previous.count ? name : previous
    }

    /// Drops the stages that are empty once clamped and quantized, then keeps the first
    /// `maxStagesPerSection` usable ones with their durations clamped and quantized. The order
    /// matters: a sub-millisecond stage must not take a slot from a real one.
    public static func normalizedStages(_ stages: [Stage]) -> [Stage] {
        let usable = stages.lazy
            .filter(isPlayable)
            .map { (stage: Stage) -> Stage in
                var stage = stage
                stage.duration = normalizedDuration(stage.duration)
                return stage
            }

        return Array(usable.prefix(maxStagesPerSection))
    }

    /// Whether a stage makes it into the schedule: its clamped duration holds at least a whole millisecond.
    public static func isPlayable(_ stage: Stage) -> Bool {
        normalizedDuration(stage.duration) > .zero
    }

    private static func normalizedDuration(_ duration: Duration) -> Duration {
        min(max(duration, .zero), maxStageDuration).flooredToMilliseconds()
    }

    public static func normalizedTrainingRounds(_ rounds: Int) -> Int {
        min(max(rounds, 0), maxTrainingRounds)
    }
}
