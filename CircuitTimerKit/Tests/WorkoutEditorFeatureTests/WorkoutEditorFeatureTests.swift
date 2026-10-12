@testable import WorkoutEditorFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain

@MainActor
@Suite
struct WorkoutEditorFeatureTests {
    private func makeStore(
        _ state: WorkoutEditorFeature.State = editingState(makeWorkout()),
        dependencies: (inout DependencyValues) -> Void = { _ in }
    ) -> TestStoreOf<WorkoutEditorFeature> {
        TestStore(initialState: state) {
            WorkoutEditorFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            dependencies(&$0)
        }
    }

    @Test
    func test_fieldActions_changeDraftAndBackToOriginalClearsChanges() async {
        let dismissed = LockIsolated(false)
        let store = makeStore { $0.dismiss = DismissEffect { dismissed.setValue(true) } }

        await store.send(.view(.nameChanged("Renamed"))) { $0.draft.name = "Renamed" }
        await store.send(.view(.pauseAfterWarmUpChanged(true))) { $0.draft.pauseAfterWarmUp = true }
        await store.send(.view(.pauseAfterTrainingChanged(true))) { $0.draft.pauseAfterTraining = true }
        #expect(store.state.original == makeWorkout())
        await store.send(.view(.nameChanged("Workout"))) { $0.draft.name = "Workout" }
        await store.send(.view(.pauseAfterWarmUpChanged(false))) { $0.draft.pauseAfterWarmUp = false }
        await store.send(.view(.pauseAfterTrainingChanged(false))) { $0.draft.pauseAfterTraining = false }

        #expect(!store.state.hasChanges)
        await store.send(.view(.backButtonTapped))
        #expect(dismissed.value)
    }

    @Test(arguments: [
        (-1, 1),
        (0, 1),
        (WorkoutLimits.maxTrainingRounds, WorkoutLimits.maxTrainingRounds),
        (WorkoutLimits.maxTrainingRounds + 1, WorkoutLimits.maxTrainingRounds),
    ])
    func test_trainingRoundsChanged_clampsToEditorRange(input: Int, expected: Int) async {
        let store = makeStore()
        store.exhaustivity = .off

        await store.send(.view(.trainingRoundsChanged(input)))

        #expect(store.state.draft.trainingRounds == expected)
    }

    @Test
    func test_addStage_belowLimitAppendsAndAtLimitDoesNothing() async {
        var workout = makeWorkout()
        workout.training = (1..<WorkoutLimits.maxStagesPerSection).map { makeStage(100 + $0) }
        let store = makeStore(editingState(workout))

        await store.send(.view(.addStageButtonTapped(.training))) {
            $0.draft.training.append(Stage(id: UUID(0), name: "", duration: .seconds(30), intensity: .work))
        }
        #expect(!store.state.canAddStage(to: .training))
        await store.send(.view(.addStageButtonTapped(.training)))
        await store.send(.view(.addStageButtonTapped(.warmUp))) {
            $0.draft.warmUp.append(Stage(id: UUID(1), name: "", duration: .seconds(30), intensity: .work))
        }
    }

    @Test
    func test_stageEdits_changeOnlyTheAddressedStage() async {
        let store = makeStore()
        let rest = UUID(fixture: 21)

        await store.send(.view(.stageNameChanged(.training, rest, "Breathe"))) { $0.draft.training[1].name = "Breathe" }
        await store.send(.view(.stageDurationTextChanged(.training, rest, "00:45"))) {
            $0.draft.training[1].duration = .seconds(45)
        }
        await store.send(.view(.stageIntensityTapped(.training, rest))) { $0.draft.training[1].intensity = .work }
        await store.send(.view(.stageIntensityTapped(.training, rest))) { $0.draft.training[1].intensity = .rest }
        await store.send(.view(.stageNameChanged(.warmUp, rest, "Wrong section")))
        await store.send(.view(.stageNameChanged(.training, UUID(fixture: 999), "Unknown")))
    }

