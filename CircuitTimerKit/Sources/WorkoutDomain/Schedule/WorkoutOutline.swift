/// A schedule summarized section by section for a read-only screen: what plays, how often and how long,
/// without repeating the training for every round.
public struct WorkoutOutline: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public let kind: WorkoutSectionKind
        /// The time the section adds to the schedule, all its rounds included.
        public let duration: Duration
        public let roundCount: Int
        /// The stages of one round, in play order.
        public let stages: [ScheduledStage]
        /// A manual pause waits for the user after the section.
        public let isFollowedByPause: Bool
    }

    /// The sections that play anything, in play order.
    public let sections: [Section]
    public let totalDuration: Duration

    public init(schedule: WorkoutSchedule) {
        sections = WorkoutSectionKind.allCases.compactMap { kind in
            let stages = schedule.stages.filter { $0.section == kind && $0.round == 1 && $0.kind != .pause }
            guard let first = stages.first else { return nil }

            let segments = schedule.segments.filter { $0.section == kind }
            return Section(
                kind: kind,
                duration: segments.reduce(.zero) { $0 + ($1.range.upperBound - $1.range.lowerBound) },
                roundCount: first.roundCount,
                stages: stages,
                isFollowedByPause: schedule.stages.contains { $0.section == kind && $0.kind == .pause }
            )
        }
        totalDuration = schedule.totalDuration
    }
}
