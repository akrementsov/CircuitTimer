@testable import AppFeature
@testable import WorkoutEditorFeature

import BackgroundNotifications
import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain
import WorkoutTimerFeature

@MainActor
struct AppNotificationPermissionTests {
    @Test
    func test_start_unknownPermission_waitsForSystemAnswerBeforeCreatingTimer() async throws {
        let workout = makeWorkout(1)
        var state = loaded([workout])
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: workout)))
        let editorID = try #require(state.path.ids.last)
        let prompt = AsyncStream<NotificationAccess>.makeStream()
        let store = makeStore(state, notificationsEnabled: true) {
            $0.timerSession.end = { _ in }
            $0.backgroundNotifications.access = {
                NotificationAccess(authorization: .notDetermined, showsAlerts: false, playsSound: false)
            }
            $0.backgroundNotifications.requestAuthorization = {
                for await answer in prompt.stream { return answer }
                throw CancellationError()
            }
        }

        await store.send(.path(.element(id: editorID, action: .editor(.delegate(.startRequested(workout)))))) {
            $0.notificationPermissionGeneration = 1
            $0.startIntent = AppFeature.StartIntent(generation: 1, editorID: editorID, workout: workout)
        }
        await store.receive(\.internal.notificationAccessQueried) {
            $0.startIntent?.isAwaitingAuthorization = true
        }
        #expect(store.state.destination == nil)
        prompt.continuation.yield(NotificationAccess(authorization: .denied, showsAlerts: false, playsSound: false))
        prompt.continuation.finish()
        await store.receive(\.internal.notificationPermissionAnswered) {
            $0.notificationAccess = NotificationAccess(authorization: .denied, showsAlerts: false, playsSound: false)
            $0.startIntent = nil
            $0.destination = .timer($0.testTimer(for: workout))
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
    }

    @Test
    func test_start_stalledPrompt_explicitChoicePresentsTimerOnlyAfterAlertDismisses() async throws {
        let workout = makeWorkout(1)
        var state = loaded([workout])
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: workout)))
        let editorID = try #require(state.path.ids.last)
        let clock = TestClock()
        let prompt = AsyncStream<NotificationAccess>.makeStream()
        let store = makeStore(state, notificationsEnabled: true) {
            $0.continuousClock = clock
            $0.timerSession.end = { _ in }
            $0.backgroundNotifications.access = {
                NotificationAccess(authorization: .notDetermined, showsAlerts: false, playsSound: false)
            }
            $0.backgroundNotifications.requestAuthorization = {
                for await answer in prompt.stream { return answer }
                throw CancellationError()
            }
        }
        await store.send(.path(.element(id: editorID, action: .editor(.delegate(.startRequested(workout)))))) {
            $0.notificationPermissionGeneration = 1
            $0.startIntent = AppFeature.StartIntent(generation: 1, editorID: editorID, workout: workout)
        }
        await store.receive(\.internal.notificationAccessQueried) {
            $0.startIntent?.isAwaitingAuthorization = true
        }
        await clock.advance(by: .seconds(10))
        await store.receive(\.internal.notificationPermissionStalled) {
            $0.destination = .permissionStalled(.permissionStalled)
        }
        await store.send(.destination(.presented(.permissionStalled(.startNow)))) {
            $0.destination = nil
        }
        await store.receive(\.internal.startIntentConfirmed) {
            $0.startIntent = nil
            $0.destination = .timer($0.testTimer(for: workout))
        }
        prompt.continuation.yield(.authorized)
        prompt.continuation.finish()
        await store.receive(\.internal.notificationPermissionAnswered) {
            $0.notificationAccess = .authorized
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
    }

    @Test
    func test_permissionAnswered_obsoleteGeneration_doesNotOpenTimerOrReplaceCache() async {
        var state = loaded([makeWorkout(1)])
        state.notificationPermissionGeneration = 2
        let denied = NotificationAccess(authorization: .denied, showsAlerts: false, playsSound: false)
        state.notificationAccess = denied
        let store = makeStore(state)
        await store.send(.internal(.notificationPermissionAnswered(generation: 1, .authorized)))
        #expect(store.state.destination == nil)
        #expect(store.state.notificationAccess == denied)
    }

    @Test
    func test_start_accessQueryFailed_waitRetriesAccessBeforeStarting() async throws {
        struct ReadFailure: Error {}
        let workout = makeWorkout(1)
        var state = loaded([workout])
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: workout)))
        let editorID = try #require(state.path.ids.last)
        let reads = LockIsolated(0)
        let store = makeStore(state, notificationsEnabled: true) {
            $0.timerSession.end = { _ in }
            $0.backgroundNotifications.access = {
                let call = reads.withValue { $0 += 1; return $0 }
                if call == 1 { throw ReadFailure() }
                return .authorized
            }
        }
        await store.send(.path(.element(id: editorID, action: .editor(.delegate(.startRequested(workout)))))) {
            $0.notificationPermissionGeneration = 1
            $0.startIntent = AppFeature.StartIntent(generation: 1, editorID: editorID, workout: workout)
        }
        await store.receive(\.internal.notificationAccessQueried) {
            $0.destination = .permissionStalled(.permissionStalled)
        }
        await store.send(.destination(.presented(.permissionStalled(.wait)))) { $0.destination = nil }
        await store.receive(\.internal.notificationPermissionWait)
        await store.receive(\.internal.notificationAccessQueried) {
            $0.notificationAccess = .authorized
            $0.startIntent = nil
            $0.destination = .timer($0.testTimer(for: workout))
        }
        #expect(reads.value == 2)
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
    }

    @Test
    func test_startPending_enteringEditor_cancelsIntentAndRejectsLateAnswer() async throws {
        let workout = makeWorkout(1)
        var editor = WorkoutEditorFeature.State(viewing: workout)
        editor.isStarting = true
        var state = loaded([workout])
        state.path.append(.editor(editor))
        let editorID = try #require(state.path.ids.last)
        state.notificationPermissionGeneration = 1
        state.startIntent = AppFeature.StartIntent(generation: 1, editorID: editorID, workout: workout)
        let store = makeStore(state, notificationsEnabled: true)

        await store.send(.path(.element(id: editorID, action: .editor(.view(.editButtonTapped))))) {
            $0.path[id: editorID, case: \.editor]?.phase = .editing
            $0.path[id: editorID, case: \.editor]?.isStarting = false
            $0.startIntent = nil
            $0.notificationPermissionGeneration = 2
        }
        await store.send(.internal(.notificationPermissionAnswered(generation: 1, .authorized)))
        #expect(store.state.destination == nil)
    }

    @Test
    func test_startPending_leavingTab_releasesEditorStartButton() async throws {
        let workout = makeWorkout(1)
        var editor = WorkoutEditorFeature.State(viewing: workout)
        editor.isStarting = true
        var state = loaded([workout])
        state.path.append(.editor(editor))
        let editorID = try #require(state.path.ids.last)
        state.notificationPermissionGeneration = 1
        state.startIntent = AppFeature.StartIntent(generation: 1, editorID: editorID, workout: workout)
        let store = makeStore(state, notificationsEnabled: true)

        await store.send(.view(.tabSelected(.settings))) {
            $0.selectedTab = .settings
            $0.startIntent = nil
            $0.notificationPermissionGeneration = 2
            $0.path[id: editorID, case: \.editor]?.isStarting = false
        }
        await store.send(.view(.tabSelected(.workouts))) { $0.selectedTab = .workouts }
        #expect(store.state.path[id: editorID, case: \.editor]?.canStart == true)
    }

    @Test
    func test_cleanup_stalled_remainsVisibleWithoutReplacingRestoreAlert() async {
        var state = loaded([makeWorkout(1)])
        state.destination = .alert(.mutationFailed)
        let store = makeStore(state)
        await store.send(.internal(.notificationCleanupFinished(false))) {
            $0.isNotificationCleanupStalled = true
        }
        #expect(store.state.destination?.is(\.alert) == true)
        await store.send(.destination(.dismiss)) { $0.destination = nil }
    }
}

private extension AppFeature.State {
    func testTimer(for workout: Workout) -> WorkoutTimerFeature.State {
        WorkoutTimerFeature.State(
            id: UUID(0),
            workoutID: workout.id,
            title: workout.name,
            schedule: WorkoutSchedule(workout: workout)
        )
    }
}
