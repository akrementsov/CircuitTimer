@testable import AppFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain
import WorkoutEditorFeature
import WorkoutStorage

@MainActor
@Suite
struct AppFeatureMoveTests {
    private let first = makeWorkout(1)
    private let second = makeWorkout(2)

    @Test
    func test_workoutMovedUp_middleWorkout_swapsWithPreviousAndWritesReorder() async {
        let third = makeWorkout(3)
        let reordered = LockIsolated<[[Workout.ID]]>([])
        var state = loaded([first, second, third])
        state.hiddenRecordCount = 2
        let store = makeStore(state) {
            $0.workoutStorage.reorder = { ids in
                reordered.withValue { $0.append(ids) }
                return .applied
            }
        }

        await store.send(.view(.workoutMovedUp(second.id))) {
            $0.workouts = .loaded([self.second, self.first, third])
            $0.pendingMutations = [.reorder([self.second.id, self.first.id, third.id])]
        }
        await store.receive(\.internal.mutationFinished) { $0.pendingMutations = [] }

        #expect(reordered.value == [[second.id, first.id, third.id]])
    }

    @Test
    func test_workoutMovedDown_middleWorkout_swapsWithNextAndWritesReorder() async {
        let third = makeWorkout(3)
        let reordered = LockIsolated<[[Workout.ID]]>([])
        let store = makeStore(loaded([first, second, third])) {
            $0.workoutStorage.reorder = { ids in
                reordered.withValue { $0.append(ids) }
                return .applied
            }
        }

        await store.send(.view(.workoutMovedDown(second.id))) {
            $0.workouts = .loaded([self.first, third, self.second])
            $0.pendingMutations = [.reorder([self.first.id, third.id, self.second.id])]
        }
        await store.receive(\.internal.mutationFinished) { $0.pendingMutations = [] }

        #expect(reordered.value == [[first.id, third.id, second.id]])
    }

    @Test(arguments: [
        ("first up", [1, 2, 3], AppFeature.Action.View.workoutMovedUp(UUID(fixture: 1))),
        ("last down", [1, 2, 3], .workoutMovedDown(UUID(fixture: 3))),
        ("single up", [1], .workoutMovedUp(UUID(fixture: 1))),
        ("single down", [1], .workoutMovedDown(UUID(fixture: 1))),
        ("unknown up", [1, 2], .workoutMovedUp(UUID(fixture: 99))),
        ("unknown down", [1, 2], .workoutMovedDown(UUID(fixture: 99))),
        ("empty up", [], .workoutMovedUp(UUID(fixture: 1))),
        ("empty down", [], .workoutMovedDown(UUID(fixture: 1))),
    ])
    func test_workoutMovedUpAndDown_edgeUnknownSingleOrEmpty_isNoOp(
        _ name: String,
        numbers: [Int],
        action: AppFeature.Action.View
    ) async {
        // Storage stays unimplemented, so any write would fail the test.
        let store = makeStore(loaded(numbers.map { makeWorkout($0) }))

        await store.send(.view(action))
    }

    @Test
    func test_move_twoMovesWhileWriteHeld_thenEditorRequest_drainsQueueThenOpensEditor() async {
        let clock = TestClock()
        let third = makeWorkout(3)
        let payloads = LockIsolated<[[Workout.ID]]>([])
        let store = makeStore(loaded([first, second, third])) {
            $0.workoutStorage.reorder = { ids in
                payloads.withValue { $0.append(ids) }
                try await clock.sleep(for: .seconds(1))
                return .applied
            }
        }

        await store.send(.view(.workoutMovedUp(third.id))) {
            $0.workouts = .loaded([self.first, third, self.second])
            $0.pendingMutations = [.reorder([self.first.id, third.id, self.second.id])]
        }
        await store.send(.view(.workoutMovedUp(third.id))) {
            $0.workouts = .loaded([third, self.first, self.second])
            $0.pendingMutations.append(.reorder([third.id, self.first.id, self.second.id]))
        }
        await store.send(.view(.workoutTapped(third.id))) { $0.deferredEditor = .edit(third.id) }
        #expect(payloads.value == [[first.id, third.id, second.id]])

        await clock.advance(by: .seconds(1))
        await store.receive(\.internal.mutationFinished) {
            $0.pendingMutations = [.reorder([third.id, self.first.id, self.second.id])]
        }
        #expect(payloads.value == [[first.id, third.id, second.id], [third.id, first.id, second.id]])

        await clock.advance(by: .seconds(1))
        await store.receive(\.internal.mutationFinished) {
            $0.pendingMutations = []
            $0.deferredEditor = nil
            $0.destination = .editor(WorkoutEditorFeature.State(editing: third))
        }
    }

    @Test(arguments: [
        ([0], 0),
        ([0], 1),
        ([1], 1),
        ([1], 2),
        ([2], 2),
        ([2], 3),
        ([], 0),
    ])
    func test_workoutsMoved_dropInPlace_writesNothing(source: [Int], destination: Int) async {
        // Storage stays unimplemented, so any write would fail the test.
        let store = makeStore(loaded([first, second, makeWorkout(3)]))

        await store.send(.view(.workoutsMoved(IndexSet(source), destination)))
    }
}