    @Test(arguments: [("99:99", WorkoutLimits.maxStageDuration), ("", .zero)])
    func test_stageDurationTextChanged_parsesWithinStageLimits(text: String, expected: Duration) async {
        let store = makeStore()

        await store.send(.view(.stageDurationTextChanged(.warmUp, UUID(fixture: 10), text))) {
            $0.draft.warmUp[0].duration = expected
        }
    }

    @Test
    func test_stageDeleteAndMove_addressedStages_changeTheDraft() async {
        let store = makeStore()

        await store.send(.view(.stagesMoved(.training, IndexSet(integer: 1), 0))) {
            $0.draft.training = [makeStage(21, .rest), makeStage(20)]
        }
        await store.send(.view(.stageDeleteButtonTapped(.coolDown, UUID(fixture: 30)))) { $0.draft.coolDown = [] }
        await store.send(.view(.stageDeleteButtonTapped(.training, UUID(fixture: 21)))) {
            $0.draft.training = [makeStage(20)]
        }
    }

    @Test(arguments: [
        (WorkoutSectionKind.training, UUID(fixture: 99)),
        (.warmUp, UUID(fixture: 20)),
    ])
    func test_stageDeleteButtonTapped_idNotInSection_isNoOp(section: WorkoutSectionKind, id: UUID) async {
        let store = makeStore()

        await store.send(.view(.stageDeleteButtonTapped(section, id)))
    }

    @Test(arguments: [
        ("source past the end", IndexSet(integer: 2), 0),
        ("destination past the end", IndexSet(integer: 0), 3),
        ("negative destination", IndexSet(integer: 0), -1),
        ("empty source", IndexSet(), 0),
    ])
    func test_stagesMoved_staleOffsets_isNoOp(_ name: String, source: IndexSet, destination: Int) async {
        let store = makeStore()

        await store.send(.view(.stagesMoved(.training, source, destination)))
    }

    @Test
    func test_stageMovedUpAndDown_middleStage_swapsWithNeighbour() async {
        let first = makeStage(20)
        let middle = makeStage(21, .rest)
        let last = makeStage(22)
        var workout = makeWorkout()
        workout.training = [first, middle, last]
        let store = makeStore(editingState(workout))

        await store.send(.view(.stageMovedUp(.training, middle.id))) { $0.draft.training = [middle, first, last] }
        #expect(store.state.hasChanges)
        await store.send(.view(.stageMovedDown(.training, middle.id))) { $0.draft.training = [first, middle, last] }
        #expect(!store.state.hasChanges)
        await store.send(.view(.stageMovedDown(.training, middle.id))) { $0.draft.training = [first, last, middle] }
    }

    @Test(arguments: [
        ("first up", [20, 21, 22], WorkoutEditorFeature.Action.View.stageMovedUp(.training, UUID(fixture: 20))),
        ("last down", [20, 21, 22], .stageMovedDown(.training, UUID(fixture: 22))),
        ("single up", [20], .stageMovedUp(.training, UUID(fixture: 20))),
        ("single down", [20], .stageMovedDown(.training, UUID(fixture: 20))),
        ("empty up", [], .stageMovedUp(.training, UUID(fixture: 20))),
        ("empty down", [], .stageMovedDown(.training, UUID(fixture: 20))),
        ("unknown up", [20, 21], .stageMovedUp(.training, UUID(fixture: 99))),
        ("unknown down", [20, 21], .stageMovedDown(.training, UUID(fixture: 99))),
        ("other section up", [20, 21], .stageMovedUp(.warmUp, UUID(fixture: 21))),
        ("other section down", [20, 21], .stageMovedDown(.warmUp, UUID(fixture: 20))),
    ])
    func test_stageMovedUpAndDown_edgeUnknownOtherSectionSingleOrEmpty_isNoOp(
        _ name: String,
        training: [Int],
        action: WorkoutEditorFeature.Action.View
    ) async {
        var workout = makeWorkout()
        workout.training = training.map { makeStage($0) }
        let store = makeStore(editingState(workout))

        await store.send(.view(action))
    }

