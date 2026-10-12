@testable import AppFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain
import WorkoutEditorFeature
import WorkoutStorage

/// A reload of a list that is already shown: it starts when a write reports that storage diverged, and the list stays
/// on screen until the new one arrives.
@MainActor
@Suite
struct AppFeatureReloadTests {
    private struct Failure: Error {}

    private let first = makeWorkout(1)
    private let second = makeWorkout(2)
    private let renamed = makeWorkout(2, name: "Reloaded")

    /// The shown list with one write in flight, whose divergence starts the reload.
    private var diverging: AppFeature.State {
        var state = loaded([first, second])
        state.pendingMutations = [.reorder([second.id, first.id])]
        return state
    }

    @Test
    func test_open_duringAReload_opensTheFreshWorkoutOnceItLands() async {
        let gate = Gate()
        let opening = makeStore(diverging) {
            $0.workoutStorage.fetchAll = {
                await gate.wait()
                return StoredWorkouts(workouts: [self.first, self.renamed])
            }
        }
        await opening.send(.internal(.mutationFinished(.storeDiverged))) {
            $0.pendingMutations = []
            $0.isReloading = true
        }
        await opening.send(.view(.workoutTapped(second.id))) { $0.deferredScreen = .open(self.second.id) }
        gate.open()
        await opening.receive(\.internal.workoutsLoaded) {
            $0.isReloading = false
            $0.workouts = .loaded([self.first, self.renamed])
            $0.deferredScreen = nil
            $0.path[id: 0] = .editor(WorkoutEditorFeature.State(viewing: self.renamed))
        }
    }

    @Test
    func test_create_duringAReload_opensOnceItLands() async {
        let creatingGate = Gate()
        let creating = makeStore(diverging) {
            $0.workoutStorage.fetchAll = {
                await creatingGate.wait()
                return StoredWorkouts(workouts: [self.first, self.second])
            }
        }
        await creating.send(.internal(.mutationFinished(.storeDiverged))) {
            $0.pendingMutations = []
            $0.isReloading = true
        }
        await creating.send(.view(.addButtonTapped)) { $0.deferredScreen = .create }
        creatingGate.open()
        await creating.receive(\.internal.workoutsLoaded) {
            $0.isReloading = false
            $0.deferredScreen = nil
            $0.path[id: 0] = .editor(WorkoutEditorFeature.State(newWorkoutID: UUID(0), firstStageID: UUID(1)))
        }
    }

    @Test
    func test_writeDuringAReload_readLandsFirst_isReadAgainAfterTheWrite() async {
        let clock = TestClock()
        let gate = Gate()
        let fetches = LockIsolated(0)
        let store = makeStore(diverging) {
            $0.workoutStorage.fetchAll = {
                fetches.withValue { $0 += 1 }
                if fetches.value == 1 {
                    await gate.wait()
                    // Read before the delete landed.
                    return StoredWorkouts(workouts: [self.first, self.second])
                }
                return StoredWorkouts(workouts: [self.second])
            }
            $0.workoutStorage.delete = { _ in
                try await clock.sleep(for: .seconds(1))
                return .applied
            }
        }
        await store.send(.internal(.mutationFinished(.storeDiverged))) {
            $0.pendingMutations = []
            $0.isReloading = true
        }
        await store.send(.view(.workoutTapped(second.id))) { $0.deferredScreen = .open(self.second.id) }
        await store.send(.view(.deleteButtonTapped(first.id))) {
            $0.workouts = .loaded([self.second])
            $0.pendingMutations = [.delete(self.first.id)]
            $0.needsReload = true
        }

        gate.open()
        await store.receive(\.internal.workoutsLoaded) { $0.isReloading = false }
        await clock.advance(by: .seconds(1))
        await store.receive(\.internal.mutationFinished) {
            $0.pendingMutations = []
            $0.needsReload = false
            $0.isReloading = true
        }
        await store.receive(\.internal.workoutsLoaded) {
            $0.isReloading = false
            $0.deferredScreen = nil
            $0.path[id: 0] = .editor(WorkoutEditorFeature.State(viewing: self.second))
        }

        #expect(fetches.value == 2)
    }

    @Test
    func test_writeDuringAReload_writeLandsFirst_replacesTheReadInFlight() async {
        let clock = TestClock()
        let gate = Gate()
        let fetches = LockIsolated(0)
        let store = makeStore(diverging) {
            $0.workoutStorage.fetchAll = {
                fetches.withValue { $0 += 1 }
                if fetches.value == 1 {
                    // Held until the newer read cancels it.
                    await gate.wait()
                    try Task.checkCancellation()
                    return StoredWorkouts(workouts: [self.first, self.second])
                }
                return StoredWorkouts(workouts: [self.second])
            }
            $0.workoutStorage.delete = { _ in
                try await clock.sleep(for: .seconds(1))
                return .applied
            }
        }
        await store.send(.internal(.mutationFinished(.storeDiverged))) {
            $0.pendingMutations = []
            $0.isReloading = true
        }
        await store.send(.view(.workoutTapped(second.id))) { $0.deferredScreen = .open(self.second.id) }
        await store.send(.view(.deleteButtonTapped(first.id))) {
            $0.workouts = .loaded([self.second])
            $0.pendingMutations = [.delete(self.first.id)]
            $0.needsReload = true
        }

        await clock.advance(by: .seconds(1))
        await store.receive(\.internal.mutationFinished) {
            $0.pendingMutations = []
            $0.needsReload = false
        }
        await store.receive(\.internal.workoutsLoaded) {
            $0.isReloading = false
            $0.deferredScreen = nil
            $0.path[id: 0] = .editor(WorkoutEditorFeature.State(viewing: self.second))
        }
        gate.open()
        await store.finish()

        #expect(fetches.value == 2)
    }

