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

    @Test(arguments: ["off", "denied", "authorized"])
    func test_start_permissionAlreadySettled_opensWithoutReadingOrRequestingAccess(mode: String) async throws {
        let defaults = UserDefaults.inMemory
        defaults.set(mode != "off", forKey: "signalBackgroundNotifications")
        let workout = makeWorkout(1)
        let accesses = LockIsolated(0)
        let requests = LockIsolated(0)
        let (store, editorID) = try withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            var state = loaded([workout])
            state.path.append(.editor(WorkoutEditorFeature.State(viewing: workout)))
            let editorID = try #require(state.path.ids.last)
            if mode == "denied" { state.notificationAccess = .init(authorization: .denied, showsAlerts: false, playsSound: false) }
            if mode == "authorized" { state.notificationAccess = .authorized }
            let store = makeStore(state, notificationsEnabled: mode != "off") {
                $0.defaultAppStorage = defaults
                $0.backgroundNotifications.access = { accesses.withValue { $0 += 1 }; return .authorized }
                $0.backgroundNotifications.requestAuthorization = { requests.withValue { $0 += 1 }; return .authorized }
                $0.timerSession.end = { _ in }
            }
            return (store, editorID)
        }
        #expect(store.state.isBackgroundNotificationsOn == (mode != "off"))

        await store.send(.path(.element(id: editorID, action: .editor(.delegate(.startRequested(workout)))))) {
            $0.destination = .timer($0.testTimer(for: workout))
        }
        #expect(store.state.startIntent == nil)
        #expect(store.state.notificationPermissionGeneration == 0)
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
        #expect(accesses.value == 0)
        #expect(requests.value == 0)
    }

    @Test
    func test_start_pendingIntent_ignoresSecondStartWithoutAdvancingGeneration() async throws {
        let workout = makeWorkout(1)
        var state = loaded([workout])
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: workout)))
        let editorID = try #require(state.path.ids.last)
        let gate = Gate()
        let reads = LockIsolated(0)
        let store = makeStore(state, notificationsEnabled: true) {
            $0.backgroundNotifications.access = {
                reads.withValue { $0 += 1 }
                await gate.wait()
                return .authorized
            }
            $0.timerSession.end = { _ in }
        }
        await store.send(.path(.element(id: editorID, action: .editor(.delegate(.startRequested(workout)))))) {
            $0.notificationPermissionGeneration = 1
            $0.startIntent = AppFeature.StartIntent(generation: 1, editorID: editorID, workout: workout)
        }
        await store.send(.path(.element(id: editorID, action: .editor(.delegate(.startRequested(workout))))))
        #expect(store.state.notificationPermissionGeneration == 1)
        #expect(store.state.startIntent?.generation == 1)
        gate.open()
        await store.receive(.internal(.notificationAccessQueried(generation: 1, .authorized))) {
            $0.notificationAccess = .authorized
            $0.startIntent = nil
            $0.destination = .timer($0.testTimer(for: workout))
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
        #expect(reads.value == 1)
    }

    @Test
    func test_start_pendingIntent_changedWorkoutCancelsBeforePermissionAnswer() async throws {
        let workout = makeWorkout(1)
        var changed = workout
        changed.name = "Changed"
        var editor = WorkoutEditorFeature.State(viewing: changed)
        editor.isStarting = true
        var state = loaded([workout])
        state.path.append(.editor(editor))
        let editorID = try #require(state.path.ids.last)
        state.startIntent = AppFeature.StartIntent(generation: 1, editorID: editorID, workout: workout)
        state.notificationPermissionGeneration = 1
        let store = makeStore(state, notificationsEnabled: true)

        await store.send(.internal(.notificationPermissionAnswered(generation: 1, .authorized))) {
            $0.notificationAccess = .authorized
            $0.startIntent = nil
            $0.notificationPermissionGeneration = 2
            $0.path[id: editorID, case: \.editor]?.isStarting = false
        }
        #expect(store.state.destination == nil)
    }

    @Test
    func test_confirmStartIntent_otherDestinationCancelsWithoutReplacingIt() async throws {
        let workout = makeWorkout(1)
        var editor = WorkoutEditorFeature.State(viewing: workout)
        editor.isStarting = true
        var state = loaded([workout])
        state.path.append(.editor(editor))
        let editorID = try #require(state.path.ids.last)
        state.startIntent = AppFeature.StartIntent(generation: 1, editorID: editorID, workout: workout)
        state.notificationPermissionGeneration = 1
        state.destination = .resumeRun(.retryTimer)
        let store = makeStore(state, notificationsEnabled: true)

        await store.send(.internal(.startIntentConfirmed(generation: 1))) {
            $0.startIntent = nil
            $0.notificationPermissionGeneration = 2
            $0.path[id: editorID, case: \.editor]?.isStarting = false
        }
        #expect(store.state.destination?.is(\.resumeRun) == true)
        await store.send(.destination(.dismiss)) {
            $0.destination = nil
            $0.runRestore = .resolved
        }
    }

    @Test(arguments: ["error", "undetermined"])
    func test_requestAuthorization_unsettledResultOpensTimerWithoutCaching(mode: String) async throws {
        struct RequestFailure: Error {}
        let workout = makeWorkout(1)
        var state = loaded([workout])
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: workout)))
        let editorID = try #require(state.path.ids.last)
        let store = makeStore(state, notificationsEnabled: true) {
            $0.backgroundNotifications.access = {
                NotificationAccess(authorization: .notDetermined, showsAlerts: false, playsSound: false)
            }
            $0.backgroundNotifications.requestAuthorization = {
                if mode == "error" { throw RequestFailure() }
                return NotificationAccess(authorization: .notDetermined, showsAlerts: false, playsSound: false)
            }
            $0.timerSession.end = { _ in }
        }
        await store.send(.path(.element(id: editorID, action: .editor(.delegate(.startRequested(workout)))))) {
            $0.notificationPermissionGeneration = 1
            $0.startIntent = AppFeature.StartIntent(generation: 1, editorID: editorID, workout: workout)
        }
        await store.receive(\.internal.notificationAccessQueried) { $0.startIntent?.isAwaitingAuthorization = true }
        await store.receive(.internal(.notificationPermissionAnswered(
            generation: 1,
            mode == "error" ? nil : NotificationAccess(authorization: .notDetermined, showsAlerts: false, playsSound: false)
        ))) {
            $0.startIntent = nil
            $0.destination = .timer($0.testTimer(for: workout))
        }
        #expect(store.state.notificationAccess == nil)
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
    }

    @Test
    func test_requestAuthorization_cancelledEmitsNoAnswer() async throws {
        let workout = makeWorkout(1)
        var state = loaded([workout])
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: workout)))
        let editorID = try #require(state.path.ids.last)
        let store = makeStore(state, notificationsEnabled: true) {
            $0.backgroundNotifications.access = {
                NotificationAccess(authorization: .notDetermined, showsAlerts: false, playsSound: false)
            }
            $0.backgroundNotifications.requestAuthorization = { throw CancellationError() }
            $0.timerSession.end = { _ in }
        }
        await store.send(.path(.element(id: editorID, action: .editor(.delegate(.startRequested(workout)))))) {
            $0.notificationPermissionGeneration = 1
            $0.startIntent = AppFeature.StartIntent(generation: 1, editorID: editorID, workout: workout)
        }
        await store.receive(\.internal.notificationAccessQueried) { $0.startIntent?.isAwaitingAuthorization = true }
        #expect(store.state.notificationAccess == nil)
        await store.send(.internal(.startIntentConfirmed(generation: 1))) {
            $0.startIntent = nil
            $0.destination = .timer($0.testTimer(for: workout))
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
    }

    @Test(arguments: [false, true])
    func test_permissionStalled_waitOrSystemDismissRestartsDeadlineWithoutSecondRequest(systemDismiss: Bool) async throws {
        let workout = makeWorkout(1)
        var editor = WorkoutEditorFeature.State(viewing: workout)
        editor.isStarting = true
        var state = loaded([workout])
        state.path.append(.editor(editor))
        let editorID = try #require(state.path.ids.last)
        state.notificationPermissionGeneration = 1
        state.startIntent = AppFeature.StartIntent(generation: 1, editorID: editorID, workout: workout, isAwaitingAuthorization: true)
        state.destination = .permissionStalled(.permissionStalled)
        let clock = TestClock()
        let requests = LockIsolated(0)
        let store = makeStore(state, notificationsEnabled: true) {
            $0.continuousClock = clock
            $0.backgroundNotifications.requestAuthorization = { requests.withValue { $0 += 1 }; return .authorized }
        }

        if systemDismiss {
            await store.send(.destination(.dismiss)) { $0.destination = nil }
        } else {
            await store.send(.destination(.presented(.permissionStalled(.wait)))) { $0.destination = nil }
        }
        await store.receive(.internal(.notificationPermissionWait))
        await clock.advance(by: .seconds(10))
        await store.receive(.internal(.notificationPermissionStalled(generation: 1))) {
            $0.destination = .permissionStalled(.permissionStalled)
        }
        #expect(store.state.startIntent?.generation == 1)
        #expect(requests.value == 0)
        await store.send(.internal(.startIntentConfirmed(generation: 1))) {
            $0.startIntent = nil
            $0.notificationPermissionGeneration = 2
            $0.path[id: editorID, case: \.editor]?.isStarting = false
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.receive(.internal(.notificationPermissionWait))
        await store.finish()
    }

    @Test
    func test_permissionAnswered_whileStallAlertShownDismissesThenStarts() async throws {
        let workout = makeWorkout(1)
        var state = loaded([workout])
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: workout)))
        let editorID = try #require(state.path.ids.last)
        state.notificationPermissionGeneration = 1
        state.startIntent = AppFeature.StartIntent(generation: 1, editorID: editorID, workout: workout, isAwaitingAuthorization: true)
        state.destination = .permissionStalled(.permissionStalled)
        let store = makeStore(state, notificationsEnabled: true) { $0.timerSession.end = { _ in } }
        await store.send(.internal(.notificationPermissionAnswered(generation: 1, .authorized))) {
            $0.notificationAccess = .authorized
            $0.destination = nil
        }
        #expect(store.state.startIntent?.generation == 1)
        await store.receive(.internal(.startIntentConfirmed(generation: 1))) {
            $0.startIntent = nil
            $0.destination = .timer($0.testTimer(for: workout))
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
    }

    @Test
    func test_permissionStall_sceneLeavesAndReturns_restartsOnlyWhenActive() async throws {
        let workout = makeWorkout(1)
        var state = loaded([workout])
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: workout)))
        let editorID = try #require(state.path.ids.last)
        state.notificationPermissionGeneration = 1
        state.startIntent = AppFeature.StartIntent(generation: 1, editorID: editorID, workout: workout, isAwaitingAuthorization: true)
        let clock = TestClock()
        let store = makeStore(state, notificationsEnabled: true) { $0.continuousClock = clock }
        await store.send(.internal(.notificationPermissionWait))
        await store.send(.view(.scenePhaseChanged(.inactive))) { $0.isSceneActive = false }
        await clock.advance(by: .seconds(10))
        await store.send(.view(.scenePhaseChanged(.background)))
        await clock.advance(by: .seconds(10))
        #expect(store.state.destination == nil)
        await store.send(.view(.scenePhaseChanged(.active))) { $0.isSceneActive = true }
        await clock.advance(by: .seconds(10))
        await store.receive(.internal(.notificationPermissionStalled(generation: 1))) {
            $0.destination = .permissionStalled(.permissionStalled)
        }
        await store.send(.internal(.startIntentConfirmed(generation: 1))) {
            $0.startIntent = nil
            $0.notificationPermissionGeneration = 2
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.receive(.internal(.notificationPermissionWait))
        await store.finish()
    }

    @Test
    func test_permissionStall_otherGenerationOrAlertOrInactiveSceneDoesNotPresent() async throws {
        let workout = makeWorkout(1)
        var state = loaded([workout])
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: workout)))
        let editorID = try #require(state.path.ids.last)
        state.notificationPermissionGeneration = 2
        state.startIntent = AppFeature.StartIntent(generation: 2, editorID: editorID, workout: workout, isAwaitingAuthorization: true)
        state.destination = .permissionStalled(.permissionStalled)
        let clock = TestClock()
        let store = makeStore(state, notificationsEnabled: true) {
            $0.continuousClock = clock
            $0.timerSession.end = { _ in }
        }
        await store.send(.internal(.notificationPermissionWait))
        await clock.advance(by: .seconds(10))
        await store.send(.internal(.notificationPermissionStalled(generation: 2)))
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.receive(.internal(.notificationPermissionWait))
        await store.send(.internal(.notificationPermissionStalled(generation: 1)))
        await store.send(.view(.scenePhaseChanged(.inactive))) { $0.isSceneActive = false }
        await store.send(.internal(.notificationPermissionWait))
        await clock.advance(by: .seconds(10))
        #expect(store.state.destination == nil)
        await store.send(.internal(.startIntentConfirmed(generation: 2))) {
            $0.startIntent = nil
            $0.destination = .timer($0.testTimer(for: workout))
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
    }

    @Test(arguments: [false, true])
    func test_permissionStall_cancelOrConfirmStopsDeadline(confirm: Bool) async throws {
        let workout = makeWorkout(1)
        var editor = WorkoutEditorFeature.State(viewing: workout)
        editor.isStarting = true
        var state = loaded([workout])
        state.path.append(.editor(editor))
        let editorID = try #require(state.path.ids.last)
        state.notificationPermissionGeneration = 1
        state.startIntent = AppFeature.StartIntent(generation: 1, editorID: editorID, workout: workout, isAwaitingAuthorization: true)
        let clock = TestClock()
        let store = makeStore(state, notificationsEnabled: true) {
            $0.continuousClock = clock
            $0.timerSession.end = { _ in }
        }
        await store.send(.internal(.notificationPermissionWait))
        if confirm {
            await store.send(.internal(.startIntentConfirmed(generation: 1))) {
                $0.startIntent = nil
                $0.destination = .timer($0.testTimer(for: workout))
            }
        } else {
            await store.send(.view(.tabSelected(.settings))) {
                $0.selectedTab = .settings
                $0.startIntent = nil
                $0.notificationPermissionGeneration = 2
                $0.path[id: editorID, case: \.editor]?.isStarting = false
            }
        }
        await clock.advance(by: .seconds(10))
        if confirm { await store.send(.destination(.dismiss)) { $0.destination = nil } }
        await store.finish()
        #expect(store.state.destination == nil)
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
