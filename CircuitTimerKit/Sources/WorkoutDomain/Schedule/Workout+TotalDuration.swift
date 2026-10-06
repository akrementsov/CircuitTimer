extension Workout {
    /// Matches `WorkoutSchedule(workout:).totalDuration` without materializing the schedule.
    public var totalDuration: Duration {
        let training = WorkoutLimits.normalizedStages(training).totalDuration
        let rounds = WorkoutLimits.normalizedTrainingRounds(trainingRounds)

        return WorkoutLimits.normalizedStages(warmUp).totalDuration
            + training * rounds
            + WorkoutLimits.normalizedStages(coolDown).totalDuration
    }
}

extension [Stage] {
    var totalDuration: Duration {
        reduce(.zero) { $0 + $1.duration }
    }
}
