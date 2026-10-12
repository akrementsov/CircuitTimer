@testable import WorkoutEditorFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain

@MainActor
@Suite
struct WorkoutEditorViewingTests {
    private func makeStore(
        _ state: WorkoutEditorFeature.State,
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
    func test_viewActions_viewing_ignoreEverythingButBackEditAndStart() async {
        // Storage and dismissal are left unimplemented: a write or a dismissal fails the test.
        let store = makeStore(WorkoutEditorFeature.State(viewing: makeWorkout()))
        let stage = UUID(fixture: 20)
        let actions: [WorkoutEditorFeature.Action.View] = [
            .nameChanged("Other"),
            .trainingRoundsChanged(9),
            .pauseAfterWarmUpChanged(true),
            .pauseAfterTrainingChanged(true),
            .addStageButtonTapped(.training),
            .stageDeleteButtonTapped(.training, stage),
            .stagesMoved(.training, IndexSet(integer: 1), 0),
            // Ids that would really move, so only the phase keeps them still.
            .stageMovedUp(.training, UUID(fixture: 21)),
            .stageMovedDown(.training, UUID(fixture: 20)),
            .stageNameChanged(.training, stage, "Other"),
            .stageDurationTextChanged(.training, stage, "1"),
            .stageIntensityTapped(.training, stage),
            .saveButtonTapped,
        ]

        for action in actions {
            await store.send(.view(action))
        }
    }

    @Test
    func test_editButtonTapped_viewing_rebuildsTheDraftFromTheStoredWorkout() async {
        var workout = makeWorkout()
        workout.trainingRounds = 0
        var state = WorkoutEditorFeature.State(viewing: workout)
        state.draft.name = "Stale"
        state.isStarting = true
        let store = makeStore(state)

        await store.send(.view(.editButtonTapped)) {
            $0.draft = $0.original
            $0.isStarting = false
            $0.phase = .editing
        }
        #expect(store.state.draft.trainingRounds == 1)
        #expect(store.state.workout.trainingRounds == 0)
    }

    @Test(arguments: [
        WorkoutEditorFeature.State(newWorkoutID: UUID(fixture: 1), firstStageID: UUID(fixture: 2)),
        editingState(makeWorkout()),
    ])
    func test_editAndStart_newOrEditing_changeNothing(state: WorkoutEditorFeature.State) async {
        let store = makeStore(state)

        await store.send(.view(.editButtonTapped))
        await store.send(.view(.startButtonTapped))
    }

    @Test
    func test_startButtonTapped_viewing_startsTheStoredWorkoutNotTheDraft() async {
        // Stored with 0 rounds: the editor lifts its copy to 1, but the warm-up and cool-down still play.
        var workout = makeWorkout()
        workout.trainingRounds = 0
        let store = makeStore(WorkoutEditorFeature.State(viewing: workout))
        #expect(store.state.draft.trainingRounds == 1)

        await store.send(.view(.startButtonTapped)) { $0.isStarting = true }
        await store.receive(\.delegate.startRequested, workout)
    }

    @Test
    func test_startButtonTapped_secondTap_asksOnceAndEditUnblocksStart() async {
        let store = makeStore(WorkoutEditorFeature.State(viewing: makeWorkout()))

        await store.send(.view(.startButtonTapped)) { $0.isStarting = true }
        await store.receive(\.delegate.startRequested)
        await store.send(.view(.startButtonTapped))

        await store.send(.view(.editButtonTapped)) {
            $0.isStarting = false
            $0.phase = .editing
        }
        await store.send(.view(.saveButtonTapped))
        await store.receive(\.internal.editingEnded) { $0.phase = .viewing }
        await store.send(.view(.startButtonTapped)) { $0.isStarting = true }
        await store.receive(\.delegate.startRequested, makeWorkout())
    }

    @Test
    func test_save_untouchedStoredWorkoutWithoutAName_endsEditing() async {
        var workout = makeWorkout()
        workout.name = ""
        // Storage is left unimplemented: a write fails the test.
        let store = makeStore(editingState(workout))

        await store.send(.view(.saveButtonTapped))
        await store.receive(\.internal.editingEnded) { $0.phase = .viewing }

        #expect(store.state.canStart)
    }

    @Test
    func test_backButtonTapped_starting_stillLeaves() async {
        let dismissals = LockIsolated(0)
        var state = WorkoutEditorFeature.State(viewing: makeWorkout())
        state.isStarting = true
        let store = makeStore(state) { $0.dismiss = DismissEffect { dismissals.withValue { $0 += 1 } } }

        await store.send(.view(.backButtonTapped))

        #expect(dismissals.value == 1)
    }

    @Test
    func test_save_newWorkoutFailsThenRetrySucceeds_turnsReadOnlyWithStart() async {
        let calls = LockIsolated(0)
        let store = makeStore(WorkoutEditorFeature.State(newWorkoutID: UUID(fixture: 1), firstStageID: UUID(fixture: 2))) {
            $0.workoutStorage.save = { _ in
                calls.withValue { $0 += 1 }
                if calls.value == 1 {
                    throw SaveFailure()
                }
            }
        }
        await store.send(.view(.nameChanged("  Morning  "))) { $0.draft.name = "  Morning  " }

        await store.send(.view(.saveButtonTapped)) { $0.isSaving = true }
        await store.receive(\.internal.saveFailed) {
            $0.isSaving = false
            $0.destination = .saveFailedAlert(.saveFailed)
        }
        #expect(store.state.phase == .new)
        #expect(store.state.draft.name == "  Morning  ")
        await store.send(.destination(.dismiss)) { $0.destination = nil }

        let saved = WorkoutEditorFeature.normalizedForSaving(store.state.draft)
        await store.send(.view(.saveButtonTapped)) { $0.isSaving = true }
        await store.receive(\.internal.saveSucceeded, saved) {
            $0.isSaving = false
            $0.workout = saved
            $0.original = saved
            $0.draft = saved
            $0.phase = .viewing
        }
        await store.receive(\.delegate.saved, saved)

        #expect(store.state.canStart)
        #expect(calls.value == 2)
    }
}
