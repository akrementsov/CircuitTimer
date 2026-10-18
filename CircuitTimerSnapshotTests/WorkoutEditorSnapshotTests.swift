import AppFeature
import SnapshotCapture
import Testing

extension SnapshotTests {
    @MainActor
    @Suite
    struct WorkoutEditorSnapshotTests {
        @Test(arguments: SnapshotTextSize.allCases)
        func test_editor_viewing_matchesReference(textSize: SnapshotTextSize) async throws {
            try await assertAppSnapshot(textSize: textSize) { language in
                .viewing(SnapshotFixtures.editorWorkout(language: language))
            }
        }

        @Test(arguments: SnapshotTextSize.allCases)
        func test_editor_editing_matchesReference(textSize: SnapshotTextSize) async throws {
            try await assertAppSnapshot(textSize: textSize) { language in
                .editing(SnapshotFixtures.editorWorkout(language: language))
            }
        }
    }
}
