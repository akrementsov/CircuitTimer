@testable import WorkoutDomain

import Foundation

/// A fixed date of the current epoch, so `Date` arithmetic has production precision.
let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// A date `seconds` after `origin`; accepts fractions to probe sub-millisecond boundaries.
func moment(_ seconds: Double) -> Date {
    origin.addingTimeInterval(seconds)
}

extension UUID {
    /// Deterministic identifiers for fixtures.
    init(fixture number: Int) {
        let high = UInt8(truncatingIfNeeded: number >> 8)
        let low = UInt8(truncatingIfNeeded: number)
        self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, high, low))
    }
}

func makeStage(_ number: Int, _ duration: Duration, _ intensity: Stage.Intensity = .work) -> Stage {
    Stage(id: UUID(fixture: number), name: "Stage \(number)", duration: duration, intensity: intensity)
}

/// Work 10 s, rest 5 s, a manual pause, work 10 s — 25 s in total.
///
/// Stage indices: 0 work, 1 rest, 2 manual pause, 3 work.
func makePausedWorkout() -> Workout {
    Workout(
        id: UUID(fixture: 900),
        warmUp: [makeStage(1, .seconds(10)), makeStage(2, .seconds(5), .rest)],
        training: [makeStage(3, .seconds(10))],
        pauseAfterWarmUp: true
    )
}

func makeRun(_ workout: Workout) -> WorkoutRun {
    WorkoutRun(schedule: WorkoutSchedule(workout: workout))
}

/// The observable state of a run, for compact expectations.
struct RunState: Equatable, Sendable, CustomStringConvertible {
    let phase: WorkoutRun.Phase
    let cursor: Int
    let position: Duration

    init(_ phase: WorkoutRun.Phase, cursor: Int, position: Duration) {
        self.phase = phase
        self.cursor = cursor
        self.position = position
    }

    init(_ run: WorkoutRun) {
        self.init(run.phase, cursor: run.cursor, position: run.position)
    }

    var description: String {
        "\(phase) cursor \(cursor) position \(position)"
    }
}

extension Duration {
    var isWholeMilliseconds: Bool {
        components.attoseconds % 1_000_000_000_000_000 == 0
    }
}
