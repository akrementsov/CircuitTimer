extension Workout {
    /// The time one section adds to the schedule: its normalized stages, the training repeated for its rounds.
    public func duration(of section: WorkoutSectionKind) -> Duration {
        let stages = WorkoutLimits.normalizedStages(self[section]).totalDuration
        return section == .training ? stages * WorkoutLimits.normalizedTrainingRounds(trainingRounds) : stages
    }

    /// Matches `WorkoutSchedule(workout:).totalDuration` without materializing the schedule.
    public var totalDuration: Duration {
        WorkoutSectionKind.allCases.reduce(.zero) { $0 + duration(of: $1) }
    }
}

extension [Stage] {
    var totalDuration: Duration {
        reduce(.zero) { $0 + $1.duration }
    }
}
