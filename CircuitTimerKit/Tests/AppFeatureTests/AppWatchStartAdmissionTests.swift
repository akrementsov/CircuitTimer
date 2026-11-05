@testable import AppFeature
@testable import WorkoutEditorFeature

import BackgroundNotifications
import ComposableArchitecture
import Foundation
import Testing
import WatchLink
import WorkoutDomain
import WorkoutStorage
import WorkoutTimerFeature

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppWatchStartAdmissionTests {
    private let workout = makeWorkout(1)

    private var request: WatchStartRequest {
        WatchStartRequest(id: 7, workoutID: workout.id, scheduleFingerprint: WorkoutSchedule(workout: workout).fingerprint)
    }

    private func ready() -> AppFeature.State {
        var state = loaded([workout])
        state.hasScenePhase = true
        state.runRestore = .resolved
        return state
    }

    private func intent(_ clock: TestClock<Duration>, generation: Int = 1) -> AppFeature.StartIntent {
        AppFeature.StartIntent(
            generation: generation,
            origin: .watch(requestID: 7),
            workout: workout,
            stage: .admitting,
            acceptedAt: MonotonicInstant(now: clock)
        )
    }

    enum Rejection: CaseIterable, Sendable {
        case unobservedScene, background, reload, draft, restoring, listUnavailable, gone, notPlayable, changed
    }

    @Test(arguments: Rejection.allCases)
    func test_request_notAdmissible_answersWithoutStartingPermissions(reason: Rejection) async {
        var state = ready()
        let expected: WatchStartResult
        switch reason {
            case .unobservedScene:
                state.hasScenePhase = false
                expected = .openPhoneApp
            case .background:
                state.isSceneActive = false
                expected = .openPhoneApp
            case .reload:
                state.isReloading = true
                expected = .busy
            case .draft:
                state.path.append(.editor(WorkoutEditorFeature.State(viewing: workout)))
                if let id = state.path.ids.last { state.path[id: id, case: \.editor]?.phase = .editing }
                expected = .busy
            case .restoring:
                state.runRestore = .reading
                expected = .busy
            case .listUnavailable:
                state.workouts = .failed
                expected = .listUnavailable
            case .gone:
                state.workouts = .loaded([])
                expected = .gone
            case .notPlayable:
                state.workouts = .loaded([Workout(id: workout.id, name: workout.name)])
                expected = .notPlayable
            case .changed:
                var changed = workout
                changed.training[0].duration = .seconds(20)
                state.workouts = .loaded([changed])
                expected = .changed
        }
        let answers = LockIsolated<[WatchStartResult]>([])
        let store = makeStore(state) {
            $0.watchCompanion.startHandled = { id, result in
                #expect(id == 7)
                answers.withValue { $0.append(result) }
                return true
            }
        }

        await store.send(.internal(.watchStartRequested(request)))
        await store.finish()

        #expect(answers.value == [expected])
        #expect(store.state.startIntent == nil)
        #expect(store.state.destination == nil)
    }

    @Test(arguments: [true, false])
    func test_request_waitsForAdmissionBeforeRunningTheSharedStart(admitted: Bool) async {
        let clock = TestClock<Duration>()
        let held = Gate()
        let answers = LockIsolated<[WatchStartResult]>([])
        let store = makeStore(ready()) {
            $0.continuousClock = clock
            $0.timerSession.end = { _ in }
            $0.watchCompanion.startHandled = { _, result in
                answers.withValue { $0.append(result) }
                await held.wait()
                return admitted
            }
        }
        await store.send(.internal(.watchStartRequested(request))) {
            $0.startGeneration = 1
            $0.startIntent = self.intent(clock)
        }
        #expect(store.state.destination == nil)
        #expect(store.state.startIntent?.stage == .admitting)
        held.open()
        await store.receive(.internal(.watchStartAdmitted(generation: 1, admitted))) {
            $0.startIntent = nil
            if admitted {
                $0.destination = .timer(self.timer())
            } else {
                $0.startGeneration = 2
            }
        }
        #expect(answers.value == [.accepted(asksOnPhone: false)])
        if admitted { await store.send(.destination(.dismiss)) { $0.destination = nil } }
        await store.finish()
    }

    @Test
    func test_request_admissionOutlivesDeadline_lateTrueDoesNotOpenTimer() async {
        let clock = TestClock<Duration>()
        let held = Gate()
        let store = makeStore(ready()) {
            $0.continuousClock = clock
            $0.watchCompanion.startHandled = { _, _ in await held.wait(); return true }
        }
        await store.send(.internal(.watchStartRequested(request))) {
            $0.startGeneration = 1
            $0.startIntent = self.intent(clock)
        }
        await clock.advance(by: .seconds(30))
        await store.receive(.internal(.watchStartExpired(generation: 1))) {
            $0.startIntent = nil
            $0.startGeneration = 2
        }
        held.open()
        await store.receive(.internal(.watchStartAdmitted(generation: 1, true)))
        #expect(store.state.destination == nil)
        await store.finish()
    }

    @Test
    func test_rootTask_subscribesOnceAndRoutesTheWatchRequest() async {
        let clock = TestClock<Duration>()
        let requests = AsyncStream<WatchStartRequest>.makeStream()
        let subscriptions = LockIsolated(0)
        let store = makeStore(AppFeature.State()) {
            $0.continuousClock = clock
            $0.timerSession.end = { _ in }
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: [workout]) }
            $0.watchCompanion.startRequests = {
                subscriptions.withValue { $0 += 1 }
                return requests.stream
            }
            $0.watchCompanion.startHandled = { _, _ in true }
        }
        await store.send(.view(.task)) {
            $0.workouts = .loading
            $0.runRestore = .reading
        }
        await store.receive(.internal(.runRecordLoaded(nil))) { $0.runRestore = .resolved }
        await store.receive(\.internal.workoutsLoaded) { $0.workouts = .loaded([self.workout]) }
        await store.send(.view(.scenePhaseChanged(.active))) { $0.hasScenePhase = true }
        await store.send(.view(.task))
        requests.continuation.yield(request)
        await store.receive(.internal(.watchStartRequested(request))) {
            $0.startGeneration = 1
            $0.startIntent = self.intent(clock)
        }
        await store.receive(.internal(.watchStartAdmitted(generation: 1, true))) {
            $0.startIntent = nil
            $0.destination = .timer(self.timer())
        }
        requests.continuation.finish()
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
        #expect(subscriptions.value == 1)
    }

    @Test(arguments: [true, false])
    func test_request_takesOverStalledHealth_skipsEvenTheHealthRead(fromWatch: Bool) async throws {
        let clock = TestClock<Duration>()
        var state = ready()
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: workout)))
        let id = try #require(state.path.ids.last)
        var old = intent(clock)
        if !fromWatch {
            old = AppFeature.StartIntent(generation: 1, origin: .editor(id), workout: workout)
        }
        old.stage = .health
        old.hasStalled = true
        state.startIntent = old
        state.startGeneration = 1
        let store = makeStore(state, healthAccess: nil) {
            $0.continuousClock = clock
            $0.timerSession.end = { _ in }
            $0.watchCompanion.startHandled = { _, result in
                #expect(result == .accepted(asksOnPhone: false))
                return true
            }
            $0.workoutHealth.access = { Issue.record("A stalled Health takeover read access again"); return .determined }
        }
        await store.send(.internal(.watchStartRequested(request))) {
            $0.startGeneration = 3
            var next = self.intent(clock, generation: 3)
            next.skipsHealth = true
            $0.startIntent = next
        }
        await store.receive(.internal(.watchStartAdmitted(generation: 3, true))) {
            $0.startIntent = nil
            $0.destination = .timer(self.timer())
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
    }

    @Test
    func test_request_permissionStages_keepOriginalIntentAndDeadline() async {
        let clock = TestClock<Duration>()
        let sheet = Gate()
        let store = makeStore(ready(), notificationsEnabled: true, healthAccess: nil) {
            $0.continuousClock = clock
            $0.watchCompanion.startHandled = { _, result in
                #expect(result == .accepted(asksOnPhone: true))
                return true
            }
            $0.backgroundNotifications.access = { .authorized }
            $0.workoutHealth.access = { .notDetermined }
            $0.workoutHealth.requestAuthorization = { await sheet.wait() }
        }
        await store.send(.internal(.watchStartRequested(request))) {
            $0.startGeneration = 1
            $0.startIntent = self.intent(clock)
        }
        await store.receive(.internal(.watchStartAdmitted(generation: 1, true))) {
            $0.startIntent?.stage = .notifications
        }
        await store.receive(.internal(.notificationAccessQueried(generation: 1, .authorized))) {
            $0.notificationAccess = .authorized
            $0.startIntent?.stage = .health
        }
        await store.receive(.internal(.healthAccessQueried(generation: 1, .notDetermined))) {
            $0.healthAccess = .notDetermined
            $0.isHealthRequestOutstanding = true
        }
        await clock.advance(by: .seconds(10))
        await store.receive(.internal(.healthStalled(generation: 1))) { $0.startIntent?.hasStalled = true }
        await clock.advance(by: .seconds(20))
        await store.receive(.internal(.watchStartExpired(generation: 1))) {
            $0.startIntent = nil
            $0.startGeneration = 2
        }
        sheet.open()
        await store.receive(.internal(.healthPermissionAnswered(generation: 1, succeeded: true))) {
            $0.healthAccess = .determined
            $0.isHealthRequestOutstanding = false
        }
        #expect(store.state.destination == nil)
        await store.finish()
    }

    private func timer() -> WorkoutTimerFeature.State {
        WorkoutTimerFeature.State(
            id: UUID(0),
            workoutID: workout.id,
            title: workout.name,
            workoutName: workout.name,
            schedule: WorkoutSchedule(workout: workout)
        )
    }
}
