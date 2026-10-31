import SnapshotCapture
import Testing
import WorkoutTimerFeature

extension SnapshotTests {
    @MainActor
    @Suite
    struct WorkoutTimerSnapshotTests {
        @Test(arguments: SnapshotTextSize.currentCases())
        func test_timer_startCountdown_matchesReference(textSize: SnapshotTextSize) async throws {
            try await assertTimerSnapshot(textSize: textSize) { language in
                .startCountdown(SnapshotFixtures.editorWorkout(language: language))
            }
        }

        @Test(arguments: SnapshotTextSize.currentCases())
        func test_timer_paused_matchesReference(textSize: SnapshotTextSize) async throws {
            try await assertTimerSnapshot(textSize: textSize) { language in
                .paused(SnapshotFixtures.editorWorkout(language: language))
            }
        }

        @Test(arguments: SnapshotTextSize.currentCases())
        func test_timer_finished_matchesReference(textSize: SnapshotTextSize) async throws {
            try await assertTimerSnapshot(textSize: textSize) { language in
                .finished(SnapshotFixtures.editorWorkout(language: language))
            }
        }

        @Test(arguments: SnapshotTextSize.currentCases())
        func test_timer_stageList_matchesReference(textSize: SnapshotTextSize) async throws {
            try await assertTimerSnapshot(textSize: textSize) { language in
                .stageList(SnapshotFixtures.editorWorkout(language: language))
            }
        }
    }
}
