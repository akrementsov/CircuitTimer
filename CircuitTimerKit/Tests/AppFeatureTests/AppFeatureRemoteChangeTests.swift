@testable import AppFeature
@testable import WorkoutEditorFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain
import WorkoutStorage

/// Storage changed without a write of this list: iCloud brought another device's changes, or a save found its workout
/// deleted on another device.
@MainActor
@Suite
struct AppFeatureRemoteChangeTests {
    private let first = makeWorkout(1)
    private let second = makeWorkout(2)
    private let third = makeWorkout(3)
    private let renamedFirst = makeWorkout(1, name: "Renamed")

    @Test
    func test_task_remoteChanges_eachOneReloadsTheShownList() async {
        let changes = AsyncStream<Void>.makeStream()
        let fetches = LockIsolated(0)
        let store = makeStore(AppFeature.State()) {
            $0.cloudSync.remoteChanges = { changes.stream }
            $0.workoutStorage.fetchAll = {
                let call = fetches.withValue { count in
                    count += 1
                    return count
                }
                return StoredWorkouts(workouts: Array([self.first, self.second, self.third].prefix(call)))
            }
        }

        await store.send(.view(.task)) {
            $0.workouts = .loading
            $0.runRestore = .reading
        }
        await store.receive(.internal(.runRecordLoaded(nil))) { $0.runRestore = .resolved }
        await store.receive(\.internal.workoutsLoaded) { $0.workouts = .loaded([self.first]) }

        changes.continuation.yield()
        await store.receive(\.internal.workoutsChangedRemotely) { $0.isReloading = true }
        await store.receive(\.internal.workoutsLoaded) {
            $0.isReloading = false
            $0.workouts = .loaded([self.first, self.second])
        }
        changes.continuation.yield()
        await store.receive(\.internal.workoutsChangedRemotely) { $0.isReloading = true }
        await store.receive(\.internal.workoutsLoaded) {
            $0.isReloading = false
            $0.workouts = .loaded([self.first, self.second, self.third])
        }

        changes.continuation.finish()
        await store.finish()
        #expect(fetches.value == 3)
    }

    @Test
    func test_workoutsChangedRemotely_loadedIdleList_readsOnce() async {
        let fetches = LockIsolated(0)
        let store = makeStore(loaded([first, second])) {
            $0.workoutStorage.fetchAll = {
                fetches.withValue { $0 += 1 }
                return StoredWorkouts(workouts: [self.renamedFirst, self.second])
            }
        }

        await store.send(.internal(.workoutsChangedRemotely)) { $0.isReloading = true }
        await store.receive(\.internal.workoutsLoaded) {
            $0.isReloading = false
            $0.workouts = .loaded([self.renamedFirst, self.second])
        }

        #expect(fetches.value == 1)
    }

    @Test
    func test_workoutsChangedRemotely_firstLoadInFlight_readsAgainOnceItLands() async {
        var state = AppFeature.State()
        state.workouts = .loading
        let fetches = LockIsolated(0)
        let store = makeStore(state) {
            $0.workoutStorage.fetchAll = {
                fetches.withValue { $0 += 1 }
                return StoredWorkouts(workouts: [self.first, self.second])
            }
        }

        await store.send(.internal(.workoutsChangedRemotely)) { $0.needsReload = true }
        await store.send(.internal(.workoutsLoaded(StoredWorkouts(workouts: [first])))) { $0.needsReload = false }
        await store.receive(\.internal.workoutsLoaded) { $0.workouts = .loaded([self.first, self.second]) }

        #expect(fetches.value == 1)
    }

    @Test
    func test_workoutsChangedRemotely_firstLoadFails_retryReadsOnce() async {
        var state = AppFeature.State()
        state.workouts = .loading
        let fetches = LockIsolated(0)
        let store = makeStore(state) {
            $0.workoutStorage.fetchAll = {
                fetches.withValue { $0 += 1 }
                return StoredWorkouts(workouts: [self.first])
            }
        }

        await store.send(.internal(.workoutsChangedRemotely)) { $0.needsReload = true }
        await store.send(.internal(.workoutsLoadingFailed)) {
            $0.needsReload = false
            $0.workouts = .failed
        }
        await store.send(.view(.retryButtonTapped)) { $0.workouts = .loading }
        await store.receive(\.internal.workoutsLoaded) { $0.workouts = .loaded([self.first]) }

        #expect(fetches.value == 1)
    }

