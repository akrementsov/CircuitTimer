@testable import AppFeature
@testable import WorkoutEditorFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain
import WorkoutStorage

/// The editor's own `dismiss` is not stubbed here: inside the Workouts stack it must pop the editor's element.
@MainActor
@Suite
struct AppFeatureEditorStackTests {
    private struct SaveFailure: Error {}

    private let first = makeWorkout(1)
    private let second = makeWorkout(2)

    @Test
    func test_saveFailed_pushedEditor_staysOnStackWithAlertAndListUntouched() async {
        let store = makeStore(loaded([first, second])) {
            $0.workoutStorage.save = { _ in throw SaveFailure() }
        }
        await store.send(.view(.workoutTapped(first.id))) {
            $0.path[id: 0] = .editor(WorkoutEditorFeature.State(editing: self.first))
        }
        await store.send(.path(.element(id: 0, action: .editor(.view(.nameChanged("Renamed")))))) {
            $0.path[id: 0, case: \.editor]?.draft.name = "Renamed"
        }

        await store.send(.path(.element(id: 0, action: .editor(.view(.saveButtonTapped))))) {
            $0.path[id: 0, case: \.editor]?.isSaving = true
        }
        await store.receive(.path(.element(id: 0, action: .editor(.internal(.saveFailed))))) {
            $0.path[id: 0, case: \.editor]?.isSaving = false
            $0.path[id: 0, case: \.editor]?.destination = .saveFailedAlert(.saveFailed)
        }
    }

    @Test
    func test_discardConfirmed_changedDraftPushedEditor_popsStackAndLeavesListUntouched() async {
        let store = makeStore(loaded([first, second])) {
            $0.workoutStorage.save = { _ in Issue.record("Discarding must not save") }
        }
        await store.send(.view(.workoutTapped(first.id))) {
            $0.path[id: 0] = .editor(WorkoutEditorFeature.State(editing: self.first))
        }
        await store.send(.path(.element(id: 0, action: .editor(.view(.nameChanged("Renamed")))))) {
            $0.path[id: 0, case: \.editor]?.draft.name = "Renamed"
        }
        await store.send(.path(.element(id: 0, action: .editor(.view(.backButtonTapped))))) {
            $0.path[id: 0, case: \.editor]?.destination = .discardConfirmation(.discardChanges)
        }

        await store.send(.path(.element(id: 0, action: .editor(.destination(.presented(.discardConfirmation(.discard))))))) {
            $0.path[id: 0, case: \.editor]?.destination = nil
        }
        await store.receive(\.path.popFrom) { $0.path = StackState() }
    }

    @Test
    func test_openScreen_editorAlreadyPushed_doesNotPushAgain() async {
        var state = loaded([first, second])
        state.path.append(.editor(WorkoutEditorFeature.State(editing: first)))
        state.pendingMutations = [.delete(UUID(fixture: 99))]
        state.deferredScreen = .create
        let store = makeStore(state)

        await store.send(.internal(.mutationFinished(.applied))) {
            $0.pendingMutations = []
            $0.deferredScreen = nil
        }
        await store.send(.view(.addButtonTapped))
        await store.send(.view(.workoutTapped(second.id)))
    }
}
