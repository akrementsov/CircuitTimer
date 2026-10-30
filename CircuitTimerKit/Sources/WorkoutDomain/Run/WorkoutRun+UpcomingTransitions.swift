import Foundation

extension WorkoutRun {
    public struct Transition: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case stageStarted(ScheduledStage)
            case finished
        }

        public let kind: Kind
        public let date: Date
        public let epochMs: Int64
    }

    public struct UpcomingTransitions: Hashable, Sendable {
        public let events: [Transition]
        public let hasMore: Bool
    }

    /// When a running run stops by itself: on entering the next manual pause or at its end,
    /// floored to whole milliseconds. `nil` unless running. It reads no clock, so the caller
    /// ticks the run first, and it stays equal while ticks re-anchor the run.
    public var automaticStopDate: Date? {
        guard case let .running(since) = phase else { return nil }

        let pause = schedule.stages.dropFirst(cursor + 1).first { $0.kind == .pause }
        return since.adding((pause?.start ?? schedule.totalDuration) - position).flooredToMilliseconds()
    }

    public func upcomingTransitions(at now: Date, limit: Int) -> UpcomingTransitions {
        var run = self
        run.tick(at: now)
        guard case let .running(since) = run.phase else {
            return UpcomingTransitions(events: [], hasMore: false)
        }

        let limit = max(0, limit)
        var events: [Transition] = []
        for stage in run.schedule.stages.dropFirst(run.cursor + 1) {
            guard events.count < limit else { return UpcomingTransitions(events: events, hasMore: true) }

            let date = since.adding(stage.start - run.position)
            events.append(Transition(kind: .stageStarted(stage), date: date, epochMs: date.millisecondsSince1970))
            // Nothing beyond a manual pause has a date until the user resumes it.
            if stage.kind == .pause { return UpcomingTransitions(events: events, hasMore: false) }
        }
        guard events.count < limit else { return UpcomingTransitions(events: events, hasMore: true) }

        let date = since.adding(run.schedule.totalDuration - run.position)
        events.append(Transition(kind: .finished, date: date, epochMs: date.millisecondsSince1970))
        return UpcomingTransitions(events: events, hasMore: false)
    }
}
