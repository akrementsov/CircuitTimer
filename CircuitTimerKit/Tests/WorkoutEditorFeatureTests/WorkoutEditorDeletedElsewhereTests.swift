@testable import WorkoutEditorFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain

/// A save that finds its workout deleted on another device, and the two ways out of it.
@MainActor
@Suite
struct WorkoutEditorDeletedElsewhereTests {
    /// The draft of `deletedElsewhereState()` under the identifier `UUID.incrementing` gives first.
    private let copy = Workout(
        id: UUID(0),
        name: "Renamed",
        warmUp: [makeStage(10)],
        training: [makeStage(20), makeStage(21, .rest)],
        trainingRounds: 3,
        coolDown: [makeStage(30, .rest)],
        pauseAfterWarmUp: true
    )

    @Test
    func test_save_deletedElsewhere_offersTheChoiceOnceAndKeepsTheDraft() async {
        let saves = LockIsolated(0)
        let store = makeStore(editingState()) {
            $0.workoutStorage.save = { _ in
                saves.withValue { $0 += 1 }
                return .deletedElsewhere
            }
        }
        await store.send(.view(.nameChanged("Renamed"))) { $0.draft.name = "Renamed" }

        await store.send(.view(.saveButtonTapped)) { $0.isSaving = true }
        await store.receive(\.internal.saveFoundDeletedElsewhere) {
            $0.isSaving = false
            $0.destination = .deletedElsewhereAlert(.deletedElsewhere)
        }
        await store.receive(\.delegate.deletedElsewhere)
        await store.send(.destination(.dismiss)) { $0.destination = nil }

        #expect(store.state.phase == .editing)
        #expect(store.state.draft.name == "Renamed")
        #expect(store.state.workout == makeWorkout())
        #expect(saves.value == 1)
    }

    @Test
    func test_saveAsNew_deletedElsewhere_savesTheDraftOnceUnderANewID() async {
        let saved = LockIsolated<[Workout]>([])
        let store = makeStore(deletedElsewhereState()) {
            $0.workoutStorage.save = { workout in
                saved.withValue { $0.append(workout) }
                return .saved
            }
        }

        await store.send(.destination(.presented(.deletedElsewhereAlert(.saveAsNew)))) {
            $0.destination = nil
            $0.draft = self.copy
            $0.isSaving = true
        }
        await store.receive(\.internal.saveSucceeded, copy) {
            $0.isSaving = false
            $0.workout = self.copy
            $0.original = self.copy
            $0.draft = self.copy
            $0.phase = .viewing
        }
        await store.receive(\.delegate.saved, copy)

        #expect(saved.value == [copy])
        #expect(store.state.canStart)
    }

    @Test
    func test_dontSave_deletedElsewhere_leavesWithoutSavingOrAsking() async {
        let dismissals = LockIsolated(0)
        // Storage is left unimplemented: a write fails the test.
        let store = makeStore(deletedElsewhereState()) {
            $0.dismiss = DismissEffect { dismissals.withValue { $0 += 1 } }
        }

        await store.send(.destination(.presented(.deletedElsewhereAlert(.dontSave)))) { $0.destination = nil }
        await store.finish()

        #expect(dismissals.value == 1)
    }

    @Test
    func test_saveAsNew_saveFails_keepsTheNewIDAndRetrySavesUnderIt() async {
        let savedIDs = LockIsolated<[Workout.ID]>([])
        let store = makeStore(deletedElsewhereState()) {
            $0.workoutStorage.save = { workout in
                let call = savedIDs.withValue { ids in
                    ids.append(workout.id)
                    return ids.count
                }
                if call == 1 {
                    throw SaveFailure()
                }
                return .saved
            }
        }

        await store.send(.destination(.presented(.deletedElsewhereAlert(.saveAsNew)))) {
            $0.destination = nil
            $0.draft = self.copy
            $0.isSaving = true
        }
        await store.receive(\.internal.saveFailed) {
            $0.isSaving = false
            $0.destination = .saveFailedAlert(.saveFailed)
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }

        await store.send(.view(.saveButtonTapped)) { $0.isSaving = true }
        await store.receive(\.internal.saveSucceeded, copy) {
            $0.isSaving = false
            $0.workout = self.copy
            $0.original = self.copy
            $0.draft = self.copy
            $0.phase = .viewing
        }
        await store.receive(\.delegate.saved, copy)

        #expect(savedIDs.value == [UUID(0), UUID(0)])
    }

    /// A changed draft whose save found the workout deleted on another device.
    private func deletedElsewhereState() -> WorkoutEditorFeature.State {
        var state = editingState()
        state.draft.name = "Renamed"
        state.draft.pauseAfterWarmUp = true
        state.destination = .deletedElsewhereAlert(.deletedElsewhere)
        return state
    }

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
}
