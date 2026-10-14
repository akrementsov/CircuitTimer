@testable import AppFeature
@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain
import WorkoutStorage

@MainActor
@Suite
struct AppFeatureRunRestoreTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let workout = makeWorkout(1)

    @Test(arguments: [WorkoutRunRecord.Phase.running, .paused])
    func test_launch_validRecord_offersChoiceWithoutStartingTimer(phase: WorkoutRunRecord.Phase) async throws {
        let saved = try stored(phase)
        let store = makeStore(AppFeature.State()) {
            $0.date = .constant(now)
            $0.workoutRunRecord.load = { saved }
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: [workout]) }
        }

        await store.send(.view(.task)) {
            $0.workouts = .loading
            $0.runRestore = .reading
        }
        await store.receive(.internal(.runRecordLoaded(saved))) { $0.runRestore = .found(saved) }
        await store.receive(\.internal.workoutsLoaded) {
            $0.workouts = .loaded([workout])
            $0.runRestore = .offered(saved)
            $0.destination = .resumeRun(.resumeRun(workoutName: workout.name))
        }
        #expect(store.state.destination?.is(\.timer) == false)
        await store.send(.destination(.dismiss)) {
            $0.runRestore = .resolved
            $0.destination = nil
        }
    }

    @Test
    func test_continue_runningRecord_settlesAtChoiceAndPresentsWithoutCountdown() async throws {
        let saved = try stored(.running)
        let wall = now.addingTimeInterval(4)
        let restored = try WorkoutRun(schedule: WorkoutSchedule(workout: workout), restoring: saved.record, at: wall)
        let ends = LockIsolated<[UUID]>([])
        let store = offered(saved) {
            $0.date = .constant(wall)
            $0.timerSession.end = { id in ends.withValue { $0.append(id) } }
        }

        await store.send(.destination(.presented(.resumeRun(.resume)))) { $0.destination = nil }
        await store.receive(.internal(.resumeRunConfirmed)) {
            $0.runRestore = .resolved
            $0.destination = .timer(WorkoutTimerFeature.State(
                id: UUID(0),
                workoutID: workout.id,
                title: workout.name,
                restoring: restored,
                at: wall
            ))
        }
        #expect(store.state.destination?[case: \.timer]?.snapshot.totalElapsed == .seconds(4))
        #expect(store.state.destination?[case: \.timer]?.countdown == nil)
        await store.send(.view(.timerCoverAppeared)) { $0.isTimerCoverUp = true }
        await store.send(.destination(.dismiss)) {
            $0.destination = nil
            $0.isTimerCoverUp = false
        }
        await store.finish()
        #expect(ends.value == [UUID(0)])
    }

    @Test
    func test_continue_runEndedWhileQuestionShown_opensFinishedTimer() async throws {
        let saved = try stored(.running)
        let wall = now.addingTimeInterval(100)
        let restored = try WorkoutRun(schedule: WorkoutSchedule(workout: workout), restoring: saved.record, at: wall)
        let store = offered(saved) {
            $0.date = .constant(wall)
            $0.timerSession.end = { _ in }
        }
        await store.send(.destination(.presented(.resumeRun(.resume)))) { $0.destination = nil }
        await store.receive(.internal(.resumeRunConfirmed)) {
            $0.runRestore = .resolved
            $0.destination = .timer(WorkoutTimerFeature.State(
                id: UUID(0),
                workoutID: workout.id,
                title: workout.name,
                restoring: restored,
                at: wall
            ))
        }
        #expect(store.state.destination?[case: \.timer]?.snapshot.status == .finished)
        await store.send(.view(.timerCoverAppeared)) { $0.isTimerCoverUp = true }
        await store.send(.destination(.dismiss)) {
            $0.destination = nil
            $0.isTimerCoverUp = false
        }
        await store.finish()
    }

    @Test(arguments: [false, true])
    func test_finish_offeredRecord_clearsOrShowsFailure(fails: Bool) async throws {
        let saved = try stored(.paused)
        let writes = LockIsolated<[WorkoutRunRecord?]>([])
        let store = offered(saved) {
            $0.workoutRunRecord.write = { record, _ in
                writes.withValue { $0.append(record) }
                if fails { throw SaveFailure() }
            }
        }
        await store.send(.destination(.presented(.resumeRun(.finish)))) {
            $0.destination = nil
            $0.runRestore = .resolved
        }
        if fails {
            await store.receive(.internal(.runFinishFailed)) { $0.destination = .alert(.runNotFinished) }
            await store.send(.destination(.dismiss)) { $0.destination = nil }
        }
        await store.finish()
        #expect(writes.value == [nil])
    }

    @Test(arguments: ["ended", "oldPause", "deleted", "changed"])
    func test_load_nonRestorableRun_dropsAndOnlyUnexpectedLossShowsAlert(reason: String) async throws {
        let saved = try stored(reason == "oldPause" ? .paused : .running)
        var state = AppFeature.State()
        state.workouts = .loading
        state.runRestore = .found(saved)
        let wall = reason == "ended" || reason == "oldPause" ? now.addingTimeInterval(86_401) : now
        var current = workout
        if reason == "changed" { current.training[0].duration = .seconds(20) }
        let workouts = reason == "deleted" ? [] : [current]
        let writes = LockIsolated<[WorkoutRunRecord?]>([])
        let store = makeStore(state) {
            $0.date = .constant(wall)
            $0.workoutRunRecord.write = { record, _ in writes.withValue { $0.append(record) } }
        }

        await store.send(.internal(.workoutsLoaded(StoredWorkouts(workouts: workouts)))) {
            $0.workouts = .loaded(IdentifiedArray(uniqueElements: workouts))
            $0.runRestore = .resolved
            if reason == "deleted" || reason == "changed" { $0.destination = .alert(.runNotRestored) }
        }
        await store.finish()
        #expect(writes.value == [nil])
        if store.state.destination != nil {
            await store.send(.destination(.dismiss)) { $0.destination = nil }
        }
    }

    @Test(arguments: [AppFeature.RunRecordLoadFailure.unreadable, .corrupt, .unsupportedSchema])
    func test_load_failedRecord_reportsAndOnlyClearsCorrupt(failure: AppFeature.RunRecordLoadFailure) async {
        var state = AppFeature.State()
        state.workouts = .loading
        state.runRestore = .reading
        let writes = LockIsolated<[WorkoutRunRecord?]>([])
        let store = makeStore(state) {
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: []) }
            $0.workoutRunRecord.write = { record, _ in writes.withValue { $0.append(record) } }
        }
        await store.send(.internal(.runRecordLoadingFailed(failure))) {
            $0.runRestore = .resolved
            $0.destination = .alert(.runNotRestored)
        }
        await store.receive(\.internal.workoutsLoaded) { $0.workouts = .loaded([]) }
        await store.finish()
        #expect(writes.value == (failure == .corrupt ? [nil] : []))
        await store.send(.destination(.dismiss)) { $0.destination = nil }
    }

    @Test
    func test_launch_stalledRead_timesOutWithoutErasingRecord() async {
        let clock = TestClock<Duration>()
        let writes = LockIsolated(0)
        let store = makeStore(AppFeature.State()) {
            $0.continuousClock = clock
            $0.workoutRunRecord.load = { try await Task.never() }
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: []) }
            $0.workoutRunRecord.write = { _, _ in writes.withValue { $0 += 1 } }
        }
        await store.send(.view(.task)) {
            $0.workouts = .loading
            $0.runRestore = .reading
        }
        await clock.advance(by: .seconds(2))
        await store.receive(.internal(.runRecordReadTimedOut)) {
            $0.runRestore = .resolved
            $0.destination = .alert(.runNotRestored)
        }
        await store.receive(\.internal.workoutsLoaded) { $0.workouts = .loaded([]) }
        #expect(writes.value == 0)
        await store.send(.destination(.dismiss)) { $0.destination = nil }
    }

    @Test
    func test_recordLoaded_afterTimeout_doesNotReplaceCurrentList() async throws {
        let saved = try stored(.running)
        var state = loaded([workout])
        state.runRestore = .resolved
        let store = makeStore(state)
        await store.send(.internal(.runRecordLoaded(saved)))
    }

    @Test
    func test_destinationDismiss_beforeRestoredCoverAppears_reportsFailureAndKeepsRecord() async throws {
        let saved = try stored(.running)
        let run = try WorkoutRun(schedule: WorkoutSchedule(workout: workout), restoring: saved.record, at: now)
        var state = loaded([workout])
        state.runRestore = .resolved
        state.destination = .timer(WorkoutTimerFeature.State(
            id: UUID(fixture: 99),
            workoutID: workout.id,
            title: workout.name,
            restoring: run,
            at: now
        ))
        let clears = LockIsolated(0)
        let store = makeStore(state) {
            $0.timerSession.end = { _ in }
            $0.workoutRunRecord.write = { _, _ in clears.withValue { $0 += 1 } }
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.receive(.internal(.timerPresentationFailed)) { $0.destination = .alert(.timerNotPresented) }
        #expect(clears.value == 0)
        await store.send(.destination(.dismiss)) { $0.destination = nil }
    }

    private func stored(_ phase: WorkoutRunRecord.Phase) throws -> StoredRunRecord {
        var run = WorkoutRun(schedule: WorkoutSchedule(workout: workout))
        run.start(at: now)
        if phase == .paused { run.pause(at: now.addingTimeInterval(3)) }
        return StoredRunRecord(record: try #require(WorkoutRunRecord(workoutID: workout.id, run: run)), savedAt: now)
    }

    private func offered(
        _ saved: StoredRunRecord,
        dependencies: (inout DependencyValues) -> Void = { _ in }
    ) -> TestStoreOf<AppFeature> {
        var state = loaded([workout])
        state.runRestore = .offered(saved)
        state.destination = .resumeRun(.resumeRun(workoutName: workout.name))
        return makeStore(state, dependencies: dependencies)
    }

    private struct SaveFailure: Error {}
}
