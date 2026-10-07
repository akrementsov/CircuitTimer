@testable import AppFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain
import WorkoutEditorFeature
import WorkoutStorage

@MainActor
@Suite
struct AppFeatureListTests {
    private struct WriteFailure: Error {}

    private let first = makeWorkout(1)
    private let second = makeWorkout(2)

    private func loaded(_ workouts: [Workout]) -> AppFeature.State {
        var state = AppFeature.State()
        state.workouts = .loaded(IdentifiedArray(uniqueElements: workouts))
        return state
    }

    private func makeStore(
        _ state: AppFeature.State,
        dependencies: (inout DependencyValues) -> Void = { _ in }
    ) -> TestStoreOf<AppFeature> {
        TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            dependencies(&$0)
        }
    }

    @Test
    func test_load_takesHiddenCountUniquesIDsAndReplacesCountOnReload() async {
        let responses = LockIsolated([
            StoredWorkouts(workouts: [makeWorkout(1), makeWorkout(1, name: "Duplicate"), makeWorkout(2)], hiddenRecordCount: 2),
            StoredWorkouts(workouts: [], hiddenRecordCount: 0),
        ])
        let store = makeStore(AppFeature.State()) {
            $0.workoutStorage.fetchAll = { responses.withValue { $0.removeFirst() } }
        }

        await store.send(.view(.task)) { $0.workouts = .loading }
        await store.receive(\.internal.workoutsLoaded) {
            $0.workouts = .loaded([makeWorkout(1), makeWorkout(2)])
            $0.hiddenRecordCount = 2
        }
        await store.send(.view(.retryButtonTapped)) { $0.workouts = .loading }
        await store.receive(\.internal.workoutsLoaded) {
            $0.workouts = .loaded([])
            $0.hiddenRecordCount = 0
        }
    }

    @Test(arguments: [
        (AppFeature.Content.idle, false, false),
        (.loading, false, false),
        (.failed, false, false),
        (.loaded([]), true, false),
        (.loaded([makeWorkout(1)]), true, true),
    ])
    func test_listFlags_followContent(content: AppFeature.Content, canAdd: Bool, canEdit: Bool) {
        var state = AppFeature.State()
        state.workouts = content

        #expect(state.canAddWorkout == canAdd)
        #expect(state.canEditList == canEdit)
    }

    @Test
    func test_addAndTap_openEditorForNewAndExistingWorkouts() async {
        let store = makeStore(loaded([first]))

        await store.send(.view(.addButtonTapped)) {
            $0.destination = .editor(WorkoutEditorFeature.State(newWorkoutID: UUID(0), firstStageID: UUID(1)))
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.send(.view(.workoutTapped(first.id))) {
            $0.destination = .editor(WorkoutEditorFeature.State(editing: self.first))
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.send(.view(.workoutTapped(UUID(fixture: 99))))
    }

    @Test
    func test_editorSaved_updatesInPlaceAppendsNewAndReloadsWhenNotLoaded() async {
        var renamed = first
        renamed.name = "Renamed"
        var state = loaded([first, second])
        state.destination = .editor(WorkoutEditorFeature.State(editing: first))
        let store = makeStore(state)

        await store.send(.destination(.presented(.editor(.delegate(.saved(renamed)))))) {
            $0.workouts = .loaded([renamed, self.second])
        }
        await store.send(.destination(.presented(.editor(.delegate(.saved(makeWorkout(3))))))) {
            $0.workouts = .loaded([renamed, self.second, makeWorkout(3)])
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }

        var failed = AppFeature.State()
        failed.workouts = .failed
        failed.destination = .editor(WorkoutEditorFeature.State(editing: first))
        let notLoaded = makeStore(failed) {
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: [makeWorkout(3)]) }
        }
        await notLoaded.send(.destination(.presented(.editor(.delegate(.saved(makeWorkout(3))))))) { $0.workouts = .loading }
        await notLoaded.receive(\.internal.workoutsLoaded) { $0.workouts = .loaded([makeWorkout(3)]) }
    }

    @Test
    func test_delete_removesRowAndWritesOnceWithoutReload() async {
        let deleted = LockIsolated<[Workout.ID]>([])
        let store = makeStore(loaded([first, second])) {
            $0.workoutStorage.delete = { id in
                deleted.withValue { $0.append(id) }
                return .applied
            }
        }

        await store.send(.view(.deleteButtonTapped(first.id))) {
            $0.workouts = .loaded([self.second])
            $0.pendingMutations = [.delete(self.first.id)]
        }
        await store.receive(\.internal.mutationFinished) { $0.pendingMutations = [] }
        await store.send(.view(.deleteButtonTapped(UUID(fixture: 99))))

        #expect(deleted.value == [first.id])
        let notLoaded = makeStore(AppFeature.State())
        await notLoaded.send(.view(.deleteButtonTapped(first.id)))
        await notLoaded.send(.view(.duplicateButtonTapped(first.id)))
        await notLoaded.send(.view(.workoutsMoved(IndexSet(integer: 0), 1)))
    }

    @Test
    func test_duplicate_insertsFreshCopyAfterOriginal() async throws {
        let inserted = LockIsolated<[(Workout, Workout.ID)]>([])
        let original = Workout(
            id: UUID(fixture: 1),
            name: "Workout",
            warmUp: [makeStage(10)],
            training: [makeStage(20, .rest)],
            trainingRounds: 4,
            pauseAfterWarmUp: true
        )
        let store = makeStore(loaded([original, second])) {
            $0.workoutStorage.insert = { workout, anchor in
                inserted.withValue { $0.append((workout, anchor)) }
                return .applied
            }
        }
        store.exhaustivity = .off

        await store.send(.view(.duplicateButtonTapped(original.id)))
        await store.receive(\.internal.mutationFinished)

        guard case let .loaded(workouts) = store.state.workouts else {
            Issue.record("The list is not loaded")
            return
        }
        let copy = workouts[1]
        #expect(workouts.ids.elements == [original.id, UUID(0), second.id])
        #expect(copy.warmUp.map(\.id) == [UUID(1)])
        #expect(copy.training.map(\.id) == [UUID(2)])
        #expect(copy.warmUp.map(\.duration) == original.warmUp.map(\.duration))
        #expect(copy.training.map(\.intensity) == [.rest])
        #expect(copy.trainingRounds == 4)
        #expect(copy.pauseAfterWarmUp)
        #expect(copy.name.contains(original.name))
        #expect(copy.name != original.name)
        #expect(!copy.name.contains("workouts.duplicate"))
        let call = try #require(inserted.value.first)
        #expect(call.0 == copy)
        #expect(call.1 == original.id)
    }

    @Test
    func test_move_reordersRowsAndWritesNewOrder() async {
        let reordered = LockIsolated<[Workout.ID]>([])
        let store = makeStore(loaded([first, second])) {
            $0.workoutStorage.reorder = { ids in
                reordered.setValue(ids)
                return .applied
            }
        }

        await store.send(.view(.workoutsMoved(IndexSet(integer: 1), 0))) {
            $0.workouts = .loaded([self.second, self.first])
            $0.pendingMutations = [.reorder([self.second.id, self.first.id])]
        }
        await store.receive(\.internal.mutationFinished) { $0.pendingMutations = [] }

        #expect(reordered.value == [second.id, first.id])
    }

    @Test
    func test_queue_writesOneAtATimeInUserOrder() async {
        let clock = TestClock()
        let calls = LockIsolated<[String]>([])
        let third = makeWorkout(3)
        let store = makeStore(loaded([first, second, third])) {
            $0.workoutStorage.delete = { _ in
                calls.withValue { $0.append("delete") }
                try await clock.sleep(for: .seconds(1))
                return .applied
            }
            $0.workoutStorage.insert = { _, _ in
                calls.withValue { $0.append("insert") }
                try await clock.sleep(for: .seconds(1))
                return .applied
            }
            $0.workoutStorage.reorder = { _ in
                calls.withValue { $0.append("reorder") }
                try await clock.sleep(for: .seconds(1))
                return .applied
            }
        }
        store.exhaustivity = .off

        await store.send(.view(.deleteButtonTapped(first.id)))
        await store.send(.view(.duplicateButtonTapped(second.id)))
        await store.send(.view(.workoutsMoved(IndexSet(integer: 2), 0)))
        #expect(store.state.pendingMutations.count == 3)
        #expect(calls.value == ["delete"])

        await clock.advance(by: .seconds(1))
        await store.receive(\.internal.mutationFinished)
        #expect(calls.value == ["delete", "insert"])
        await clock.advance(by: .seconds(1))
        await store.receive(\.internal.mutationFinished)
        await clock.advance(by: .seconds(1))
        await store.receive(\.internal.mutationFinished)

        #expect(calls.value == ["delete", "insert", "reorder"])
        #expect(store.state.pendingMutations.isEmpty)
        guard case let .loaded(workouts) = store.state.workouts else {
            Issue.record("The list is not loaded")
            return
        }
        #expect(workouts.ids.elements == [third.id, second.id, UUID(0)])
    }

    @Test
    func test_divergence_reloadsOnceTheQueueDrains() async {
        let clock = TestClock()
        let store = makeStore(loaded([first, second])) {
            $0.workoutStorage.delete = { _ in
                try await clock.sleep(for: .seconds(1))
                return .storeDiverged
            }
            $0.workoutStorage.reorder = { _ in
                try await clock.sleep(for: .seconds(1))
                return .applied
            }
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: [makeWorkout(2), makeWorkout(1, name: "Copy")]) }
        }

        await store.send(.view(.deleteButtonTapped(first.id))) {
            $0.workouts = .loaded([self.second])
            $0.pendingMutations = [.delete(self.first.id)]
        }
        await store.send(.view(.workoutsMoved(IndexSet(integer: 0), 1))) {
            $0.pendingMutations = [.delete(self.first.id), .reorder([self.second.id])]
        }
        await clock.advance(by: .seconds(1))
        await store.receive(\.internal.mutationFinished) {
            $0.pendingMutations = [.reorder([self.second.id])]
            $0.needsReload = true
        }
        await clock.advance(by: .seconds(1))
        await store.receive(\.internal.mutationFinished) {
            $0.pendingMutations = []
            $0.needsReload = false
            $0.workouts = .loading
        }
        await store.receive(\.internal.workoutsLoaded) {
            $0.workouts = .loaded([makeWorkout(2), makeWorkout(1, name: "Copy")])
        }
    }

    @Test
    func test_writeFailure_dropsQueueShowsAlertAndReloads() async {
        let clock = TestClock()
        let reorderCalls = LockIsolated(0)
        var state = loaded([first, second])
        state.deferredEditor = .create
        let store = makeStore(state) {
            $0.workoutStorage.delete = { _ in
                try await clock.sleep(for: .seconds(1))
                throw WriteFailure()
            }
            $0.workoutStorage.reorder = { _ in
                reorderCalls.withValue { $0 += 1 }
                return .applied
            }
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: [makeWorkout(1), makeWorkout(2)]) }
        }

        await store.send(.view(.deleteButtonTapped(first.id))) {
            $0.workouts = .loaded([self.second])
            $0.pendingMutations = [.delete(self.first.id)]
        }
        await store.send(.view(.workoutsMoved(IndexSet(integer: 0), 1))) {
            $0.pendingMutations = [.delete(self.first.id), .reorder([self.second.id])]
        }
        await clock.advance(by: .seconds(1))
        await store.receive(\.internal.mutationFailed) {
            $0.pendingMutations = []
            $0.deferredEditor = nil
            $0.destination = .alert(.mutationFailed)
            $0.workouts = .loading
        }
        await store.receive(\.internal.workoutsLoaded) {
            $0.workouts = .loaded([makeWorkout(1), makeWorkout(2)])
        }

        #expect(reorderCalls.value == 0)
    }

    @Test(arguments: ["delete", "insert", "reorder"])
    func test_writeFailure_anyKind_reportsFailure(kind: String) async {
        let store = makeStore(loaded([first, second])) {
            $0.workoutStorage.delete = { _ in throw WriteFailure() }
            $0.workoutStorage.insert = { _, _ in throw WriteFailure() }
            $0.workoutStorage.reorder = { _ in throw WriteFailure() }
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: []) }
        }
        store.exhaustivity = .off

        switch kind {
            case "delete": await store.send(.view(.deleteButtonTapped(first.id)))
            case "insert": await store.send(.view(.duplicateButtonTapped(first.id)))
            default: await store.send(.view(.workoutsMoved(IndexSet(integer: 1), 0)))
        }

        await store.receive(\.internal.mutationFailed)
        #expect(store.state.destination == .alert(.mutationFailed))
    }

    @Test
    func test_writeCancelled_sendsNothingAndKeepsQueueHead() async {
        let store = makeStore(loaded([first, second])) {
            $0.workoutStorage.delete = { _ in throw CancellationError() }
        }

        await store.send(.view(.deleteButtonTapped(first.id))) {
            $0.workouts = .loaded([self.second])
            $0.pendingMutations = [.delete(self.first.id)]
        }
        await store.finish()
    }

    @Test
    func test_editorRequestWhileBusy_isDeferredAndLastRequestWins() async {
        var state = loaded([first, second])
        state.pendingMutations = [.delete(UUID(fixture: 99))]
        let store = makeStore(state)

        await store.send(.view(.addButtonTapped)) { $0.deferredEditor = .create }
        await store.send(.view(.workoutTapped(second.id))) { $0.deferredEditor = .edit(self.second.id) }

        var loading = AppFeature.State()
        loading.workouts = .loading
        let loadingStore = makeStore(loading)
        await loadingStore.send(.view(.addButtonTapped)) { $0.deferredEditor = .create }
    }

    @Test
    func test_deferredEditor_opensWhenQueueDrainsWithCurrentData() async {
        var state = loaded([first, second])
        state.pendingMutations = [.reorder([second.id, first.id])]
        state.deferredEditor = .create
        let store = makeStore(state) {
            $0.workoutStorage.reorder = { _ in .applied }
        }

        await store.send(.internal(.mutationFinished(.applied))) {
            $0.pendingMutations = []
            $0.deferredEditor = nil
            $0.destination = .editor(WorkoutEditorFeature.State(newWorkoutID: UUID(0), firstStageID: UUID(1)))
        }
    }

    @Test
    func test_deferredEditor_afterDivergenceOpensOnlyOnceReloaded() async {
        let renamed = makeWorkout(2, name: "Reloaded")
        var state = loaded([first, second])
        state.pendingMutations = [.reorder([second.id, first.id])]
        state.deferredEditor = .edit(second.id)
        let store = makeStore(state) {
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: [makeWorkout(1), renamed]) }
        }

        await store.send(.internal(.mutationFinished(.storeDiverged))) {
            $0.pendingMutations = []
            $0.workouts = .loading
        }
        await store.receive(\.internal.workoutsLoaded) {
            $0.workouts = .loaded([makeWorkout(1), renamed])
            $0.deferredEditor = nil
            $0.destination = .editor(WorkoutEditorFeature.State(editing: renamed))
        }
    }

    @Test
    func test_deferredEdit_isDroppedForDeletedOrMissingWorkoutAndOnLoadFailure() async {
        var state = loaded([first, second])
        state.pendingMutations = [.reorder([UUID(fixture: 99)])]
        state.deferredEditor = .edit(first.id)
        let store = makeStore(state) {
            $0.workoutStorage.delete = { _ in .applied }
        }
        await store.send(.view(.deleteButtonTapped(second.id))) {
            $0.workouts = .loaded([self.first])
            $0.pendingMutations.append(.delete(self.second.id))
        }
        #expect(store.state.deferredEditor == .edit(first.id))
        await store.send(.view(.deleteButtonTapped(first.id))) {
            $0.workouts = .loaded([])
            $0.pendingMutations.append(.delete(self.first.id))
            $0.deferredEditor = nil
        }

        var missing = loaded([second])
        missing.deferredEditor = .edit(first.id)
        let missingStore = makeStore(missing)
        await missingStore.send(.internal(.workoutsLoaded(StoredWorkouts(workouts: [second])))) { $0.deferredEditor = nil }

        var failing = AppFeature.State()
        failing.workouts = .loading
        failing.deferredEditor = .create
        let failingStore = makeStore(failing)
        await failingStore.send(.internal(.workoutsLoadingFailed)) {
            $0.workouts = .failed
            $0.deferredEditor = nil
        }
    }

    @Test
    func test_deferredEditor_isDroppedWhenSomethingIsAlreadyPresented() async {
        var state = loaded([first])
        state.pendingMutations = [.delete(UUID(fixture: 99))]
        state.deferredEditor = .create
        state.destination = .alert(.mutationFailed)
        let store = makeStore(state)

        await store.send(.internal(.mutationFinished(.applied))) {
            $0.pendingMutations = []
            $0.deferredEditor = nil
        }
    }
}

private func makeStage(_ number: Int, _ intensity: Stage.Intensity = .work) -> Stage {
    Stage(id: UUID(fixture: number), name: "Stage \(number)", duration: .seconds(10), intensity: intensity)
}

private func makeWorkout(_ number: Int, name: String? = nil) -> Workout {
    Workout(id: UUID(fixture: number), name: name ?? "Workout \(number)", training: [makeStage(number * 100)])
}

private extension UUID {
    init(fixture number: Int) {
        let high = UInt8(truncatingIfNeeded: number >> 8)
        let low = UInt8(truncatingIfNeeded: number)
        self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, high, low))
    }
}