    @Test
    func test_save_changedDraft_savesNormalizedCopyThenReturnsToViewing() async {
        let events = LockIsolated<[String]>([])
        let saved = LockIsolated<Workout?>(nil)
        let store = makeStore {
            $0.workoutStorage.save = { workout in
                saved.setValue(workout)
                events.withValue { $0.append("save") }
            }
            $0.dismiss = DismissEffect { events.withValue { $0.append("dismiss") } }
        }
        await store.send(.view(.nameChanged("  Morning  "))) { $0.draft.name = "  Morning  " }
        await store.send(.view(.stageNameChanged(.warmUp, UUID(fixture: 10), " Jog "))) { $0.draft.warmUp[0].name = " Jog " }
        await store.send(.view(.stageDurationTextChanged(.coolDown, UUID(fixture: 30), ""))) { $0.draft.coolDown[0].duration = .zero }
        let draft = store.state.draft
        var expected = draft
        expected.name = "Morning"
        expected.warmUp[0].name = "Jog"
        expected.coolDown = []

        await store.send(.view(.saveButtonTapped)) { $0.isSaving = true }
        await store.receive(\.internal.saveSucceeded, expected) {
            $0.isSaving = false
            $0.workout = expected
            $0.original = expected
            $0.draft = expected
            $0.phase = .viewing
        }
        await store.receive(\.delegate.saved, expected)

        await store.finish()
        #expect(saved.value == expected)
        #expect(draft != expected)
        #expect(events.value == ["save"])
    }

    @Test
    func test_save_untouchedSavedWorkout_endsEditingWithoutWriting() async {
        var workout = makeWorkout()
        workout.trainingRounds = 0
        // Storage is left unimplemented: a write fails the test.
        let store = makeStore(editingState(workout))

        await store.send(.view(.saveButtonTapped))
        await store.receive(\.internal.editingEnded) { $0.phase = .viewing }

        #expect(store.state.workout == workout)
        #expect(store.state.canStart)
    }

    @Test
    func test_save_guardFails_doesNothing() async {
        let blankName = makeStore()
        await blankName.send(.view(.nameChanged("   "))) { $0.draft.name = "   " }
        await blankName.send(.view(.saveButtonTapped))

        var silent = makeWorkout()
        silent.name = "Silent"
        for section in WorkoutSectionKind.allCases {
            silent[section] = silent[section].map { Stage(id: $0.id, name: $0.name, duration: .zero, intensity: $0.intensity) }
        }
        let nothingToPlay = makeStore(editingState(silent))
        await nothingToPlay.send(.view(.nameChanged("Still silent"))) { $0.draft.name = "Still silent" }
        await nothingToPlay.send(.view(.saveButtonTapped))
    }

    @Test
    func test_save_whileDiscardDialogShown_closesDialogAndSaves() async {
        let store = makeStore {
            $0.workoutStorage.save = { _ in }
            $0.dismiss = DismissEffect {}
        }
        await store.send(.view(.nameChanged("Renamed"))) { $0.draft.name = "Renamed" }
        await store.send(.view(.backButtonTapped)) { $0.destination = .discardConfirmation(.discardChanges) }

        await store.send(.view(.saveButtonTapped)) {
            $0.destination = nil
            $0.isSaving = true
        }
        await store.receive(\.internal.saveSucceeded) { $0.returnToViewing(savedName: "Renamed") }
        await store.receive(\.delegate.saved)
    }

    @Test
    func test_save_failsThenRetrySucceeds() async {
        let failing = LockIsolated(true)
        let store = makeStore {
            $0.workoutStorage.save = { _ in
                if failing.value {
                    throw SaveFailure()
                }
            }
            $0.dismiss = DismissEffect {}
        }
        await store.send(.view(.nameChanged("Renamed"))) { $0.draft.name = "Renamed" }

        await store.send(.view(.saveButtonTapped)) { $0.isSaving = true }
        await store.receive(\.internal.saveFailed) {
            $0.isSaving = false
            $0.destination = .saveFailedAlert(.saveFailed)
        }
        #expect(store.state.draft.name == "Renamed")
        await store.send(.destination(.dismiss)) { $0.destination = nil }

        failing.setValue(false)
        await store.send(.view(.saveButtonTapped)) { $0.isSaving = true }
        await store.receive(\.internal.saveSucceeded) { $0.returnToViewing(savedName: "Renamed") }
        await store.receive(\.delegate.saved)
    }

