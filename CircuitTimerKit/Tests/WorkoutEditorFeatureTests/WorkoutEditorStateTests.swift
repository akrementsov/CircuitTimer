@testable import WorkoutEditorFeature

import Foundation
import Testing
import WorkoutDomain

@Suite
struct WorkoutEditorStateTests {
    struct FlagsCase: CustomTestStringConvertible, Sendable {
        let testDescription: String
        let state: WorkoutEditorFeature.State
        let isDraftComplete: Bool
        let canSave: Bool
        let showsSaveHint: Bool
    }

    static let flagsCases: [FlagsCase] = {
        let untouchedNew = WorkoutEditorFeature.State(newWorkoutID: UUID(fixture: 1), firstStageID: UUID(fixture: 2))
        let untouched = WorkoutEditorFeature.State(editing: makeWorkout())
        var changed = untouched
        changed.draft.name = "Changed"
        var blankName = untouched
        blankName.draft.name = "  "
        var nothingToPlay = untouched
        for section in WorkoutSectionKind.allCases {
            nothingToPlay.draft[section] = nothingToPlay.draft[section].map { stage in
                var stage = stage
                stage.duration = .zero
                return stage
            }
        }
        var saving = changed
        saving.isSaving = true
        return [
            FlagsCase(
                testDescription: "untouched new",
                state: untouchedNew,
                isDraftComplete: false,
                canSave: false,
                showsSaveHint: true
            ),
            FlagsCase(
                testDescription: "complete but untouched",
                state: untouched,
                isDraftComplete: true,
                canSave: false,
                showsSaveHint: false
            ),
            FlagsCase(
                testDescription: "complete and changed",
                state: changed,
                isDraftComplete: true,
                canSave: true,
                showsSaveHint: false
            ),
            FlagsCase(
                testDescription: "blank name",
                state: blankName,
                isDraftComplete: false,
                canSave: false,
                showsSaveHint: true
            ),
            FlagsCase(
                testDescription: "nothing to play",
                state: nothingToPlay,
                isDraftComplete: false,
                canSave: false,
                showsSaveHint: true
            ),
            FlagsCase(
                testDescription: "saving",
                state: saving,
                isDraftComplete: true,
                canSave: false,
                showsSaveHint: false
            ),
        ]
    }()

    @Test
    func test_initNew_givesOneWorkStageInTraining() {
        let state = WorkoutEditorFeature.State(newWorkoutID: UUID(fixture: 1), firstStageID: UUID(fixture: 2))

        #expect(state.mode == .create)
        #expect(state.draft == Workout(
            id: UUID(fixture: 1),
            training: [Stage(id: UUID(fixture: 2), name: "", duration: .seconds(30), intensity: .work)]
        ))
        #expect(state.original == state.draft)
    }

    @Test(arguments: [(-5, 1), (0, 1), (7, 7), (WorkoutLimits.maxTrainingRounds + 1, WorkoutLimits.maxTrainingRounds)])
    func test_initEditing_liftsRoundsIntoEditorRangeWithoutChanges(stored: Int, expected: Int) {
        var workout = makeWorkout()
        workout.trainingRounds = stored

        let state = WorkoutEditorFeature.State(editing: workout)

        #expect(state.mode == .edit)
        #expect(state.draft.trainingRounds == expected)
        #expect(state.original == state.draft)
        #expect(!state.hasChanges)
    }

    @Test(arguments: flagsCases)
    func test_flags_followDraftAndSaving(flags: FlagsCase) {
        #expect(flags.state.isDraftComplete == flags.isDraftComplete)
        #expect(flags.state.canSave == flags.canSave)
        #expect(flags.state.showsSaveHint == flags.showsSaveHint)
    }
}
