@testable import AppFeature

import Foundation
import Testing
import WorkoutDomain

@Suite
struct WorkoutDisplayNameTests {
    // `make test` runs in English, so the catalog's English variant applies.
    @Test(arguments: [
        ("", "Untitled workout"),
        (" ", "Untitled workout"),
        ("\t\n", "Untitled workout"),
        ("Legs", "Legs"),
        ("  Legs  ", "  Legs  "),
        ("Leg day", "Leg day"),
    ])
    func test_displayName_name_fallsBackOnlyWhenBlank(name: String, expected: String) {
        let workout = Workout(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)), name: name)

        #expect(workout.displayName == expected)
    }

    @Test(arguments: [
        (Workout(id: Self.id), false),
        (Workout(id: Self.id, training: [Self.stage(.zero)]), false),
        // Normalization floors durations to whole milliseconds, so this stage never reaches the schedule.
        (Workout(id: Self.id, training: [Self.stage(.microseconds(999))]), false),
        (Workout(id: Self.id, training: [Self.stage(.seconds(10))], trainingRounds: 0), false),
        (Workout(id: Self.id, training: [Self.stage(.milliseconds(1))]), true),
        (Workout(id: Self.id, warmUp: [Self.stage(.seconds(10))]), true),
        (Workout(id: Self.id, coolDown: [Self.stage(.seconds(10))]), true),
    ])
    func test_isPlayable_totalDuration_isTrueOnlyAboveZero(workout: Workout, expected: Bool) {
        #expect(workout.isPlayable == expected)
    }

    private static let id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

    private static func stage(_ duration: Duration) -> Stage {
        Stage(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)), name: "Stage", duration: duration, intensity: .work)
    }
}
