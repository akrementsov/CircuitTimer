@testable import WorkoutEditorFeature

import Foundation
import Testing
import WorkoutDomain

@Suite
struct WorkoutEditorStateTests {
    @Test
    func test_hasChanges_whitespaceAndUntouchedStarter_doesNotRequireSaving() {
        var state = editingState()
        state.draft.name = "  Workout  "
        state.draft.warmUp[0].name = "  Stage 10  "
        state.draft.training.insert(Stage(id: UUID(fixture: 99), name: "", duration: .zero, intensity: .work), at: 0)

        #expect(!state.hasChanges)
        #expect(state.canSave)
        #expect(state.saveBlocker == nil)
    }

    @Test
    func test_canSave_editedStageBecomesZero_blocksUntilStageDeleted() {
        var state = editingState()
        state.draft.training[0].duration = .zero

        #expect(state.isDraftComplete)
        #expect(state.unsavableStageIDs == [UUID(fixture: 20)])
        #expect(!state.canSave)
        #expect(state.saveBlocker == .unsavableStage)

        state.draft.training.removeFirst()

        #expect(state.hasChanges)
        #expect(state.canSave)
        #expect(state.saveBlocker == nil)
    }

    @Test
    func test_canSave_storedZeroStage_blocksOnlyWhenThatStageChanges() {
        var workout = makeWorkout()
        workout.warmUp[0].duration = .zero
        var state = editingState(workout)
        state.draft.name = "Renamed"

        #expect(state.canSave)
        #expect(state.unsavableStageIDs.isEmpty)

        state.draft.warmUp[0].name = "Changed empty stage"

        #expect(!state.canSave)
        #expect(state.unsavableStageIDs == [UUID(fixture: 10)])
    }

    struct FlagsCase: CustomTestStringConvertible, Sendable {
        let testDescription: String
        let state: WorkoutEditorFeature.State
        let isDraftComplete: Bool
        let canSave: Bool
        let saveBlocker: WorkoutEditorFeature.State.SaveBlocker?
    }

    static let flagsCases: [FlagsCase] = {
        let untouchedNew = newDraftState()
        let untouched = editingState(makeWorkout())
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
        var storedNameless = makeWorkout()
        storedNameless.name = ""
        let untouchedNameless = editingState(storedNameless)
        var saving = changed
        saving.isSaving = true
        return [
            FlagsCase(
                testDescription: "untouched new",
                state: untouchedNew,
                isDraftComplete: false,
                canSave: false,
                saveBlocker: .incomplete
            ),
            FlagsCase(
                testDescription: "saved workout untouched",
                state: untouched,
                isDraftComplete: true,
                canSave: true,
                saveBlocker: nil
            ),
            FlagsCase(
                testDescription: "complete and changed",
                state: changed,
                isDraftComplete: true,
                canSave: true,
                saveBlocker: nil
            ),
            FlagsCase(
                testDescription: "blank name",
                state: blankName,
                isDraftComplete: false,
                canSave: false,
                saveBlocker: .incomplete
            ),
            FlagsCase(
                testDescription: "nothing to play",
                state: nothingToPlay,
                isDraftComplete: false,
                canSave: false,
                saveBlocker: .unsavableStage
            ),
            FlagsCase(
                testDescription: "stored without a name, untouched",
                state: untouchedNameless,
                isDraftComplete: false,
                canSave: true,
                saveBlocker: nil
            ),
            FlagsCase(
                testDescription: "saving",
                state: saving,
                isDraftComplete: true,
                canSave: false,
                saveBlocker: nil
            ),
        ]
    }()

