extension Workout {
    /// The stages of one section, as the user edited them.
    public subscript(section: WorkoutSectionKind) -> [Stage] {
        switch section {
            case .warmUp: warmUp
            case .training: training
            case .coolDown: coolDown
        }
    }
}
