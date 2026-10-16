@testable import AppFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutStorage

@MainActor
struct AppNotificationCleanupTests {
    private struct CleanupFailure: Error {}

    @Test(arguments: ["false", "error"])
    func test_cleanup_failureShowsNotice(mode: String) async {
        let store = makeStore(loaded([makeWorkout(1)])) {
            $0.backgroundNotifications.removeOrphans = {
                if mode == "error" { throw CleanupFailure() }
                return false
            }
        }
        await store.send(.view(.notificationCleanupRetryTapped))
        await store.receive(.internal(.notificationCleanupFinished(false))) {
            $0.isNotificationCleanupStalled = true
        }
        await store.finish()
    }

    @Test(arguments: ["retry", "active"])
    func test_cleanup_successAfterStallClearsNotice(mode: String) async {
        var state = loaded([makeWorkout(1)])
        state.isNotificationCleanupStalled = true
        let calls = LockIsolated(0)
        let store = makeStore(state) {
            $0.backgroundNotifications.removeOrphans = {
                calls.withValue { $0 += 1 }
                return true
            }
        }
        if mode == "retry" {
            await store.send(.view(.notificationCleanupRetryTapped))
        } else {
            await store.send(.view(.scenePhaseChanged(.active)))
        }
        await store.receive(.internal(.notificationCleanupFinished(true))) {
            $0.isNotificationCleanupStalled = false
        }
        await store.finish()
        #expect(calls.value == 1)
    }

    @Test
    func test_cleanup_cancelledEmitsNoResult() async {
        let store = makeStore(loaded([makeWorkout(1)])) {
            $0.backgroundNotifications.removeOrphans = { throw CancellationError() }
        }
        await store.send(.view(.notificationCleanupRetryTapped))
        await store.finish()
        #expect(store.state.isNotificationCleanupStalled == false)
    }

    @Test
    func test_launch_cleanupRunsOnceBeforeRecordReadDeadline() async {
        let clock = TestClock()
        let cleanups = LockIsolated(0)
        let store = makeStore(AppFeature.State()) {
            $0.continuousClock = clock
            $0.workoutRunRecord.load = { try await Task.never() }
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: []) }
            $0.backgroundNotifications.removeOrphans = {
                cleanups.withValue { $0 += 1 }
                return false
            }
        }

        await store.send(.view(.task)) {
            $0.workouts = .loading
            $0.runRestore = .reading
        }
        await store.receive(.internal(.notificationCleanupFinished(false))) {
            $0.isNotificationCleanupStalled = true
        }
        await store.send(.view(.task))
        #expect(store.state.runRestore == .reading)
        #expect(cleanups.value == 1)
        await clock.advance(by: .seconds(2))
        await store.receive(.internal(.runRecordReadTimedOut)) {
            $0.runRestore = .resolved
            $0.destination = .alert(.runNotRestored)
        }
        await store.receive(\.internal.workoutsLoaded) { $0.workouts = .loaded([]) }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
    }

    @Test
    func test_launch_successfulCleanupEmitsNoAction() async {
        let cleanups = LockIsolated(0)
        let store = makeStore(AppFeature.State()) {
            $0.workoutRunRecord.load = { nil }
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: []) }
            $0.backgroundNotifications.removeOrphans = {
                cleanups.withValue { $0 += 1 }
                return true
            }
        }
        await store.send(.view(.task)) {
            $0.workouts = .loading
            $0.runRestore = .reading
        }
        await store.receive(.internal(.runRecordLoaded(nil))) { $0.runRestore = .resolved }
        await store.receive(\.internal.workoutsLoaded) { $0.workouts = .loaded([]) }
        await store.finish()
        #expect(cleanups.value == 1)
        #expect(store.state.isNotificationCleanupStalled == false)
    }

    @Test
    func test_launch_runsBothOrphanCleanupsOnceInParallelWithoutDelayingTheRestore() async {
        let orphanCleanups = LockIsolated(0)
        let notificationCleanups = LockIsolated(0)
        let started = AsyncStream<Void>.makeStream()
        let releaseNotifications = AsyncStream<Void>.makeStream()
        let releaseActivities = AsyncStream<Void>.makeStream()
        let store = makeStore(AppFeature.State()) {
            $0.workoutRunRecord.load = { nil }
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: []) }
            // Both cleanups stay in flight together: neither waits for the other or for the restore.
            $0.backgroundNotifications.removeOrphans = {
                notificationCleanups.withValue { $0 += 1 }
                started.continuation.yield()
                for await _ in releaseNotifications.stream {}
                return true
            }
            $0.liveActivity.endOrphans = {
                orphanCleanups.withValue { $0 += 1 }
                started.continuation.yield()
                for await _ in releaseActivities.stream {}
            }
        }

        await store.send(.view(.task)) {
            $0.workouts = .loading
            $0.runRestore = .reading
        }
        await store.receive(.internal(.runRecordLoaded(nil))) { $0.runRestore = .resolved }
        await store.receive(\.internal.workoutsLoaded) { $0.workouts = .loaded([]) }
        await store.send(.view(.task))
        var arrivals = started.stream.makeAsyncIterator()
        _ = await arrivals.next()
        _ = await arrivals.next()
        #expect(orphanCleanups.value == 1)
        #expect(notificationCleanups.value == 1)

        releaseNotifications.continuation.finish()
        releaseActivities.continuation.finish()
        await store.finish()
        #expect(orphanCleanups.value == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func test_cleanup_retryCancelsOlderRequestAndReportsOnlyNewestResult() async {
        let calls = LockIsolated(0)
        let started = AsyncStream<Void>.makeStream()
        let store = makeStore(loaded([makeWorkout(1)])) {
            $0.backgroundNotifications.removeOrphans = {
                let call = calls.withValue { $0 += 1; return $0 }
                if call == 1 {
                    started.continuation.yield(())
                    return try await Task.never()
                }
                return false
            }
        }
        await store.send(.view(.notificationCleanupRetryTapped))
        for await _ in started.stream { break }
        await store.send(.view(.notificationCleanupRetryTapped))
        await store.receive(.internal(.notificationCleanupFinished(false))) {
            $0.isNotificationCleanupStalled = true
        }
        await store.finish()
        #expect(calls.value == 2)
    }
}
