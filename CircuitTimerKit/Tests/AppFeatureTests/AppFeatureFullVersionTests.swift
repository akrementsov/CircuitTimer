@testable import AppFeature
@testable import WorkoutEditorFeature

import ComposableArchitecture
import Foundation
import PurchaseFeature
import Purchases
import SettingsFeature
import Testing
import WorkoutDomain
import WorkoutStorage

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppFeatureFullVersionTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let first = makeWorkout(1)
    private let second = makeWorkout(2)
    private let third = makeWorkout(3)

    // MARK: - Launch and status

    @Test
    func test_task_hungCloudSyncDecision_delaysNeitherTheSavedRunQuestionNorTheFullVersion() async throws {
        let saved = try pausedRun(of: first, at: now)
        let decision = Gate()
        let decisions = LockIsolated(0)
        let statuses = AsyncStream<FullVersionStatus>.makeStream()
        let store = makeStore(AppFeature.State()) {
            $0.date = .constant(now)
            $0.cloudSync.prepareDecision = {
                decisions.withValue { $0 += 1 }
                await decision.wait()
            }
            $0.purchases.changes = { statuses.stream }
            $0.workoutRunRecord.load = { saved }
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: [first]) }
        }

        await store.send(.view(.task)) {
            $0.workouts = .loading
            $0.runRestore = .reading
        }
        await store.receive(.internal(.runRecordLoaded(saved))) { $0.runRestore = .found(saved) }
        await store.receive(\.internal.workoutsLoaded) {
            $0.workouts = .loaded([first])
            $0.runRestore = .offered(saved)
            $0.destination = .resumeRun(.resumeRun(workoutName: first.name))
        }
        statuses.continuation.yield(.free)
        await store.receive(.internal(.fullVersionChanged(.free))) {
            $0.fullVersion = .free
            $0.settings.fullVersion = .free
        }
        while decisions.value == 0 {
            await Task.yield()
        }
        #expect(decisions.value == 1)

        statuses.continuation.finish()
        decision.open()
        await store.finish()
    }

    @Test
    func test_fullVersionChanges_askToBuyApprovedThenRefunded_unlockAndLockNewWorkoutsAgain() async {
        let statuses = AsyncStream<FullVersionStatus>.makeStream()
        let store = makeStore(AppFeature.State()) {
            $0.purchases.changes = { statuses.stream }
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: [first, second]) }
        }
        await store.send(.view(.task)) {
            $0.workouts = .loading
            $0.runRestore = .reading
        }
        await store.receive(.internal(.runRecordLoaded(nil))) { $0.runRestore = .resolved }
        await store.receive(\.internal.workoutsLoaded) { $0.workouts = .loaded([first, second]) }
        statuses.continuation.yield(.free)
        await store.receive(.internal(.fullVersionChanged(.free))) {
            $0.fullVersion = .free
            $0.settings.fullVersion = .free
        }

        // The purchase waits for approval; the user closes the sheet.
        await store.send(.view(.addButtonTapped)) {
            $0.destination = .purchase(PurchaseFeature.State(entry: .limit(.workoutLimit)))
        }
        await store.send(.destination(.presented(.purchase(.delegate(.closeRequested))))) { $0.destination = nil }
        await store.send(.view(.purchaseSheetDismissed))

        statuses.continuation.yield(.full)
        await store.receive(.internal(.fullVersionChanged(.full))) {
            $0.fullVersion = .full
            $0.settings.fullVersion = .full
        }
        await store.send(.view(.addButtonTapped)) {
            $0.path[id: 0] = .editor(WorkoutEditorFeature.State(
                newWorkoutID: UUID(0),
                warmUpStageID: UUID(1),
                trainingStageID: UUID(2),
                coolDownStageID: UUID(3)
            ))
        }
        await store.send(.path(.popFrom(id: 0))) { $0.path = StackState() }

        statuses.continuation.yield(.free)
        await store.receive(.internal(.fullVersionChanged(.free))) {
            $0.fullVersion = .free
            $0.settings.fullVersion = .free
        }
        await store.send(.view(.addButtonTapped)) {
            $0.destination = .purchase(PurchaseFeature.State(entry: .limit(.workoutLimit)))
        }

        statuses.continuation.finish()
        await store.finish()
    }

    @Test(arguments: [
        (SettingsFeature.FullVersionRequest.buy, PurchaseFeature.Entry.browse),
        (.restore, .restore),
        (.iCloudSync, .limit(.iCloudSync)),
    ])
    func test_settingsRequest_free_opensTheSheetForItsEntry(
        request: SettingsFeature.FullVersionRequest,
        entry: PurchaseFeature.Entry
    ) async {
        let store = makeStore(freeVersion([first]))

        await store.send(.settings(.delegate(.fullVersionRequested(request)))) {
            $0.destination = .purchase(PurchaseFeature.State(entry: entry))
        }

        #expect(store.state.purchaseRequest == nil)
    }

    // MARK: - Free limit

    @Test
    func test_add_free_opensTheEditorAtOneWorkoutAndTheSheetAtTwo() async {
        let one = makeStore(freeVersion([first]))
        await one.send(.view(.addButtonTapped)) {
            $0.path[id: 0] = .editor(WorkoutEditorFeature.State(
                newWorkoutID: UUID(0),
                warmUpStageID: UUID(1),
                trainingStageID: UUID(2),
                coolDownStageID: UUID(3)
            ))
        }

        let two = makeStore(freeVersion([first, second]))
        await two.send(.view(.addButtonTapped)) {
            $0.destination = .purchase(PurchaseFeature.State(entry: .limit(.workoutLimit)))
        }
        #expect(two.state.path.isEmpty)
    }

    @Test
    func test_duplicate_freeAtTwo_opensTheSheetAndInsertsNothing() async {
        // `insert` keeps its unimplemented test value: a call fails the test.
        let store = makeStore(freeVersion([first, second]))

        await store.send(.view(.duplicateButtonTapped(first.id))) {
            $0.destination = .purchase(PurchaseFeature.State(entry: .limit(.workoutLimit)))
        }
    }

    @Test(arguments: [
        (FullVersionStatus.free, 1, 0, false),
        (.free, 1, 5, false),
        (.free, 2, 0, true),
        (.free, 3, 0, true),
        (.unknown, 1, 0, false),
        (.unknown, 2, 0, true),
        (.full, 3, 0, false),
    ])
    func test_isAtFreeWorkoutLimit_loadedList_countsTheShownWorkoutsOnly(
        status: FullVersionStatus,
        shown: Int,
        hidden: Int,
        isAtLimit: Bool
    ) {
        var state = freeVersion((1 ... shown).map { makeWorkout($0) }, status: status)
        state.hiddenRecordCount = hidden

        #expect(AppFeature().isAtFreeWorkoutLimit(state) == isAtLimit)
    }

    @Test(arguments: [AppFeature.Content.idle, .loading, .failed])
    func test_isAtFreeWorkoutLimit_noListShown_isNotAtTheLimit(content: AppFeature.Content) {
        var state = freeVersion([])
        state.workouts = content

        #expect(!AppFeature().isAtFreeWorkoutLimit(state))
    }

    @Test
    func test_duplicate_freeQuickSecondTapAtOne_firstInsertsSecondOpensTheSheet() async throws {
        let write = Gate()
        let store = makeStore(freeVersion([first])) {
            $0.workoutStorage.insert = { _, _ in
                await write.wait()
                return .applied
            }
        }

        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.view(.duplicateButtonTapped(first.id)))
        let copy = try #require(store.state.workouts.list.last)
        #expect(store.state.workouts.list.map(\.id) == [first.id, copy.id])
        #expect(store.state.pendingMutations == [.insert(copy, after: first.id)])

        store.exhaustivity = .on
        await store.send(.view(.duplicateButtonTapped(first.id))) {
            $0.destination = .purchase(PurchaseFeature.State(entry: .limit(.workoutLimit)))
        }
        write.open()
        await store.receive(.internal(.mutationFinished(.applied))) { $0.pendingMutations = [] }
    }

    @Test
    func test_add_freeDuringAReload_isCheckedOnTheListTheReloadBrings() async {
        var state = freeVersion([first])
        state.isReloading = true
        let store = makeStore(state)

        await store.send(.view(.addButtonTapped)) { $0.deferredScreen = .create }
        await store.send(.internal(.workoutsLoaded(StoredWorkouts(workouts: [first, second])))) {
            $0.isReloading = false
            $0.workouts = .loaded([first, second])
            $0.deferredScreen = nil
            $0.destination = .purchase(PurchaseFeature.State(entry: .limit(.workoutLimit)))
        }
    }

    @Test(arguments: [FullVersionStatus.free, .unknown])
    func test_storedWorkouts_overTheFreeLimit_openSaveAndStartWithoutTheSheet(status: FullVersionStatus) async throws {
        var renamed = third
        renamed.name = "Renamed"
        let store = makeStore(freeVersion([first, second, third], status: status)) {
            $0.timerSession.end = { _ in }
        }

        // Stack element identifiers are not fixed across the arguments of one test.
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.view(.workoutTapped(third.id)))
        store.exhaustivity = .on
        let id = try #require(store.state.path.ids.last)
        #expect(store.state.path[id: id, case: \.editor] == WorkoutEditorFeature.State(viewing: third))
        #expect(store.state.destination == nil)

        await store.send(.path(.element(id: id, action: .editor(.delegate(.saved(renamed)))))) {
            $0.workouts = .loaded([first, second, renamed])
        }
        await store.send(.path(.element(id: id, action: .editor(.delegate(.startRequested(third)))))) {
            $0.destination = .timer(timerState(for: third, allowsWatchControl: false))
        }
        await store.send(.view(.timerCoverAppeared)) {
            $0.path = StackState()
            $0.isTimerCoverUp = true
        }
        await store.send(.destination(.dismiss)) {
            $0.destination = nil
            $0.isTimerCoverUp = false
        }
        await store.finish()
    }
}

extension AppFeature.Content {
    fileprivate var list: [Workout] {
        if case let .loaded(workouts) = self { Array(workouts) } else { [] }
    }
}
