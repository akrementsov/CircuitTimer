import UITestContract
import XCTest

@MainActor
final class WorkoutEditorUITests: XCTestCase {
    func test_savedWorkout_editThenSave_keepsChangesWhenReopened() {
        let app = launch(.oneWorkout)

        WorkoutListScreen(app)
            .openWorkout(ScenarioFixture.workoutName)
            .tapEdit()
            .typeName(" updated")
            .tapSave()
            .assertTitle("Leg day updated")
            .tapBack()
            .assertHasWorkout("Leg day updated", duration: "2 minutes")
            .openWorkout("Leg day updated")
            .assertTitle("Leg day updated")
            .tapEdit()
            .assertName("Leg day updated")
    }

    func test_savedWorkout_dragStage_changesOrder() {
        let app = launch(.oneWorkout)

        WorkoutListScreen(app)
            .openWorkout(ScenarioFixture.workoutName)
            .tapEdit()
            .moveTrainingStage(from: 0, to: 1)
            .assertDuration("20 seconds", in: .training, stage: 0)
            .assertDuration("40 seconds", in: .training, stage: 1)
            .moveTrainingStage(from: 1, to: 0)
            .assertDuration("40 seconds", in: .training, stage: 0)
            .assertDuration("20 seconds", in: .training, stage: 1)
    }

    /// Save from a focused duration field keeps its last digit: the list shows 45 seconds, not 4.
    func test_newWorkout_save_appearsInList() {
        let app = launch(.emptyList)

        WorkoutListScreen(app)
            .assertIsEmpty()
            .tapAdd()
            .typeName("Morning circuit")
            .setDuration("0045", in: .training, stage: 0)
            .tapSave()
            .assertTitle("Morning circuit")
            .tapBack()
            .assertHasWorkout("Morning circuit", duration: "45 seconds")
    }
}
