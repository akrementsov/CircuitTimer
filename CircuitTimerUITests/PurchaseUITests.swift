import UITestContract
import XCTest

@MainActor
final class PurchaseUITests: XCTestCase {
    func test_twoWorkoutsFree_tapLockedICloudSync_opensTheSheetWithItsReasonAndCloses() {
        let app = launch(.twoWorkoutsFree)

        WorkoutListScreen(app)
            .tapSettings()
            .assertICloudSyncLocked()
            .tapLockedICloudSync()
            .assertReason("iCloud sync is part of the full version")
            .tapClose()
            .assertICloudSyncLocked()
    }

    func test_twoWorkoutsFree_buyFromTheLimit_unlocksSettingsAndANewWorkout() {
        let app = launch(.twoWorkoutsFree)

        WorkoutListScreen(app)
            .tapAddAtFreeLimit()
            .assertReason("The free version keeps two workouts")
            .tapBuy()
            .assertPurchased()
            .tapDone()
            .tapSettings()
            .assertFullVersionPurchased()
            .tapWorkouts()
            .tapAdd()
            .assertTitle("New Workout")
    }
}
