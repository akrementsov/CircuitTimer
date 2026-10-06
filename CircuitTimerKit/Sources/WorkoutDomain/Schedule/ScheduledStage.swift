/// One entry of the linear schedule: a timed stage or a manual pause that waits for the user.
public struct ScheduledStage: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case work
        case rest
        case pause
    }

    public let index: Int
    /// The source stage; `nil` for a manual pause.
    public let stageID: Stage.ID?
    /// The source stage name; `nil` for a manual pause, which the UI names by its kind.
    public let name: String?
    public let kind: Kind
    /// For a manual pause, the section it follows.
    public let section: WorkoutSectionKind
    /// One-based round within `section`.
    public let round: Int
    public let roundCount: Int
    public let start: Duration
    public let duration: Duration

    public var end: Duration {
        start + duration
    }
}
