@testable import AppFeature
@testable import SettingsFeature
@testable import WorkoutEditorFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain
import WorkoutStorage

@MainActor
@Suite
struct AppFeatureTabTests {
    private let first = makeWorkout(1)
    private let second = makeWorkout(2)

    @Test
    func test_tabSelected_switchBothWays_selectsTabKeepsSettingsPath() async {
        let store = makeStore(loaded([first])) {
            $0.appVersion.shortVersion = { "1.2" }
        }

        await store.send(.view(.tabSelected(.settings))) { $0.selectedTab = .settings }
        await store.send(.settings(.view(.aboutTapped))) {
            $0.settings.path[id: 0] = .about(version: "1.2")
        }
        await store.send(.view(.tabSelected(.workouts))) { $0.selectedTab = .workouts }
        await store.send(.view(.tabSelected(.settings))) { $0.selectedTab = .settings }
    }

    @Test
    func test_tabSelected_settingsReselectedWithPushedScreens_popsToRoot() async {
        var state = loaded([first])
        state.selectedTab = .settings
        let store = makeStore(state) {
            $0.appVersion.shortVersion = { "1.2" }
        }
        await store.send(.settings(.view(.aboutTapped))) {
            $0.settings.path[id: 0] = .about(version: "1.2")
        }
        await store.send(.settings(.view(.legalDocumentTapped(.privacyPolicy)))) {
            $0.settings.path[id: 1] = .legalDocument(.privacyPolicy)
        }

        await store.send(.view(.tabSelected(.settings))) {
            $0.settings.path = StackState()
        }
    }

    @Test
    func test_tabSelected_workoutsReselected_keepsDeferredScreenAndSettingsPath() async {
        var state = loaded([first, second])
        state.pendingMutations = [.delete(UUID(fixture: 99))]
        state.deferredScreen = .create
        let store = makeStore(state) {
            $0.appVersion.shortVersion = { "1.2" }
        }
        await store.send(.settings(.view(.aboutTapped))) {
            $0.settings.path[id: 0] = .about(version: "1.2")
        }

        await store.send(.view(.tabSelected(.workouts)))
    }

    @Test
    func test_tabSelected_workoutsReselectedWithUnchangedEditor_popsStack() async {
        let store = makeStore(loaded([first, second]))
        await store.send(.view(.workoutTapped(first.id))) {
            $0.path[id: 0] = .editor(WorkoutEditorFeature.State(editing: self.first))
        }

        await store.send(.view(.tabSelected(.workouts)))
        await store.receive(.path(.element(id: 0, action: .editor(.view(.backButtonTapped)))))
        await store.receive(\.path.popFrom) { $0.path = StackState() }
    }

    @Test
    func test_tabSelected_workoutsReselectedWithChangedEditor_asksToDiscardAndKeepsStack() async {
        let store = makeStore(loaded([first, second]))
        await store.send(.view(.workoutTapped(first.id))) {
            $0.path[id: 0] = .editor(WorkoutEditorFeature.State(editing: self.first))
        }
        await store.send(.path(.element(id: 0, action: .editor(.view(.nameChanged("Renamed")))))) {
            $0.path[id: 0, case: \.editor]?.draft.name = "Renamed"
        }

        await store.send(.view(.tabSelected(.workouts)))
        await store.receive(.path(.element(id: 0, action: .editor(.view(.backButtonTapped))))) {
            $0.path[id: 0, case: \.editor]?.destination = .discardConfirmation(.discardChanges)
        }
    }

    @Test
    func test_tabSelected_workoutsReselectedWhileSaveInFlight_saveCompletesThenPops() async {
        let gate = Gate()
        var renamed = first
        renamed.name = "Renamed"
        let store = makeStore(loaded([first, second])) {
            $0.workoutStorage.save = { _ in await gate.wait() }
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

        await store.send(.view(.tabSelected(.workouts)))
        await store.receive(.path(.element(id: 0, action: .editor(.view(.backButtonTapped)))))
        gate.open()
        await store.receive(.path(.element(id: 0, action: .editor(.delegate(.saved(renamed)))))) {
            $0.workouts = .loaded([renamed, self.second])
        }
        await store.receive(\.path.popFrom) { $0.path = StackState() }
        await store.finish()
        await store.send(.view(.addButtonTapped)) {
            $0.path[id: 1] = .editor(WorkoutEditorFeature.State(newWorkoutID: UUID(0), firstStageID: UUID(1)))
        }
    }

    @Test
    func test_tabSelected_leaveAndReturnWhileWriting_writeFinishesEditorNotPresented() async {
        let gate = Gate()
        let store = makeStore(loaded([first, second])) {
            $0.workoutStorage.delete = { _ in
                await gate.wait()
                return .applied
            }
        }
        await store.send(.view(.deleteButtonTapped(first.id))) {
            $0.workouts = .loaded([self.second])
            $0.pendingMutations = [.delete(self.first.id)]
        }
        await store.send(.view(.addButtonTapped)) { $0.deferredScreen = .create }

        await store.send(.view(.tabSelected(.settings))) {
            $0.selectedTab = .settings
            $0.deferredScreen = nil
        }
        await store.send(.view(.tabSelected(.workouts))) { $0.selectedTab = .workouts }
        gate.open()

        await store.receive(\.internal.mutationFinished) { $0.pendingMutations = [] }
    }

    @Test
    func test_tabSelected_switchWhileLoading_loadStillUpdatesListEditorNotPresented() async {
        let gate = Gate()
        let renamed = makeWorkout(1, name: "Reloaded")
        let store = makeStore(loaded([first])) {
            $0.workoutStorage.fetchAll = {
                await gate.wait()
                return StoredWorkouts(workouts: [renamed])
            }
        }
        await store.send(.view(.retryButtonTapped)) { $0.workouts = .loading }
        await store.send(.view(.workoutTapped(first.id))) { $0.deferredScreen = .edit(self.first.id) }

        await store.send(.view(.tabSelected(.settings))) {
            $0.selectedTab = .settings
            $0.deferredScreen = nil
        }
        gate.open()

        await store.receive(\.internal.workoutsLoaded) { $0.workouts = .loaded([renamed]) }
    }
}