    @Test
    func test_mutationFinished_reloadInFlight_leavesTheScreenToTheReload() async {
        var state = loaded([first, second])
        state.isReloading = true
        state.pendingMutations = [.reorder([second.id, first.id])]
        state.deferredScreen = .open(first.id)
        let store = makeStore(state)

        await store.send(.internal(.mutationFinished(.applied))) { $0.pendingMutations = [] }
        await store.send(.internal(.workoutsLoaded(StoredWorkouts(workouts: [first, second])))) {
            $0.isReloading = false
            $0.deferredScreen = nil
            $0.path.append(.editor(WorkoutEditorFeature.State(viewing: self.first)))
        }
    }

    @Test
    func test_workoutsLoaded_readOvertakenByAWrite_readsAgainInsteadOfApplying() async {
        var state = loaded([first, second])
        state.isReloading = true
        state.needsReload = true
        let store = makeStore(state) {
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: [self.renamed]) }
        }

        await store.send(.internal(.workoutsLoaded(StoredWorkouts(workouts: [first])))) { $0.needsReload = false }
        await store.receive(\.internal.workoutsLoaded) {
            $0.isReloading = false
            $0.workouts = .loaded([self.renamed])
        }
    }

    @Test
    func test_reloadFails_shownList_turnsToTheRetryScreen() async {
        var state = diverging
        state.deferredScreen = .open(first.id)
        let store = makeStore(state) {
            $0.workoutStorage.fetchAll = { throw Failure() }
        }

        await store.send(.internal(.mutationFinished(.storeDiverged))) {
            $0.pendingMutations = []
            $0.isReloading = true
        }
        await store.receive(\.internal.workoutsLoadingFailed) {
            $0.isReloading = false
            $0.workouts = .failed
            $0.deferredScreen = nil
        }
    }

    @Test
    func test_reloadFails_writeQueued_recoversOnceTheQueueDrains() async {
        let clock = TestClock()
        let gate = Gate()
        let fetches = LockIsolated(0)
        let store = makeStore(diverging) {
            $0.workoutStorage.fetchAll = {
                fetches.withValue { $0 += 1 }
                if fetches.value == 1 {
                    await gate.wait()
                    throw Failure()
                }
                return StoredWorkouts(workouts: [self.second])
            }
            $0.workoutStorage.delete = { _ in
                try await clock.sleep(for: .seconds(1))
                return .applied
            }
        }
        await store.send(.internal(.mutationFinished(.storeDiverged))) {
            $0.pendingMutations = []
            $0.isReloading = true
        }
        await store.send(.view(.deleteButtonTapped(first.id))) {
            $0.workouts = .loaded([self.second])
            $0.pendingMutations = [.delete(self.first.id)]
            $0.needsReload = true
        }

        gate.open()
        await store.receive(\.internal.workoutsLoadingFailed) {
            $0.isReloading = false
            $0.workouts = .failed
        }
        await clock.advance(by: .seconds(1))
        await store.receive(\.internal.mutationFinished) {
            $0.pendingMutations = []
            $0.needsReload = false
            $0.workouts = .loading
        }
        await store.receive(\.internal.workoutsLoaded) { $0.workouts = .loaded([self.second]) }
    }

    @Test
    func test_writeFailsDuringAReload_keepsTheListAndReadsAgain() async {
        let clock = TestClock()
        let gate = Gate()
        let fetches = LockIsolated(0)
        let store = makeStore(diverging) {
            $0.workoutStorage.fetchAll = {
                fetches.withValue { $0 += 1 }
                if fetches.value == 1 {
                    await gate.wait()
                    try Task.checkCancellation()
                    return StoredWorkouts(workouts: [self.first, self.second])
                }
                return StoredWorkouts(workouts: [self.first, self.renamed])
            }
            $0.workoutStorage.delete = { _ in
                try await clock.sleep(for: .seconds(1))
                throw Failure()
            }
        }
        await store.send(.internal(.mutationFinished(.storeDiverged))) {
            $0.pendingMutations = []
            $0.isReloading = true
        }
        await store.send(.view(.workoutTapped(second.id))) { $0.deferredScreen = .open(self.second.id) }
        await store.send(.view(.deleteButtonTapped(first.id))) {
            $0.workouts = .loaded([self.second])
            $0.pendingMutations = [.delete(self.first.id)]
            $0.needsReload = true
        }

        await clock.advance(by: .seconds(1))
        await store.receive(\.internal.mutationFailed) {
            $0.pendingMutations = []
            $0.needsReload = false
            $0.deferredScreen = nil
            $0.destination = .alert(.mutationFailed)
        }
        await store.receive(\.internal.workoutsLoaded) {
            $0.isReloading = false
            $0.workouts = .loaded([self.first, self.renamed])
        }
        gate.open()
        await store.finish()

        #expect(fetches.value == 2)
    }
}
