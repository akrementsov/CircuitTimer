import Foundation

/// What a timer's run did, in wall-clock dates, for its Health workout: when it started, the pauses it closed and where
/// it stands now. The timer follows its run after every action; the session projects the newest track it received onto
/// the date it closes, so a stop no tick has seen still ends the workout where the run stopped.
public struct WorkoutHealthTrack: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Running until `stopsAt` unless something stops it first.
        case running(stopsAt: Date)
        /// Not counting: a pause by the user or the schedule, a resume countdown, the stage list, the close dialog.
        case halted
        case finished
    }

    private enum Position: Equatable, Sendable {
        case idle
        case running(stopsAt: Date)
        case halted(since: Date)
        case finished(end: Date)
    }

    private(set) var start: Date?
    private var pauses: [DateInterval] = []
    private var position = Position.idle
    /// The newest date written into the track; `stopsAt` is a forecast and never moves it. A date before it means the
    /// clock went back unseen.
    private var latest: Date?

    public init() {}

    public mutating func follow(_ phase: Phase, at now: Date) {
        switch (position, phase) {
            case let (.idle, .running(stopsAt)):
                start = now
                latest = now
                position = .running(stopsAt: stopsAt)
            case let (.running(stopsAt), .running(next)):
                guard next != stopsAt else { return }

                shiftBack(toward: now)
                if case let .running(stopsAt) = position, stopsAt < now {
                    // The run stopped by itself and was resumed before a tick saw the stop.
                    close(DateInterval(start: stopsAt, end: now))
                }
                position = .running(stopsAt: next)
            case (.running, .halted):
                shiftBack(toward: now)
                if case let .running(stopsAt) = position {
                    position = .halted(since: written(min(stopsAt, now)))
                }
            case (.running, .finished):
                shiftBack(toward: now)
                if case let .running(stopsAt) = position {
                    position = .finished(end: written(min(stopsAt, now)))
                }
            case let (.halted, .running(next)):
                shiftBack(toward: now)
                if case let .halted(since) = position {
                    close(DateInterval(start: since, end: now))
                }
                position = .running(stopsAt: next)
            case let (.halted(since), .finished):
                position = .finished(end: since)
            case (.idle, _), (.halted, .halted), (.finished, _):
                return
        }
    }

    /// Moves every date by the jump the timer measured when the wall clock went back, as its run's `rebase` does.
    public mutating func rebase(from oldNow: Date, to now: Date) {
        shift(by: now.timeIntervalSince(oldNow))
    }

    /// The workout this track describes when its session closes at `date`, or `nil` when the run never counted.
    func workout(closingAt date: Date) -> HealthWorkout? {
        var track = self
        track.shiftBack(toward: date)
        guard let start = track.start else { return nil }

        let end: Date
        switch track.position {
            case .idle: return nil
            case let .running(stopsAt): end = min(stopsAt, date)
            // A pause the workout ends in is not part of it.
            case let .halted(since): end = min(since, date)
            case let .finished(finish): end = min(finish, date)
        }
        guard end > start else { return nil }

        let pauses = track.pauses.compactMap { pause -> DateInterval? in
            let pauseStart = max(pause.start, start)
            let pauseEnd = min(pause.end, end)
            return pauseStart < pauseEnd ? DateInterval(start: pauseStart, end: pauseEnd) : nil
        }
        return HealthWorkout(start: start, end: end, pauses: pauses)
    }

    private mutating func close(_ pause: DateInterval) {
        if pause.duration > 0 { pauses.append(pause) }
        latest = pause.end
    }

    private mutating func written(_ date: Date) -> Date {
        latest = max(latest ?? date, date)
        return date
    }

    /// A date before `latest` means the clock went back without the timer measuring it, as in a pause without a clock
    /// anchor: the whole track moves back with it, so the time it counted is kept.
    private mutating func shiftBack(toward date: Date) {
        guard let latest, date < latest else { return }

        shift(by: date.timeIntervalSince(latest))
    }

    private mutating func shift(by interval: TimeInterval) {
        guard interval != 0 else { return }

        start = start?.addingTimeInterval(interval)
        pauses = pauses.map { DateInterval(start: $0.start.addingTimeInterval(interval), duration: $0.duration) }
        latest = latest?.addingTimeInterval(interval)
        position = switch position {
            case .idle: .idle
            case let .running(stopsAt): .running(stopsAt: stopsAt.addingTimeInterval(interval))
            case let .halted(since): .halted(since: since.addingTimeInterval(interval))
            case let .finished(end): .finished(end: end.addingTimeInterval(interval))
        }
    }
}

/// A finished track: what a builder saves.
struct HealthWorkout: Hashable, Sendable {
    let start: Date
    let end: Date
    /// Inside `start...end`, in order, none empty.
    let pauses: [DateInterval]
}