    @Test
    func test_initNew_givesAnEmptyWorkStageInEverySection() {
        let state = newDraftState()

        #expect(state.phase == .new)
        #expect(state.draft == Workout(
            id: UUID(fixture: 1),
            warmUp: [Stage(id: UUID(fixture: 2), name: "", duration: .zero, intensity: .work)],
            training: [Stage(id: UUID(fixture: 3), name: "", duration: .zero, intensity: .work)],
            coolDown: [Stage(id: UUID(fixture: 4), name: "", duration: .zero, intensity: .work)]
        ))
        #expect(state.original == state.draft)
    }

    @Test(arguments: [(-5, 1), (0, 1), (7, 7), (WorkoutLimits.maxTrainingRounds + 1, WorkoutLimits.maxTrainingRounds)])
    func test_initViewing_liftsRoundsIntoEditorRangeWithoutChanges(stored: Int, expected: Int) {
        var workout = makeWorkout()
        workout.trainingRounds = stored

        let state = WorkoutEditorFeature.State(viewing: workout)

        #expect(state.phase == .viewing)
        #expect(state.draft.trainingRounds == expected)
        #expect(state.original == state.draft)
        #expect(!state.hasChanges)
    }

    @Test(arguments: flagsCases)
    func test_flags_followDraftAndSaving(flags: FlagsCase) {
        #expect(flags.state.isDraftComplete == flags.isDraftComplete)
        #expect(flags.state.canSave == flags.canSave)
        #expect(flags.state.saveBlocker == flags.saveBlocker)
    }

    @Test(arguments: [
        ("Morning", "Morning"),
        ("  Morning  ", "  Morning  "),
        ("", nil),
        (" \t", nil),
    ])
    func test_viewingTitle_storedName_showsItOrNothingWhenBlank(name: String, expected: String?) {
        var workout = makeWorkout()
        workout.name = name

        #expect(WorkoutEditorFeature.State(viewing: workout).viewingTitle == expected)
    }

    @Test
    func test_canReorderStages_phaseSavingAndCount_needTwoEditableStages() {
        let editing = editingState(makeWorkout())
        var saving = editing
        saving.isSaving = true
        var new = newDraftState()

        #expect(editing.canReorderStages(in: .training))
        #expect(!editing.canReorderStages(in: .warmUp))
        #expect(!saving.canReorderStages(in: .training))
        #expect(!WorkoutEditorFeature.State(viewing: makeWorkout()).canReorderStages(in: .training))
        #expect(!new.canReorderStages(in: .training))
        new.draft.training.append(makeStage(5))
        #expect(new.canReorderStages(in: .training))
    }

    @Test
    func test_shownStagesAndSections_viewingOrEditing_followStoredOrDraft() {
        let workout = Workout(
            id: UUID(fixture: 1),
            name: "Workout",
            warmUp: [makeStage(10, seconds: 0)],
            training: [makeStage(20), makeStage(21, .rest)],
            trainingRounds: 0,
            coolDown: [makeStage(30, .rest)]
        )
        let viewing = WorkoutEditorFeature.State(viewing: workout)
        let editing = editingState(workout)

        #expect(viewing.shownStages(in: .warmUp).isEmpty)
        #expect(viewing.shownStages(in: .training).isEmpty)
        #expect(viewing.shownStages(in: .coolDown) == workout.coolDown)
        #expect(WorkoutSectionKind.allCases.map(viewing.showsSection) == [false, false, true])
        #expect(editing.shownStages(in: .warmUp) == workout.warmUp)
        #expect(editing.shownStages(in: .training) == workout.training)
        #expect(WorkoutSectionKind.allCases.allSatisfy(editing.showsSection))
    }

    @Test
    func test_shownDurationsAndRounds_viewingOrEditing_followStoredOrDraft() {
        var workout = makeWorkout()
        workout.trainingRounds = 0
        let viewing = WorkoutEditorFeature.State(viewing: workout)
        let editing = editingState(workout)

        #expect(viewing.shownTrainingRounds == 0)
        #expect(viewing.shownDuration(of: .training) == .zero)
        #expect(viewing.shownTotalDuration == .seconds(20))
        #expect(editing.shownTrainingRounds == 1)
        #expect(editing.shownDuration(of: .training) == .seconds(20))
        #expect(editing.shownTotalDuration == .seconds(40))
    }

    @Test(arguments: [
        // The pause after the warm-up plays over an empty training before a cool-down.
        (Workout(id: UUID(fixture: 1), warmUp: [makeStage(10)], coolDown: [makeStage(30)], pauseAfterWarmUp: true), true),
        (Workout(id: UUID(fixture: 1), warmUp: [makeStage(10)], coolDown: [makeStage(30)]), false),
        (Workout(id: UUID(fixture: 1), warmUp: [makeStage(10)], pauseAfterWarmUp: true), false),
    ])
    func test_showsPauseAfterWarmUp_viewing_onlyAPauseThatPlays(workout: Workout, expected: Bool) {
        #expect(WorkoutEditorFeature.State(viewing: workout).showsPause(after: .warmUp) == expected)
    }

    @Test
    func test_showsPause_trainingEditingAndCoolDown_followTheirRules() {
        let withCoolDown = Workout(id: UUID(fixture: 1), training: [makeStage(20)], coolDown: [makeStage(30)], pauseAfterTraining: true)
        let withoutCoolDown = Workout(id: UUID(fixture: 1), training: [makeStage(20)], pauseAfterTraining: true)
        // While editing, the switch shows wherever a pause would play, whatever its state.
        let editingOff = editingState(Workout(id: UUID(fixture: 1), warmUp: [makeStage(10)], coolDown: [makeStage(30)]))

        #expect(WorkoutEditorFeature.State(viewing: withCoolDown).showsPause(after: .training))
        #expect(!WorkoutEditorFeature.State(viewing: withoutCoolDown).showsPause(after: .training))
        #expect(editingOff.showsPause(after: .warmUp))
        #expect(!editingOff.showsPause(after: .coolDown))
        #expect(!WorkoutEditorFeature.State(viewing: withCoolDown).showsPause(after: .coolDown))
    }

    @Test
    func test_canStart_onlyAPlayableStoredWorkoutOnce() {
        var starting = WorkoutEditorFeature.State(viewing: makeWorkout())
        starting.isStarting = true
        var silent = makeWorkout()
        silent.trainingRounds = 0
        silent.warmUp = []
        silent.coolDown = []

        #expect(WorkoutEditorFeature.State(viewing: makeWorkout()).canStart)
        #expect(!starting.canStart)
        #expect(!WorkoutEditorFeature.State(viewing: silent).canStart)
        #expect(!editingState(makeWorkout()).canStart)
        #expect(!newDraftState().canStart)
    }

    @Test
    func test_showStored_newerVersionWhileViewing_takesItAndKeepsTheScreenState() {
        var state = WorkoutEditorFeature.State(viewing: makeWorkout())
        state.hasSettled = true
        state.saveTipSuppressed = true
        var stored = makeWorkout()
        stored.name = "Renamed"
        stored.trainingRounds = 0

        state.showStored(stored)

        #expect(state.workout == stored)
        #expect(state.original == WorkoutEditorFeature.State.editable(stored))
        #expect(state.original.trainingRounds == 1)
        #expect(state.draft == state.original)
        #expect(state.phase == .viewing)
        #expect(state.hasSettled)
        #expect(state.saveTipSuppressed)
    }

    @Test(arguments: ["same", "editing", "alert", "starting"])
    func test_showStored_sameVersionDraftAlertOrStart_changesNothing(_ situation: String) {
        var state = situation == "editing" ? editingState() : WorkoutEditorFeature.State(viewing: makeWorkout())
        // A draft the stored version would replace, so a replacement shows even when the stored workout is the same.
        state.draft.name = "Draft"
        var stored = makeWorkout()
        switch situation {
            case "alert": state.destination = .saveFailedAlert(.saveFailed)
            case "starting": state.isStarting = true
            default: break
        }
        if situation != "same" {
            stored.name = "Renamed"
        }
        let before = state

        state.showStored(stored)

        #expect(state == before)
    }
}
