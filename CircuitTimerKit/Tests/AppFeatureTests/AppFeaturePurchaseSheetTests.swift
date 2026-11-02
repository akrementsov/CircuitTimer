@testable import AppFeature
@testable import SettingsFeature
@testable import WorkoutEditorFeature

import CloudSync
import ComposableArchitecture
import Foundation
import PurchaseFeature
import Purchases
import Testing
import WorkoutDomain
import WorkoutStorage

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppFeaturePurchaseSheetTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let workout = makeWorkout(1)
    private let sheet = AppFeature.Destination.State.purchase(PurchaseFeature.State(entry: .browse))

    // MARK: - When a request shows

    @Test(arguments: ["idle", "reading", "found", "offered", "presenting"])
    func test_request_launchQuestionNotSettled_waits(launch: String) async throws {
        var state = freeVersion([workout])
        let saved = try pausedRun(of: workout, at: now)
        state.runRestore = switch launch {
            case "idle": .idle
            case "reading": .reading
            case "found": .found(saved)
            case "offered": .offered(saved)
            default: .presenting(saved)
        }
        let store = makeStore(state)

        await store.send(.settings(.delegate(.fullVersionRequested(.buy)))) { $0.purchaseRequest = .browse }
    }

    @Test(arguments: [false, true])
    func test_request_launchQuestionSettledOrBlockedByAFailedLoad_opensTheSheet(isFoundAfterFailedLoad: Bool) async throws {
        var state = freeVersion([workout])
        if isFoundAfterFailedLoad {
            state.runRestore = .found(try pausedRun(of: workout, at: now))
            state.workouts = .failed
        }
        let store = makeStore(state)

        await store.send(.settings(.delegate(.fullVersionRequested(.buy)))) { $0.destination = self.sheet }
    }

    @Test(arguments: ["alert", "resumeRun", "permissionStalled", "purchase"])
    func test_request_underAnotherPresentation_waits(presentation: String) async {
        var state = freeVersion([workout])
        state.destination = switch presentation {
            case "alert": .alert(.mutationFailed)
            case "resumeRun": .resumeRun(.resumeRun(workoutName: workout.name))
            case "permissionStalled": .permissionStalled(.permissionStalled)
            default: .purchase(PurchaseFeature.State(entry: .limit(.iCloudSync)))
        }
        let store = makeStore(state)

        await store.send(.settings(.delegate(.fullVersionRequested(.buy)))) { $0.purchaseRequest = .browse }
    }

    @Test(arguments: ["off", "mirroring", "local", "unread"])
    func test_request_opensTheSheetWithWhatAPurchaseMeansForICloud(sync: String) async {
        // Its own preferences: the test context's are shared by the arguments running in parallel.
        let defaults = UserDefaults.inMemory
        let state = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            var state = freeVersion([workout])
            state.settings.$isICloudSyncOn.withLock { $0 = sync != "off" }
            switch sync {
                case "mirroring": state.settings.cloudSyncStatus = CloudSyncStatus(isRequested: false, isMirroring: true, problem: nil)
                case "local", "off": state.settings.cloudSyncStatus = CloudSyncStatus(isRequested: false, isMirroring: false, problem: nil)
                default: break
            }
            return state
        }
        let outlook: PurchaseFeature.ICloudOutlook = switch sync {
            case "off": .off
            case "mirroring": .alreadySyncing
            default: .startsNextLaunch
        }
        let store = makeStore(state) { $0.defaultAppStorage = defaults }

        await store.send(.settings(.delegate(.fullVersionRequested(.buy)))) {
            $0.destination = .purchase(PurchaseFeature.State(entry: .browse, iCloudOutlook: outlook))
        }
    }

    @Test
    func test_request_underTheTimer_isDropped() async {
        var state = freeVersion([workout])
        state.destination = .timer(timerState(for: workout))
        let store = makeStore(state)

        // Set and dropped in the same pass: nothing changes.
        await store.send(.settings(.delegate(.fullVersionRequested(.buy))))
    }

    @Test
    func test_requests_latestWinsAndAKnownFullVersionDropsAny() async {
        var state = freeVersion([workout])
        state.runRestore = .reading
        let store = makeStore(state)

        await store.send(.settings(.delegate(.fullVersionRequested(.buy)))) { $0.purchaseRequest = .browse }
        await store.send(.settings(.delegate(.fullVersionRequested(.iCloudSync)))) {
            $0.purchaseRequest = .limit(.iCloudSync)
        }
        await store.send(.internal(.fullVersionChanged(.full))) {
            $0.fullVersion = .full
            $0.settings.fullVersion = .full
            $0.purchaseRequest = nil
        }
        await store.send(.settings(.delegate(.fullVersionRequested(.restore))))
    }

    // MARK: - What waits for a free presentation

    @Test(arguments: ["alert", "resumeRun"])
    func test_dismiss_alertOrResumeQuestionWithARequestWaiting_showsTheSheetFromALaterAction(presentation: String) async throws {
        var state = freeVersion([workout])
        if presentation == "alert" {
            state.destination = .alert(.mutationFailed)
        } else {
            state.runRestore = .offered(try pausedRun(of: workout, at: now))
            state.destination = .resumeRun(.resumeRun(workoutName: workout.name))
        }
        state.purchaseRequest = .browse
        let store = makeStore(state)

        // The alert is still on screen during its own dismissal: the request waits through it.
        await store.send(.destination(.dismiss)) {
            $0.destination = nil
            $0.runRestore = .resolved
        }
        await store.receive(.internal(.presentationFreed)) {
            $0.destination = self.sheet
            $0.purchaseRequest = nil
        }
    }

    @Test
    func test_dismiss_alertWithNothingWaiting_schedulesNothing() async {
        var state = freeVersion([workout])
        state.destination = .alert(.mutationFailed)
        let store = makeStore(state)

        await store.send(.destination(.dismiss)) { $0.destination = nil }
    }

    @Test
    func test_dismiss_sheet_schedulesNothingUntilItsOnDismiss() async {
        var state = freeVersion([workout])
        state.destination = sheet
        state.hasPendingMutationAlert = true
        let store = makeStore(state)

        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.send(.view(.purchaseSheetDismissed)) {
            $0.hasPendingMutationAlert = false
            $0.destination = .alert(.mutationFailed)
        }
    }

    @Test
    func test_resolveRestore_underTheSheet_keepsTheRunFoundAndAsksOnceTheSheetHasGone() async throws {
        let saved = try pausedRun(of: workout, at: now)
        var state = freeVersion([])
        state.workouts = .failed
        state.runRestore = .found(saved)
        state.destination = sheet
        let store = makeStore(state) { $0.date = .constant(now) }

        await store.send(.internal(.workoutsLoaded(StoredWorkouts(workouts: [workout])))) {
            $0.workouts = .loaded([self.workout])
        }
        await store.send(.destination(.presented(.purchase(.delegate(.closeRequested))))) { $0.destination = nil }
        await store.send(.view(.purchaseSheetDismissed)) {
            $0.runRestore = .offered(saved)
            $0.destination = .resumeRun(.resumeRun(workoutName: self.workout.name))
        }
    }

    @Test
    func test_mutationFailed_underTheSheet_keepsItAndReloadsWithTheAlertPending() async {
        var state = freeVersion([workout])
        state.destination = sheet
        state.pendingMutations = [.delete(UUID(fixture: 9))]
        let store = makeStore(state) {
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: [workout]) }
        }

        await store.send(.internal(.mutationFailed)) {
            $0.pendingMutations = []
            $0.hasPendingMutationAlert = true
            $0.isReloading = true
        }
        await store.receive(\.internal.workoutsLoaded) { $0.isReloading = false }
    }

    @Test
    func test_timerCoverAppeared_pendingWriteAlert_isDropped() async {
        var state = freeVersion([workout])
        state.destination = .timer(timerState(for: workout))
        state.hasPendingMutationAlert = true
        let store = makeStore(state)

        await store.send(.view(.timerCoverAppeared)) {
            $0.hasPendingMutationAlert = false
            $0.isTimerCoverUp = true
        }
    }

    @Test
    func test_sheetGone_savedRunAndFailedWrite_askTheQuestionThenShowTheAlertOnce() async throws {
        let saved = try pausedRun(of: workout, at: now)
        var state = freeVersion([workout])
        state.runRestore = .found(saved)
        state.destination = sheet
        state.hasPendingMutationAlert = true
        let store = makeStore(state) { $0.date = .constant(now) }

        await store.send(.destination(.presented(.purchase(.delegate(.closeRequested))))) { $0.destination = nil }
        await store.send(.view(.purchaseSheetDismissed)) {
            $0.runRestore = .offered(saved)
            $0.destination = .resumeRun(.resumeRun(workoutName: self.workout.name))
        }
        await store.send(.destination(.presented(.resumeRun(.finish)))) {
            $0.destination = nil
            $0.runRestore = .resolved
        }
        await store.receive(.internal(.presentationFreed)) {
            $0.hasPendingMutationAlert = false
            $0.destination = .alert(.mutationFailed)
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
    }

    @Test
    func test_finish_resumeQuestionWithARequestWaiting_showsTheSheetAfterTheAlert() async throws {
        var state = freeVersion([workout])
        state.runRestore = .offered(try pausedRun(of: workout, at: now))
        state.destination = .resumeRun(.resumeRun(workoutName: workout.name))
        state.purchaseRequest = .browse
        let store = makeStore(state)

        await store.send(.destination(.presented(.resumeRun(.finish)))) {
            $0.destination = nil
            $0.runRestore = .resolved
        }
        await store.receive(.internal(.presentationFreed)) {
            $0.destination = self.sheet
            $0.purchaseRequest = nil
        }
    }

    @Test
    func test_sheetShown_startWaitingForPermission_isCancelledAndALateAnswerOpensNothing() async throws {
        var editor = WorkoutEditorFeature.State(viewing: workout)
        editor.isStarting = true
        var state = freeVersion([workout])
        state.path.append(.editor(editor))
        let editorID = try #require(state.path.ids.last)
        state.startGeneration = 1
        state.startIntent = AppFeature.StartIntent(generation: 1, editorID: editorID, workout: workout)
        let store = makeStore(state, notificationsEnabled: true)

        await store.send(.settings(.delegate(.fullVersionRequested(.buy)))) {
            $0.destination = self.sheet
            $0.startIntent = nil
            $0.startGeneration = 2
            $0.path[id: editorID, case: \.editor]?.isStarting = false
        }
        await store.send(.internal(.notificationPermissionAnswered(generation: 1, .authorized)))

        #expect(store.state.destination == sheet)
    }
}
