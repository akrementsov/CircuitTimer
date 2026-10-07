@testable import AppFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain
import WorkoutStorage

@MainActor
@Suite
struct AppFeatureTests {
    private struct LoadingFailure: Error {}

    @Test
    func test_task_idle_loadsWorkouts() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: [.sample]) }
        }

        await store.send(.view(.task)) {
            $0.workouts = .loading
        }
        await store.receive(\.internal.workoutsLoaded) {
            $0.workouts = .loaded([.sample])
        }
    }

    @Test(arguments: [AppFeature.Content.loading, .loaded([.sample]), .failed])
    func test_task_notIdle_doesNotReload(content: AppFeature.Content) async {
        let fetchCount = LockIsolated(0)
        var state = AppFeature.State()
        state.workouts = content
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.workoutStorage.fetchAll = {
                fetchCount.withValue { $0 += 1 }
                return StoredWorkouts(workouts: [])
            }
        }

        await store.send(.view(.task))

        #expect(fetchCount.value == 0)
    }

    @Test
    func test_retry_afterFailure_reloadsAndCanFailAgain() async {
        let shouldFail = LockIsolated(true)
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.workoutStorage.fetchAll = {
                if shouldFail.value {
                    throw LoadingFailure()
                }
                return StoredWorkouts(workouts: [.sample])
            }
        }

        await store.send(.view(.task)) {
            $0.workouts = .loading
        }
        await store.receive(\.internal.workoutsLoadingFailed) {
            $0.workouts = .failed
        }

        shouldFail.setValue(false)
        await store.send(.view(.retryButtonTapped)) {
            $0.workouts = .loading
        }
        await store.receive(\.internal.workoutsLoaded) {
            $0.workouts = .loaded([.sample])
        }

        shouldFail.setValue(true)
        await store.send(.view(.retryButtonTapped)) {
            $0.workouts = .loading
        }
        await store.receive(\.internal.workoutsLoadingFailed) {
            $0.workouts = .failed
        }
    }

    @Test
    func test_task_cancelledLoad_isNotReportedAsFailure() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.workoutStorage.fetchAll = { throw CancellationError() }
        }

        await store.send(.view(.task)) {
            $0.workouts = .loading
        }
        await store.finish()
    }

    @Test
    func test_retry_duringLoad_cancelsFirstLoadAndKeepsSecondResult() async {
        let callCount = LockIsolated(0)
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.workoutStorage.fetchAll = {
                let call = callCount.withValue { count in
                    count += 1
                    return count
                }
                if call == 1 {
                    try await Task.never()
                }
                return StoredWorkouts(workouts: [.sample])
            }
        }

        await store.send(.view(.task)) {
            $0.workouts = .loading
        }
        await store.send(.view(.retryButtonTapped))
        await store.receive(\.internal.workoutsLoaded) {
            $0.workouts = .loaded([.sample])
        }
        #expect(callCount.value == 2)
    }

    /// A superseded load that ignores cancellation and finishes later, failing or not, must not overwrite the newer result.
    @Test(arguments: [true, false])
    func test_retry_supersededLoadFinishingLate_keepsNewerResult(lateLoadFails: Bool) async {
        let callCount = LockIsolated(0)
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.workoutStorage.fetchAll = {
                let call = callCount.withValue { count in
                    count += 1
                    return count
                }
                if call == 1 {
                    _ = try? await Task.never()
                    if lateLoadFails {
                        throw LoadingFailure()
                    }
                    return StoredWorkouts(workouts: [], hiddenRecordCount: 1)
                }
                return StoredWorkouts(workouts: [.sample])
            }
        }

        await store.send(.view(.task)) {
            $0.workouts = .loading
        }
        await store.send(.view(.retryButtonTapped))
        await store.receive(\.internal.workoutsLoaded) {
            $0.workouts = .loaded([.sample])
        }
        await store.finish()
    }
}
