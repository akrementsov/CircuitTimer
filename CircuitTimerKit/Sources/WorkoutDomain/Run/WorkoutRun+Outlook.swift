import Foundation

extension WorkoutRun {
    /// The dates a presentation needs to keep counting on its own while the app is suspended:
    /// the running stage and the stage after it.
    ///
    /// Every date is a whole number of milliseconds since 1970, so the outlook stays equal while
    /// each tick re-anchors the run; a boundary may still move by a millisecond on a rare tick.
    public struct Outlook: Hashable, Sendable {
        public let stageStart: Date
        public let stageEnd: Date
        /// When the next stage ends; `nil` when the next stage is a manual pause or there is none.
        public let nextStageEnd: Date?
    }

    /// Settles a copy at `now` first; `nil` unless that copy is running.
    public func outlook(at now: Date) -> Outlook? {
        var run = self
        run.tick(at: now)
        guard case let .running(since) = run.phase, run.schedule.stages.indices.contains(run.cursor) else { return nil }

        let position = run.position
        func date(at offset: Duration) -> Date {
            since.adding(offset - position).flooredToMilliseconds()
        }

        let stage = run.schedule.stages[run.cursor]
        let next = run.schedule.next(after: stage)
        return Outlook(
            stageStart: date(at: stage.start),
            stageEnd: date(at: stage.end),
            nextStageEnd: next.flatMap { $0.kind == .pause ? nil : date(at: $0.end) }
        )
    }
}
