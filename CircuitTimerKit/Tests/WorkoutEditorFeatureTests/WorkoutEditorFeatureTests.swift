@testable import WorkoutEditorFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain

@MainActor
@Suite
struct WorkoutEditorFeatureTests {
    private func makeStore(
        _ state: WorkoutEditorFeature.State = WorkoutEditorFeature.State(editing: makeWorkout()),
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
        #expect(!store.state.canSave)
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
        let store = makeStore(WorkoutEditorFeature.State(editing: workout))

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
        await store.send(.view(.stageDurationChanged(.training, rest, .seconds(45)))) {
            $0.draft.training[1].duration = .seconds(45)
        }
        await store.send(.view(.stageIntensityTapped(.training, rest))) { $0.draft.training[1].intensity = .work }
        await store.send(.view(.stageIntensityTapped(.training, rest))) { $0.draft.training[1].intensity = .rest }
        await store.send(.view(.stageNameChanged(.warmUp, rest, "Wrong section")))
        await store.send(.view(.stageNameChanged(.training, UUID(fixture: 999), "Unknown")))
    }

    @Test(arguments: [(-1, 0), (WorkoutLimits.maxStageDuration.components.seconds + 1, WorkoutLimits.maxStageDuration.components.seconds)])
    func test_stageDurationChanged_clampsToStageLimits(input: Int64, expected: Int64) async {
        let store = makeStore()

        await store.send(.view(.stageDurationChanged(.warmUp, UUID(fixture: 10), .seconds(input)))) {
            $0.draft.warmUp[0].duration = .seconds(expected)
        }
    }

    @Test
    func test_stageDeletedMovedAndExpanded_keepPickerConsistent() async {
        let store = makeStore()
        let first = UUID(fixture: 20)
        let second = UUID(fixture: 21)

        await store.send(.view(.stageDurationTapped(first))) { $0.expandedStageID = first }
        await store.send(.view(.stageDurationTapped(second))) { $0.expandedStageID = second }
        await store.send(.view(.stageDurationTapped(second))) { $0.expandedStageID = nil }
        await store.send(.view(.stageDurationTapped(second))) { $0.expandedStageID = second }
        await store.send(.view(.stagesMoved(.training, IndexSet(integer: 1), 0))) {
            $0.draft.training = [makeStage(21, .rest), makeStage(20)]
        }
        await store.send(.view(.stageDeleteButtonTapped(.coolDown, UUID(fixture: 30)))) { $0.draft.coolDown = [] }
        await store.send(.view(.stageDeleteButtonTapped(.training, UUID(fixture: 21)))) {
            $0.draft.training = [makeStage(20)]
            $0.expandedStageID = nil
        }
    }

    @Test
    func test_save_changedDraft_savesNormalizedCopyThenDelegatesThenDismisses() async {
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
        await store.send(.view(.stageDurationChanged(.coolDown, UUID(fixture: 30), .zero))) { $0.draft.coolDown[0].duration = .zero }
        let draft = store.state.draft
        var expected = draft
        expected.name = "Morning"
        expected.warmUp[0].name = "Jog"
        expected.coolDown = []

        await store.send(.view(.saveButtonTapped)) { $0.isSaving = true }
        await store.receive(\.delegate.saved, expected)

        await store.finish()
        #expect(saved.value == expected)
        #expect(store.state.draft == draft)
        #expect(events.value == ["save", "dismiss"])
    }

    @Test
    func test_save_guardFails_doesNothing() async {
        let untouched = makeStore()
        await untouched.send(.view(.saveButtonTapped))

        let blankName = makeStore()
        await blankName.send(.view(.nameChanged("   "))) { $0.draft.name = "   " }
        await blankName.send(.view(.saveButtonTapped))

        var silent = makeWorkout()
        silent.name = "Silent"
        for section in WorkoutSectionKind.allCases {
            silent[section] = silent[section].map { Stage(id: $0.id, name: $0.name, duration: .zero, intensity: $0.intensity) }
        }
        let nothingToPlay = makeStore(WorkoutEditorFeature.State(editing: silent))
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
        var state = WorkoutEditorFeature.State(editing: makeWorkout())
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
            .stageNameChanged(.training, stage, "Other"),
            .stageDurationChanged(.training, stage, .seconds(1)),
            .stageIntensityTapped(.training, stage),
            .stageDurationTapped(stage),
            .backButtonTapped,
            .saveButtonTapped,
        ]

        for action in actions {
            await store.send(.view(action))
        }
        await store.send(.destination(.presented(.discardConfirmation(.discard)))) { $0.destination = nil }
    }
}
