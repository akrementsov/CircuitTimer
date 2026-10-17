import UITestContract
import XCTest

@MainActor
final class WorkoutEditorUITests: XCTestCase {
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
