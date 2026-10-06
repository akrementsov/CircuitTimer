extension Workout {
    /// The stages of one section, as the user edited them.
    public subscript(section: WorkoutSectionKind) -> [Stage] {
        get {
            switch section {
                case .warmUp: warmUp
                case .training: training
                case .coolDown: coolDown
            }
        }
        set {
            switch section {
                case .warmUp: warmUp = newValue
                case .training: training = newValue
                case .coolDown: coolDown = newValue
            }
        }
    }

    /// Whether a manual pause after the warm-up makes it into the schedule:
    /// a pause is kept only between two non-empty parts.
    public var canPauseAfterWarmUp: Bool {
        !WorkoutLimits.normalizedStages(warmUp).isEmpty && (hasTrainingRounds || !WorkoutLimits.normalizedStages(coolDown).isEmpty)
    }

    /// Whether a manual pause after the training makes it into the schedule.
    public var canPauseAfterTraining: Bool {
        hasTrainingRounds && !WorkoutLimits.normalizedStages(coolDown).isEmpty
    }

    private var hasTrainingRounds: Bool {
        !WorkoutLimits.normalizedStages(training).isEmpty && WorkoutLimits.normalizedTrainingRounds(trainingRounds) > 0
    }
}
