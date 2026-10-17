#if DEBUG
/// The app states a UI test can launch into. The app builds each one in `AppScenarios`; Release knows none.
public enum AppScenario: String, CaseIterable, Sendable {
    case emptyList
    case oneWorkout
}

/// The launch environment that selects a scenario.
public enum ScenarioLaunch {
    public static let scenarioKey = "CT_APP_SCENARIO"
    /// swift-dependencies reads its default context from this variable; a scenario runs only in `preview`.
    public static let dependencyContextKey = "SWIFT_DEPENDENCIES_CONTEXT"
    public static let dependencyContext = "preview"
}

/// User data the scenarios put on screen, which the tests find by its text.
public enum ScenarioFixture {
    public static let workoutName = "Leg day"
}
#endif
