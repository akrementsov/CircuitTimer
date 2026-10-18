import UITestContract
import XCTest

@MainActor
final class WorkoutReorderUITests: XCTestCase {
    func test_workouts_dragDownThenUp_preservesOrderAndSpacing() {
        let app = launch(.threeWorkouts)
        let first = ScenarioFixture.workoutName
        let second = ScenarioFixture.secondWorkoutName
        let third = ScenarioFixture.thirdWorkoutName

        WorkoutListScreen(app)
            .moveWorkout(first, onto: second)
            .assertOrder([second, first, third])
            .moveWorkout(first, onto: third)
            .assertOrder([second, third, first])
            .moveWorkout(first, onto: second)
            .assertOrder([first, second, third])
    }
}
