@testable import AppFeature
@testable import WorkoutTimerFeature

import BackgroundNotifications
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
        let accesses = LockIsolated(0)
        let requests = LockIsolated(0)
        let store = offered(saved, notificationsEnabled: true) {
            $0.date = .constant(wall)
            $0.timerSession.end = { id in ends.withValue { $0.append(id) } }
            $0.backgroundNotifications.access = { accesses.withValue { $0 += 1 }; return .authorized }
            $0.backgroundNotifications.requestAuthorization = { requests.withValue { $0 += 1 }; return .authorized }
        }

        await store.send(.destination(.presented(.resumeRun(.resume)))) { $0.destination = nil }
        await store.receive(.internal(.resumeRunConfirmed)) {
            $0.runRestore = .presenting(saved)
            $0.destination = .timer(WorkoutTimerFeature.State(
                id: UUID(0),
                workoutID: workout.id,
                title: workout.name,
                workoutName: workout.name,
                restoring: restored,
                at: wall
            ))
        }
        #expect(store.state.destination?[case: \.timer]?.snapshot.totalElapsed == .seconds(4))
        #expect(store.state.destination?[case: \.timer]?.countdown == nil)
        #expect(store.state.destination?[case: \.timer]?.id == UUID(0))
        #expect(store.state.destination?[case: \.timer]?.run.schedule == WorkoutSchedule(workout: workout))
        #expect(store.state.startIntent == nil)
        #expect(accesses.value == 0)
        #expect(requests.value == 0)
        await store.send(.view(.timerCoverAppeared)) {
            $0.isTimerCoverUp = true
            $0.runRestore = .resolved
        }
        await store.send(.destination(.dismiss)) {
            $0.destination = nil
            $0.isTimerCoverUp = false
        }
        await store.finish()
        #expect(ends.value == [UUID(0)])
    }

    @Test
    func test_cleanup_stalled_preservesOfferedResumeAlertAndRun() async throws {
        let saved = try stored(.paused)
        let store = offered(saved)
        await store.send(.internal(.notificationCleanupFinished(false))) {
            $0.isNotificationCleanupStalled = true
        }
        #expect(store.state.runRestore == .offered(saved))
        #expect(store.state.destination == .resumeRun(.resumeRun(workoutName: workout.name)))
        #expect(store.state.startIntent == nil)
        await store.send(.destination(.dismiss)) {
            $0.destination = nil
            $0.runRestore = .resolved
        }
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
            $0.runRestore = .presenting(saved)
            $0.destination = .timer(WorkoutTimerFeature.State(
                id: UUID(0),
                workoutID: workout.id,
                title: workout.name,
                workoutName: workout.name,
                restoring: restored,
                at: wall
            ))
        }
        #expect(store.state.destination?[case: \.timer]?.snapshot.status == .finished)
        await store.send(.view(.timerCoverAppeared)) {
            $0.isTimerCoverUp = true
            $0.runRestore = .resolved
        }
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

    @Test(arguments: [WorkoutRunRecord.Phase.running, .paused])
    func test_retry_failedRestoredCover_settlesAtEachAttemptAndUsesFreshOwner(phase: WorkoutRunRecord.Phase) async throws {
        let saved = try stored(phase)
        let wall = LockIsolated(now)
        let writes = LockIsolated<[WorkoutRunRecord?]>([])
        let ends = LockIsolated<[UUID]>([])
        let store = offered(saved) {
            $0.date = .init { wall.value }
            $0.timerSession.end = { id in ends.withValue { $0.append(id) } }
            $0.workoutRunRecord.write = { record, _ in writes.withValue { $0.append(record) } }
        }
        for (attempt, elapsed) in [0, 4, 7].enumerated() {
            let date = now.addingTimeInterval(TimeInterval(elapsed))
            wall.setValue(date)
            let run = try WorkoutRun(schedule: WorkoutSchedule(workout: workout), restoring: saved.record, at: date)
            await store.send(.destination(.presented(.resumeRun(.resume)))) { $0.destination = nil }
            await store.receive(.internal(.resumeRunConfirmed)) {
                $0.runRestore = .presenting(saved)
                $0.destination = .timer(WorkoutTimerFeature.State(
                    id: UUID(attempt), workoutID: workout.id, title: workout.name, workoutName: workout.name, restoring: run, at: date
                ))
            }
            #expect(store.state.destination?[case: \.timer]?.snapshot.totalElapsed == .seconds(phase == .running ? elapsed : 3))
            #expect(store.state.destination?[case: \.timer]?.countdown == nil)
            if attempt < 2 {
                await store.send(.destination(.dismiss)) {
                    $0.destination = nil
                    $0.runRestore = .offered(saved)
                }
                await store.receive(.internal(.timerPresentationFailed)) { $0.destination = .resumeRun(.retryTimer) }
                await store.finish()
                #expect(writes.value.isEmpty)
            } else {
                await store.send(.view(.timerCoverAppeared)) {
                    $0.isTimerCoverUp = true
                    $0.runRestore = .resolved
                }
                await store.send(.destination(.dismiss)) {
                    $0.destination = nil
                    $0.isTimerCoverUp = false
                }
                await store.finish()
                #expect(writes.value == [nil])
            }
        }
        #expect(ends.value == [UUID(0), UUID(1), UUID(2)])
    }

    @Test(arguments: [false, true])
    func test_finish_failedRestoredCover_clearsRecordOrReportsFailure(fails: Bool) async throws {
        let saved = try stored(.paused)
        let run = try WorkoutRun(schedule: WorkoutSchedule(workout: workout), restoring: saved.record, at: now)
        let writes = LockIsolated<[WorkoutRunRecord?]>([])
        let store = offered(saved) {
            $0.date = .constant(now)
            $0.timerSession.end = { _ in }
            $0.workoutRunRecord.write = { record, _ in
                writes.withValue { $0.append(record) }
                if fails { throw SaveFailure() }
            }
        }
        await store.send(.destination(.presented(.resumeRun(.resume)))) { $0.destination = nil }
        await store.receive(.internal(.resumeRunConfirmed)) {
            $0.runRestore = .presenting(saved)
            $0.destination = .timer(WorkoutTimerFeature.State(
                id: UUID(0), workoutID: workout.id, title: workout.name, workoutName: workout.name, restoring: run, at: now
            ))
        }
        await store.send(.destination(.dismiss)) {
            $0.destination = nil
            $0.runRestore = .offered(saved)
        }
        await store.receive(.internal(.timerPresentationFailed)) { $0.destination = .resumeRun(.retryTimer) }
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

    @Test
    func test_timerPresentationFailed_anotherDestinationIsPresented_doesNotReplaceIt() async throws {
        let saved = try stored(.running)
        let store = offered(saved)
        await store.send(.internal(.timerPresentationFailed))
    }

    @Test
    func test_load_runningRecordReachesManualPauseAfterADay_discardsSilently() async throws {
        let workout = Workout(
            id: UUID(fixture: 1),
            warmUp: [makeStage(1)],
            training: [makeStage(2)],
            pauseAfterWarmUp: true
        )
        var run = WorkoutRun(schedule: WorkoutSchedule(workout: workout))
        run.start(at: now)
        let saved = StoredRunRecord(record: try #require(WorkoutRunRecord(workoutID: workout.id, run: run)), savedAt: now)
        var state = AppFeature.State()
        state.workouts = .loading
        state.runRestore = .found(saved)
        let writes = LockIsolated<[WorkoutRunRecord?]>([])
        let store = makeStore(state) {
            $0.date = .constant(now.addingTimeInterval(86_401))
            $0.workoutRunRecord.write = { record, _ in writes.withValue { $0.append(record) } }
        }

        await store.send(.internal(.workoutsLoaded(StoredWorkouts(workouts: [workout])))) {
            $0.workouts = .loaded([workout])
            $0.runRestore = .resolved
        }
        await store.finish()
        #expect(writes.value == [nil])
        #expect(store.state.destination == nil)
    }

    @Test
    func test_workoutsChangedRemotely_runRecordStillRead_offersTheRunOnceAfterTheSecondRead() async throws {
        let saved = try stored(.running)
        var state = AppFeature.State()
        state.workouts = .loading
        state.runRestore = .reading
        let fetches = LockIsolated(0)
        let store = makeStore(state) {
            $0.date = .constant(now)
            $0.workoutStorage.fetchAll = {
                fetches.withValue { $0 += 1 }
                return StoredWorkouts(workouts: [workout])
            }
        }

        await store.send(.internal(.workoutsChangedRemotely)) { $0.needsReload = true }
        await store.send(.internal(.runRecordLoaded(saved))) { $0.runRestore = .found(saved) }
        await store.receive(\.internal.workoutsLoaded) { $0.needsReload = false }
        await store.receive(\.internal.workoutsLoaded) {
            $0.workouts = .loaded([workout])
            $0.runRestore = .offered(saved)
            $0.destination = .resumeRun(.resumeRun(workoutName: workout.name))
        }

        #expect(fetches.value == 2)
        await store.send(.destination(.dismiss)) {
            $0.destination = nil
            $0.runRestore = .resolved
        }
    }

    @Test(arguments: ["gone", "otherSchedule"])
    func test_continue_offeredWorkoutChangedRemotely_dropsTheRunWithoutATimer(change: String) async throws {
        let saved = try stored(.paused)
        var otherSchedule = workout
        otherSchedule.training[0].duration = .seconds(20)
        let reloaded = change == "gone" ? [makeWorkout(2)] : [otherSchedule]
        let fetches = LockIsolated(0)
        let writes = LockIsolated<[WorkoutRunRecord?]>([])
        let store = offered(saved) {
            $0.date = .constant(now)
            $0.workoutStorage.fetchAll = {
                fetches.withValue { $0 += 1 }
                return StoredWorkouts(workouts: reloaded)
            }
            $0.workoutRunRecord.write = { record, _ in writes.withValue { $0.append(record) } }
        }

        await store.send(.internal(.workoutsChangedRemotely)) { $0.isReloading = true }
        await store.receive(\.internal.workoutsLoaded) {
            $0.isReloading = false
            $0.workouts = .loaded(IdentifiedArray(uniqueElements: reloaded))
        }
        #expect(store.state.runRestore == .offered(saved))
        #expect(writes.value.isEmpty)

        await store.send(.destination(.presented(.resumeRun(.resume)))) { $0.destination = nil }
        await store.receive(.internal(.resumeRunConfirmed)) {
            $0.runRestore = .resolved
            $0.destination = .alert(.runNotRestored)
        }
        await store.finish()

        #expect(writes.value == [nil])
        #expect(fetches.value == 1)
    }

    @Test
    func test_continue_offeredWorkoutRenamedRemotely_opensTheTimerWithTheReloadedWorkout() async throws {
        let saved = try stored(.paused)
        let renamed = makeWorkout(1, name: "Renamed")
        let run = try WorkoutRun(schedule: WorkoutSchedule(workout: renamed), restoring: saved.record, at: now)
        let store = offered(saved) {
            $0.date = .constant(now)
            $0.timerSession.end = { _ in }
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: [renamed]) }
        }

        await store.send(.internal(.workoutsChangedRemotely)) { $0.isReloading = true }
        await store.receive(\.internal.workoutsLoaded) {
            $0.isReloading = false
            $0.workouts = .loaded([renamed])
        }
        await store.send(.destination(.presented(.resumeRun(.resume)))) { $0.destination = nil }
        await store.receive(.internal(.resumeRunConfirmed)) {
            $0.runRestore = .presenting(saved)
            $0.destination = .timer(WorkoutTimerFeature.State(
                id: UUID(0), workoutID: renamed.id, title: "Renamed", workoutName: "Renamed", restoring: run, at: now
            ))
        }
        #expect(store.state.destination?[case: \.timer]?.snapshot.totalElapsed == .seconds(3))

        await store.send(.view(.timerCoverAppeared)) {
            $0.isTimerCoverUp = true
            $0.runRestore = .resolved
        }
        await store.send(.destination(.dismiss)) {
            $0.destination = nil
            $0.isTimerCoverUp = false
        }
        await store.finish()
    }

    private func stored(_ phase: WorkoutRunRecord.Phase) throws -> StoredRunRecord {
        var run = WorkoutRun(schedule: WorkoutSchedule(workout: workout))
        run.start(at: now)
        if phase == .paused { run.pause(at: now.addingTimeInterval(3)) }
        return StoredRunRecord(record: try #require(WorkoutRunRecord(workoutID: workout.id, run: run)), savedAt: now)
    }

    private func offered(
        _ saved: StoredRunRecord,
        notificationsEnabled: Bool = false,
        dependencies: (inout DependencyValues) -> Void = { _ in }
    ) -> TestStoreOf<AppFeature> {
        var state = loaded([workout])
        state.runRestore = .offered(saved)
        state.destination = .resumeRun(.resumeRun(workoutName: workout.name))
        return makeStore(state, notificationsEnabled: notificationsEnabled, dependencies: dependencies)
    }

    private struct SaveFailure: Error {}
}