    @Test
    func test_workoutsChangedRemotely_writesQueued_readsAfterTheLastWrite() async {
        var state = loaded([second])
        // The first delete is in flight; the second waits for it.
        state.pendingMutations = [.delete(first.id), .delete(third.id)]
        let events = LockIsolated<[String]>([])
        let store = makeStore(state) {
            $0.workoutStorage.delete = { _ in
                events.withValue { $0.append("delete") }
                return .applied
            }
            $0.workoutStorage.fetchAll = {
                events.withValue { $0.append("fetch") }
                return StoredWorkouts(workouts: [self.renamedFirst, self.second])
            }
        }

        await store.send(.internal(.workoutsChangedRemotely)) { $0.needsReload = true }
        await store.send(.internal(.mutationFinished(.applied))) { $0.pendingMutations = [.delete(self.third.id)] }
        await store.receive(\.internal.mutationFinished) {
            $0.pendingMutations = []
            $0.needsReload = false
            $0.isReloading = true
        }
        await store.receive(\.internal.workoutsLoaded) {
            $0.isReloading = false
            $0.workouts = .loaded([self.renamedFirst, self.second])
        }

        #expect(events.value == ["delete", "fetch"])
    }

    @Test
    func test_workoutsChangedRemotely_severalDuringAReload_readOnceMoreAfterIt() async {
        let gate = Gate()
        let fetches = LockIsolated(0)
        let store = makeStore(loaded([first, second])) {
            $0.workoutStorage.fetchAll = {
                let call = fetches.withValue { count in
                    count += 1
                    return count
                }
                if call == 1 {
                    await gate.wait()
                    // Read before the later changes arrived.
                    return StoredWorkouts(workouts: [self.first, self.second])
                }
                return StoredWorkouts(workouts: [self.renamedFirst, self.second])
            }
        }

        await store.send(.internal(.workoutsChangedRemotely)) { $0.isReloading = true }
        await store.send(.internal(.workoutsChangedRemotely)) { $0.needsReload = true }
        await store.send(.internal(.workoutsChangedRemotely))
        gate.open()
        await store.receive(\.internal.workoutsLoaded) { $0.needsReload = false }
        await store.receive(\.internal.workoutsLoaded) {
            $0.isReloading = false
            $0.workouts = .loaded([self.renamedFirst, self.second])
        }

        #expect(fetches.value == 2)
    }

    @Test(arguments: [AppFeature.Content.idle, .failed])
    func test_workoutsChangedRemotely_nothingShown_readsNothing(content: AppFeature.Content) async {
        var state = AppFeature.State()
        state.workouts = content
        let fetches = LockIsolated(0)
        let store = makeStore(state) {
            $0.workoutStorage.fetchAll = {
                fetches.withValue { $0 += 1 }
                return StoredWorkouts(workouts: [])
            }
        }

        await store.send(.internal(.workoutsChangedRemotely))
        await store.finish()

        #expect(fetches.value == 0)
    }

