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
        Self.keepsPauseAfterWarmUp(
            warmUp: WorkoutLimits.normalizedStages(warmUp),
            trainingRounds: trainingRoundsToPlay,
            coolDown: WorkoutLimits.normalizedStages(coolDown)
        )
    }

    /// Whether a manual pause after the training makes it into the schedule.
    public var canPauseAfterTraining: Bool {
        Self.keepsPauseAfterTraining(
            trainingRounds: trainingRoundsToPlay,
            coolDown: WorkoutLimits.normalizedStages(coolDown)
        )
    }

    private var trainingRoundsToPlay: Int {
        Self.trainingRoundsToPlay(training: WorkoutLimits.normalizedStages(training), rounds: trainingRounds)
    }

    // The schedule calls these with the sections it has already normalized.

    /// Training rounds that actually play: none when the normalized training section is empty.
    static func trainingRoundsToPlay(training: [Stage], rounds: Int) -> Int {
        training.isEmpty ? 0 : WorkoutLimits.normalizedTrainingRounds(rounds)
    }

    static func keepsPauseAfterWarmUp(warmUp: [Stage], trainingRounds: Int, coolDown: [Stage]) -> Bool {
        !warmUp.isEmpty && (trainingRounds > 0 || !coolDown.isEmpty)
    }

    static func keepsPauseAfterTraining(trainingRounds: Int, coolDown: [Stage]) -> Bool {
        trainingRounds > 0 && !coolDown.isEmpty
    }
}
