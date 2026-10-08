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
}
