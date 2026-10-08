@testable import AppFeature
@testable import SettingsFeature

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
    func test_tabSelected_workoutsReselected_keepsDeferredEditorAndSettingsPath() async {
        var state = loaded([first, second])
        state.pendingMutations = [.delete(UUID(fixture: 99))]
        state.deferredEditor = .create
        let store = makeStore(state) {
            $0.appVersion.shortVersion = { "1.2" }
        }
        await store.send(.settings(.view(.aboutTapped))) {
            $0.settings.path[id: 0] = .about(version: "1.2")
        }

        await store.send(.view(.tabSelected(.workouts)))
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
        await store.send(.view(.addButtonTapped)) { $0.deferredEditor = .create }

        await store.send(.view(.tabSelected(.settings))) {
            $0.selectedTab = .settings
            $0.deferredEditor = nil
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
        await store.send(.view(.workoutTapped(first.id))) { $0.deferredEditor = .edit(self.first.id) }

        await store.send(.view(.tabSelected(.settings))) {
            $0.selectedTab = .settings
            $0.deferredEditor = nil
        }
        gate.open()

        await store.receive(\.internal.workoutsLoaded) { $0.workouts = .loaded([renamed]) }
    }
}