    @Test
    func test_save_cancelled_reportsNothingAndKeepsSaving() async {
        let store = makeStore {
            $0.workoutStorage.save = { _ in throw CancellationError() }
            $0.dismiss = DismissEffect { Issue.record("A cancelled save must not dismiss") }
        }
        await store.send(.view(.nameChanged("Renamed"))) { $0.draft.name = "Renamed" }

        await store.send(.view(.saveButtonTapped)) { $0.isSaving = true }
        await store.finish()
    }

    @Test
    func test_backButtonTapped_unchangedOrChanged_dismissesOrAsks() async {
        let dismissals = LockIsolated(0)
        let dependencies: (inout DependencyValues) -> Void = { $0.dismiss = DismissEffect { dismissals.withValue { $0 += 1 } } }
        let untouchedEdit = makeStore(dependencies: dependencies)
        let untouchedNew = makeStore(
            WorkoutEditorFeature.State(newWorkoutID: UUID(fixture: 1), firstStageID: UUID(fixture: 2)),
            dependencies: dependencies
        )
        let changed = makeStore(dependencies: dependencies)

        await untouchedEdit.send(.view(.backButtonTapped))
        await untouchedNew.send(.view(.backButtonTapped))
        await changed.send(.view(.nameChanged("Renamed"))) { $0.draft.name = "Renamed" }
        await changed.send(.view(.backButtonTapped)) { $0.destination = .discardConfirmation(.discardChanges) }

        #expect(dismissals.value == 2)
    }

    @Test
    func test_discardDialog_discardDismissesAndKeepEditingStays() async {
        let dismissals = LockIsolated(0)
        let store = makeStore { $0.dismiss = DismissEffect { dismissals.withValue { $0 += 1 } } }
        await store.send(.view(.nameChanged("Renamed"))) { $0.draft.name = "Renamed" }

        await store.send(.view(.backButtonTapped)) { $0.destination = .discardConfirmation(.discardChanges) }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        #expect(dismissals.value == 0)
        #expect(store.state.draft.name == "Renamed")

        await store.send(.view(.backButtonTapped)) { $0.destination = .discardConfirmation(.discardChanges) }
        await store.send(.destination(.presented(.discardConfirmation(.discard)))) { $0.destination = nil }
        #expect(dismissals.value == 1)
    }

    @Test
    func test_whileSaving_viewActionsAndDiscardAreIgnored() async {
        var state = editingState(makeWorkout())
        state.draft.name = "Renamed"
        state.isSaving = true
        state.destination = .discardConfirmation(.discardChanges)
        let store = makeStore(state) { $0.dismiss = DismissEffect { Issue.record("Saving must not be dismissed") } }
        let stage = UUID(fixture: 20)
        let actions: [WorkoutEditorFeature.Action.View] = [
            .nameChanged("Other"),
            .trainingRoundsChanged(9),
            .pauseAfterWarmUpChanged(true),
            .pauseAfterTrainingChanged(true),
            .addStageButtonTapped(.training),
            .stageDeleteButtonTapped(.training, stage),
            .stagesMoved(.training, IndexSet(integer: 1), 0),
            // Ids that would really move, so only the saving guard keeps them still.
            .stageMovedUp(.training, UUID(fixture: 21)),
            .stageMovedDown(.training, UUID(fixture: 20)),
            .stageNameChanged(.training, stage, "Other"),
            .stageDurationTextChanged(.training, stage, "1"),
            .stageIntensityTapped(.training, stage),
            .backButtonTapped,
            .saveButtonTapped,
        ]

        for action in actions {
            await store.send(.view(action))
        }
        await store.send(.destination(.presented(.discardConfirmation(.discard)))) { $0.destination = nil }
    }
}

private extension WorkoutEditorFeature.State {
    /// After a successful save of `makeWorkout()` renamed to `savedName`: read-only, showing what was written.
    mutating func returnToViewing(savedName: String) {
        var saved = makeWorkout()
        saved.name = savedName
        isSaving = false
        workout = saved
        original = saved
        draft = saved
        phase = .viewing
    }
}
