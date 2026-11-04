@testable import AppFeature
@testable import WorkoutEditorFeature

import ComposableArchitecture
import Foundation
import Testing
import TestSupport
import WatchLink
import WorkoutDomain
import WorkoutStorage

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppWatchStartDeadlineTests {
    private let fixture = WatchStartFixture()
    enum End: CaseIterable, Sendable { case success, refused, reloadFailure, removed, draft }

    @Test(arguments: End.allCases)
    func test_admittedDeadline_terminalPath_cancelsScheduledExpiry(end: End) async {
        let clock = TestClock<Duration>()
        let admission = Gate()
        let store = makeStore(fixture.ready()) {
            $0.continuousClock = clock
            $0.timerSession.end = { _ in }
            $0.watchCompanion.startHandled = { _, _ in await admission.wait(); return end == .success }
        }
        await store.send(.internal(.watchStartRequested(fixture.request))) {
            $0.startGeneration = 1
            $0.startIntent = self.fixture.pending(clock, stage: .admitting).startIntent
        }
        switch end {
            case .success, .refused: break
            case .reloadFailure:
                await store.send(.internal(.workoutsLoadingFailed)) {
                    $0.workouts = .failed
                    $0.startIntent = nil
                    $0.startGeneration = 2
                }
            case .removed:
                await store.send(.internal(.workoutsLoaded(StoredWorkouts(workouts: [])))) {
                    $0.workouts = .loaded([])
                    $0.startIntent = nil
                    $0.startGeneration = 2
                }
            case .draft:
                await store.send(.view(.addButtonTapped)) {
                    $0.path.append(.editor(WorkoutEditorFeature.State(
                        newWorkoutID: UUID(0), warmUpStageID: UUID(1), trainingStageID: UUID(2), coolDownStageID: UUID(3)
                    )))
                    $0.startIntent = nil
                    $0.startGeneration = 2
                }
        }
        admission.open()
        if end == .success {
            await store.receive(.internal(.watchStartAdmitted(generation: 1, true))) {
                $0.startIntent = nil
                $0.destination = .timer(self.fixture.timer)
            }
        } else if end == .refused {
            await store.receive(.internal(.watchStartAdmitted(generation: 1, false))) {
                $0.startIntent = nil
                $0.startGeneration = 2
            }
        } else {
            await store.receive(.internal(.watchStartAdmitted(generation: 1, false)))
        }
        if end == .success { await store.send(.destination(.dismiss)) { $0.destination = nil } }
        await clock.advance(by: .seconds(31))
        await store.finish()
    }

    @Test
    func test_takeover_replacesDeadline_busyAndOldExpiryCannotEndNewAdmission() async {
        let clock = TestClock<Duration>()
        let oldSheet = Gate()
        let newAdmission = Gate()
        let answers = LockIsolated<[WatchStartResult]>([])
        let store = makeStore(fixture.ready(), healthAccess: nil) {
            $0.continuousClock = clock
            $0.workoutHealth.access = { .notDetermined }
            $0.workoutHealth.requestAuthorization = { await oldSheet.wait() }
            $0.watchCompanion.startHandled = { id, result in
                answers.withValue { $0.append(result) }
                if id == 8 { await newAdmission.wait() }
                return true
            }
        }
        await store.send(.internal(.watchStartRequested(fixture.request))) {
            $0.startGeneration = 1
            $0.startIntent = self.fixture.pending(clock, stage: .admitting).startIntent
        }
        await store.receive(.internal(.watchStartAdmitted(generation: 1, true))) { $0.startIntent?.stage = .health }
        await store.receive(.internal(.healthAccessQueried(generation: 1, .notDetermined))) {
            $0.healthAccess = .notDetermined
            $0.isHealthRequestOutstanding = true
        }
        await clock.advance(by: .seconds(10))
        await store.receive(.internal(.healthStalled(generation: 1))) { $0.startIntent?.hasStalled = true }
        let request = WatchStartRequest(id: 8, workoutID: fixture.workout.id, scheduleFingerprint: fixture.request.scheduleFingerprint)
        await store.send(.internal(.watchStartRequested(request))) {
            $0.startGeneration = 3
            $0.startIntent = .init(
                generation: 3,
                origin: .watch(requestID: 8),
                workout: self.fixture.workout,
                stage: .admitting,
                skipsHealth: true,
                acceptedAt: MonotonicInstant(now: clock)
            )
        }
        oldSheet.open()
        await store.receive(.internal(.healthPermissionAnswered(generation: 1, succeeded: true))) {
            $0.healthAccess = .determined
            $0.isHealthRequestOutstanding = false
        }
        await store.send(.internal(.healthAccessQueried(generation: 1, .notDetermined)))
        await store.send(.internal(.watchStartExpired(generation: 1)))
        await clock.advance(by: .seconds(20))
        await store.send(.internal(.watchStartRequested(fixture.request)))
        await clock.advance(by: .seconds(10))
        await store.receive(.internal(.watchStartExpired(generation: 3))) {
            $0.startIntent = nil
            $0.startGeneration = 4
        }
        newAdmission.open()
        await store.receive(.internal(.watchStartAdmitted(generation: 3, true)))
        #expect(answers.value == [.accepted(asksOnPhone: true), .accepted(asksOnPhone: false), .busy])
        #expect(store.state.destination == nil)
        await store.finish()
    }

    @Test
    func test_rootTask_cancellation_terminatesStartSubscription() async {
        let requests = AsyncStream<WatchStartRequest>.makeStream()
        let ended = Observed(false)
        requests.continuation.onTermination = { _ in ended.setValue(true) }
        let store = makeStore(AppFeature.State()) {
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: []) }
            $0.watchCompanion.startRequests = { requests.stream }
        }
        let task = await store.send(.view(.task)) {
            $0.workouts = .loading
            $0.runRestore = .reading
        }
        await store.receive(.internal(.runRecordLoaded(nil))) { $0.runRestore = .resolved }
        await store.receive(.internal(.workoutsLoaded(StoredWorkouts(workouts: [])))) { $0.workouts = .loaded([]) }
        await task.cancel()
        await ended.wait { $0 }
        #expect(ended.value)
        await store.finish()
    }
}