    @Test
    func test_workoutsLoaded_readOnlyScreenOfAChangedWorkout_showsTheStoredVersion() async throws {
        var state = loaded([first, second])
        state.isReloading = true
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: first)))
        let id = try #require(state.path.ids.first)
        let store = makeStore(state)

        await store.send(.internal(.workoutsLoaded(StoredWorkouts(workouts: [renamedFirst, second])))) {
            $0.isReloading = false
            $0.workouts = .loaded([self.renamedFirst, self.second])
            $0.path[id: id] = .editor(WorkoutEditorFeature.State(viewing: self.renamedFirst))
        }
    }

    @Test
    func test_workoutsLoaded_readOnlyScreenOfAGoneWorkout_closesIt() async throws {
        var state = loaded([first, second])
        state.isReloading = true
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: first)))
        let id = try #require(state.path.ids.first)
        let store = makeStore(state)

        await store.send(.internal(.workoutsLoaded(StoredWorkouts(workouts: [second])))) {
            $0.isReloading = false
            $0.workouts = .loaded([self.second])
        }
        await store.receive(.path(.element(id: id, action: .editor(.view(.backButtonTapped)))))
        await store.receive(\.path.popFrom) { $0.path = StackState() }
    }

    @Test(arguments: ["new", "editing", "alert", "startIntent"])
    func test_workoutsLoaded_draftAlertOrStart_leavesTheOpenScreenAlone(_ situation: String) async throws {
        var state = loaded([first, second])
        state.isReloading = true
        var editor = WorkoutEditorFeature.State(viewing: first)
        switch situation {
            case "new":
                // Not in the reloaded list, so a refresh would close it.
                editor = WorkoutEditorFeature.State(
                    newWorkoutID: UUID(fixture: 50),
                    warmUpStageID: UUID(fixture: 51),
                    trainingStageID: UUID(fixture: 52),
                    coolDownStageID: UUID(fixture: 53)
                )
            case "editing":
                editor.phase = .editing
                editor.draft.name = "Draft"
            case "alert":
                editor.destination = .saveFailedAlert(.saveFailed)
            default:
                break
        }
        state.path.append(.editor(editor))
        let id = try #require(state.path.ids.first)
        if situation == "startIntent" {
            // The editor's own Start flag stays down, so only the container's intent keeps the screen.
            state.startIntent = AppFeature.StartIntent(generation: 1, editorID: id, workout: first)
        }
        let store = makeStore(state)

        await store.send(.internal(.workoutsLoaded(StoredWorkouts(workouts: [renamedFirst, second])))) {
            $0.isReloading = false
            $0.workouts = .loaded([self.renamedFirst, self.second])
        }
        await store.finish()
    }

    @Test
    func test_saveAsNew_duringTheReloadItsDeletionStarted_readsAgainAfterTheReload() async throws {
        let gate = Gate()
        let fetches = LockIsolated(0)
        let saves = LockIsolated(0)
        let copy = Workout(id: UUID(0), name: "Renamed", training: first.training)
        var state = loaded([first, second])
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: first)))
        let id = try #require(state.path.ids.first)
        let store = makeStore(state) {
            $0.workoutStorage.save = { _ in
                let call = saves.withValue { count in
                    count += 1
                    return count
                }
                return call == 1 ? .deletedElsewhere : .saved
            }
            $0.workoutStorage.fetchAll = {
                let call = fetches.withValue { count in
                    count += 1
                    return count
                }
                if call == 1 {
                    await gate.wait()
                    // Read before the copy was saved.
                    return StoredWorkouts(workouts: [self.second])
                }
                return StoredWorkouts(workouts: [self.second, copy])
            }
        }
        await store.send(.path(.element(id: id, action: .editor(.view(.editButtonTapped))))) {
            $0.path[id: id, case: \.editor]?.phase = .editing
        }
        await store.send(.path(.element(id: id, action: .editor(.view(.nameChanged("Renamed")))))) {
            $0.path[id: id, case: \.editor]?.draft.name = "Renamed"
        }

        await store.send(.path(.element(id: id, action: .editor(.view(.saveButtonTapped))))) {
            $0.path[id: id, case: \.editor]?.isSaving = true
        }
        await store.receive(.path(.element(id: id, action: .editor(.internal(.saveFoundDeletedElsewhere))))) {
            $0.path[id: id, case: \.editor]?.isSaving = false
            $0.path[id: id, case: \.editor]?.destination = .deletedElsewhereAlert(.deletedElsewhere)
        }
        await store.receive(.path(.element(id: id, action: .editor(.delegate(.deletedElsewhere))))) {
            $0.isReloading = true
        }
        await store.send(.path(.element(id: id, action: .editor(.destination(.presented(.deletedElsewhereAlert(.saveAsNew))))))) {
            $0.path[id: id, case: \.editor]?.destination = nil
            $0.path[id: id, case: \.editor]?.draft = copy
            $0.path[id: id, case: \.editor]?.isSaving = true
        }
        await store.receive(.path(.element(id: id, action: .editor(.internal(.saveSucceeded(copy)))))) {
            $0.path[id: id] = .editor(WorkoutEditorFeature.State(viewing: copy))
        }
        await store.receive(.path(.element(id: id, action: .editor(.delegate(.saved(copy)))))) {
            $0.workouts = .loaded([self.first, self.second, copy])
            $0.needsReload = true
        }

        gate.open()
        await store.receive(\.internal.workoutsLoaded) { $0.needsReload = false }
        await store.receive(\.internal.workoutsLoaded) {
            $0.isReloading = false
            $0.workouts = .loaded([self.second, copy])
        }

        #expect(fetches.value == 2)
        #expect(saves.value == 2)
    }
}
