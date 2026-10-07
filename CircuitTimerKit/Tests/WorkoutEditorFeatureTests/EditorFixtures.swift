@testable import WorkoutEditorFeature

import ComposableArchitecture
import Foundation
import WorkoutDomain

extension UUID {
    /// Deterministic identifiers for fixtures, apart from those `UUIDGenerator.incrementing` produces.
    init(fixture number: Int) {
        let high = UInt8(truncatingIfNeeded: number >> 8)
        let low = UInt8(truncatingIfNeeded: number)
        self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, high, low))
    }
}

func makeStage(_ number: Int, seconds: Int = 10, _ intensity: Stage.Intensity = .work) -> Stage {
    Stage(id: UUID(fixture: number), name: "Stage \(number)", duration: .seconds(seconds), intensity: intensity)
}

/// A complete workout: a name and stages in every section.
func makeWorkout() -> Workout {
    Workout(
        id: UUID(fixture: 1),
        name: "Workout",
        warmUp: [makeStage(10)],
        training: [makeStage(20), makeStage(21, .rest)],
        trainingRounds: 3,
        coolDown: [makeStage(30, .rest)]
    )
}

struct SaveFailure: Error {}
