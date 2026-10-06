import Foundation

/// A single run through a `WorkoutSchedule`.
///
/// The run never counts ticks. It stores the schedule position reached at `since` and derives
/// everything else from the wall-clock time passed into each call, so it cannot drift and it
/// catches up correctly after the app spends time in the background.
///
/// Every operation first settles the elapsed time, then applies itself to the resulting phase.
/// A run that reaches a manual pause stops there and waits for the user, however much time
/// has passed.
public struct WorkoutRun: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        case idle
        case running(since: Date)
        case paused
        case awaitingUser
        case finished
    }

    private enum Mode {
        case running(since: Date)
        case paused
    }

    public let schedule: WorkoutSchedule
    public private(set) var phase: Phase
    /// Schedule time reached at the current anchor; always a whole number of milliseconds.
    private(set) var position: Duration
    /// Index of the current stage; equals `schedule.stages.count` once finished.
    private(set) var cursor: Int

    public init(schedule: WorkoutSchedule) {
        self.schedule = schedule
        position = .zero
        cursor = 0
        phase = schedule.stages.isEmpty ? .finished : .idle
    }

    // MARK: - Operations

    /// Commits the progress made by `now`, including reaching a manual pause or the end.
    public mutating func tick(at now: Date) {
        settle(at: now)
    }

    public mutating func start(at now: Date) {
        settle(at: now)
        guard phase == .idle else { return }

        enter(0, mode: .running(since: now))
    }

    public mutating func pause(at now: Date) {
        settle(at: now)
        guard case .running = phase else { return }

        phase = .paused
    }

    public mutating func resume(at now: Date) {
        settle(at: now)
        switch phase {
            case .paused:
                phase = .running(since: now)
            case .awaitingUser:
                enter(cursor + 1, mode: .running(since: now))
            case .idle, .running, .finished:
                break
        }
    }

    public mutating func skipToNextStage(at now: Date) {
        settle(at: now)
        switch phase {
            case .running, .awaitingUser:
                enter(cursor + 1, mode: .running(since: now))
            case .paused:
                enter(cursor + 1, mode: .paused)
            case .idle, .finished:
                break
        }
    }

    /// Moves a running run forward to `kept` and re-anchors it at `now`.
    ///
    /// Use it to restore progress the user has already seen after the system clock moved
    /// backwards. It never moves back, never passes a manual pause and never goes past the end;
    /// outside `.running` it changes nothing.
    public mutating func rebase(at now: Date, keepingTotalElapsed kept: Duration) {
        settle(at: now)
        guard case .running = phase else { return }

        let target = min(max(kept, .zero), schedule.totalDuration).flooredToMilliseconds()
        advance(to: max(position, target), anchor: now)
    }

    public func snapshot(at now: Date) -> Snapshot {
        var run = self
        run.settle(at: now)
        return run.projection()
    }

    // MARK: - Transitions

    private mutating func settle(at now: Date) {
        guard case let .running(since) = phase else { return }
        guard now >= since else {
            // The system clock went back past the anchor: keep the progress, restart from now.
            phase = .running(since: now)
            return
        }

        let elapsed = min(now.elapsed(since: since), schedule.totalDuration - position)
        // Clamping to `now` keeps `since <= now` when the 1 µs tolerance rounds `elapsed` up.
        advance(to: position + elapsed, anchor: min(since.adding(elapsed), now))
    }

    private mutating func advance(to target: Duration, anchor: Date) {
        let stages = schedule.stages
        while cursor < stages.count {
            let stage = stages[cursor]
            if stage.kind == .pause {
                enter(cursor, mode: .paused)
                return
            }
            if target < stage.end {
                position = target
                phase = .running(since: anchor)
                return
            }
            cursor += 1
        }
        enter(stages.count, mode: .paused)
    }

    /// Moves to the start of stage `index`. A manual pause always waits for the user and
    /// running past the last stage finishes the run, whatever `mode` says.
    private mutating func enter(_ index: Int, mode: Mode) {
        let stages = schedule.stages
        guard index < stages.count else {
            cursor = stages.count
            position = schedule.totalDuration
            phase = .finished
            return
        }

        cursor = index
        position = stages[index].start
        if stages[index].kind == .pause {
            phase = .awaitingUser
            return
        }
        switch mode {
            case let .running(since):
                phase = .running(since: since)
            case .paused:
                phase = .paused
        }
    }
}
