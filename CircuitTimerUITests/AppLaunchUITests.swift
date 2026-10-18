import XCTest

/// Runs first, by name: the first launch on a fresh simulator is slow, and it falls on this short test instead of
/// one with many steps that would come close to its time limit.
@MainActor
final class AppLaunchUITests: XCTestCase {
    func test_emptyList_launch_showsEmptyList() {
        let app = launch(.emptyList)

        WorkoutListScreen(app)
            .assertIsEmpty()
    }
}
