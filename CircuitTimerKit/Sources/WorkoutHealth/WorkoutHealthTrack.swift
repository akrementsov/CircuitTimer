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

                let stop = stopsAt.addingTimeInterval(shiftBack(toward: now))
                if stop < now {
                    // The run stopped by itself and was resumed before a tick saw the stop.
                    close(DateInterval(start: stop, end: now))
                }
                position = .running(stopsAt: next)
            case let (.running(stopsAt), .halted):
                let stop = stopsAt.addingTimeInterval(shiftBack(toward: now))
                position = .halted(since: written(min(stop, now)))
            case let (.running(stopsAt), .finished):
                let stop = stopsAt.addingTimeInterval(shiftBack(toward: now))
                position = .finished(end: written(min(stop, now)))
            case let (.halted(since), .running(next)):
                let pauseStart = since.addingTimeInterval(shiftBack(toward: now))
                close(DateInterval(start: pauseStart, end: now))
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

    /// The workout this track describes when its session closes at `date`, or `nil` when the run never counted. A
    /// session lost earlier than the track's newest date ends it at `limit` without moving the track.
    func workout(closingAt date: Date, endingBy limit: Date = .distantFuture) -> HealthWorkout? {
        var track = self
        track.shiftBack(toward: date)
        guard let start = track.start else { return nil }

        var end: Date
        switch track.position {
            case .idle: return nil
            case let .running(stopsAt): end = min(stopsAt, date)
            // A pause the workout ends in is not part of it.
            case let .halted(since): end = min(since, date)
            case let .finished(finish): end = min(finish, date)
        }
        end = min(end, limit)
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
    /// anchor: the whole track moves back with it, so the time it counted is kept. Returns how far it moved.
    @discardableResult
    private mutating func shiftBack(toward date: Date) -> TimeInterval {
        guard let latest, date < latest else { return 0 }

        let interval = date.timeIntervalSince(latest)
        shift(by: interval)
        return interval
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
