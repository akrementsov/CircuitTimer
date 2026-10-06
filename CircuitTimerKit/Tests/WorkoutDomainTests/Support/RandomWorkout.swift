@testable import WorkoutDomain

import Foundation

extension Workout {
    /// A workout mixing valid stages with ones normalization must drop or clamp.
    static func random(using generator: inout SeededGenerator, rounds: ClosedRange<Int>) -> Workout {
        var nextID = 0
        func section() -> [Stage] {
            (0..<Int.random(in: 0...3, using: &generator)).map { _ in
                nextID += 1
                let intensity: Stage.Intensity = Bool.random(using: &generator) ? .work : .rest
                return makeStage(nextID, randomDuration(using: &generator), intensity)
            }
        }

        return Workout(
            id: UUID(fixture: 0),
            warmUp: section(),
            training: section(),
            trainingRounds: Int.random(in: rounds, using: &generator),
            coolDown: section(),
            pauseAfterWarmUp: Bool.random(using: &generator),
            pauseAfterTraining: Bool.random(using: &generator)
        )
    }

    private static func randomDuration(using generator: inout SeededGenerator) -> Duration {
        switch Int.random(in: 0..<10, using: &generator) {
            case 0:
                .milliseconds(-Int64.random(in: 0...5_000, using: &generator))
            case 1:
                .microseconds(Int64.random(in: 0...999, using: &generator))
            case 2:
                .seconds(Int64.random(in: 5_999...7_000, using: &generator))
            default:
                .microseconds(Int64.random(in: 1_000...20_000_000, using: &generator))
        }
    }
}
