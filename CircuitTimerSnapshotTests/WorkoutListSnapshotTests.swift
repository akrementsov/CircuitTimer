import AppFeature
import SnapshotCapture
import Testing

extension SnapshotTests {
    @MainActor
    @Suite
    struct WorkoutListSnapshotTests {
        @Test(arguments: SnapshotTextSize.currentCases())
        func test_list_loaded_matchesReference(textSize: SnapshotTextSize) async throws {
            try await assertAppSnapshot(textSize: textSize) { language in
                .list(SnapshotFixtures.workouts(language: language), hiddenRecordCount: 2)
            }
        }

        @Test(arguments: SnapshotTextSize.currentCases(in: [.large]))
        func test_list_empty_matchesReference(textSize: SnapshotTextSize) async throws {
            try await assertAppSnapshot(textSize: textSize) { _ in
                .list([], hiddenRecordCount: 2)
            }
        }

        @Test(arguments: SnapshotTextSize.currentCases(in: [.large]))
        func test_list_failed_matchesReference(textSize: SnapshotTextSize) async throws {
            try await assertAppSnapshot(textSize: textSize) { _ in
                .failedList
            }
        }
    }
}
