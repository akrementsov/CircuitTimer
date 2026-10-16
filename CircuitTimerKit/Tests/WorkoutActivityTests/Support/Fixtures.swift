@testable import WorkoutActivity

import Foundation
import WorkoutDomain

/// A fixed date of the current epoch in whole milliseconds, so outlook dates compare exactly.
let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// A date `seconds` after `origin`.
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

/// Squats 10 s, an unnamed rest 5 s, a manual pause, Lunges 10 s.
///
/// Stage indices: 0 work, 1 rest, 2 manual pause, 3 work.
func makePausedWorkout(name: String = "Morning") -> Workout {
    Workout(
        id: UUID(fixture: 900),
        name: name,
        warmUp: [
            Stage(id: UUID(fixture: 1), name: "Squats", duration: .seconds(10), intensity: .work),
            Stage(id: UUID(fixture: 2), name: "", duration: .seconds(5), intensity: .rest),
        ],
        training: [Stage(id: UUID(fixture: 3), name: "Lunges", duration: .seconds(10), intensity: .work)],
        pauseAfterWarmUp: true
    )
}

/// Squats 10 s, a rest named with spaces only 5 s, Lunges 10 s — no manual pause.
func makeOpenWorkout() -> Workout {
    Workout(
        id: UUID(fixture: 901),
        warmUp: [
            Stage(id: UUID(fixture: 1), name: "Squats", duration: .seconds(10), intensity: .work),
            Stage(id: UUID(fixture: 2), name: "  ", duration: .seconds(5), intensity: .rest),
            Stage(id: UUID(fixture: 3), name: "Lunges", duration: .seconds(10), intensity: .work),
        ]
    )
}

func makeRun(_ workout: Workout) -> WorkoutRun {
    WorkoutRun(schedule: WorkoutSchedule(workout: workout))
}

typealias Attributes = WorkoutActivityAttributes
typealias Content = WorkoutActivityAttributes.ContentState

extension WorkoutActivityAttributes.Stage {
    static func work(_ name: String? = "Squats") -> Self {
        Self(kind: .work, name: name)
    }

    static func rest(_ name: String? = "") -> Self {
        Self(kind: .rest, name: name)
    }
}

extension WorkoutActivityAttributes.ContentState {
    /// A user pause holding `milliseconds` of a work stage; distinct values make distinct contents.
    static func held(_ milliseconds: Int64) -> Self {
        Self(phase: .paused(WorkoutActivityAttributes.HeldStage(stage: .work(), remainingMilliseconds: milliseconds)))
    }

    static let finished = Self(phase: .finished)
}
