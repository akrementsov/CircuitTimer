@testable import AppFeature
@testable import WorkoutEditorFeature
@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import PurchaseFeature
import Purchases
import Testing
import TestSupport
import WatchLink
import WorkoutDomain
import WorkoutStorage

/// The watch app is part of the full version: what the app tells the watch link when the status changes, the open
/// timer that follows it in place, and the Starts it refuses or cancels.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppFeatureWatchAccessTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let workout = makeWorkout(1)

    private var request: WatchStartRequest {
        WatchStartRequest(id: 7, workoutID: workout.id, scheduleFingerprint: WorkoutSchedule(workout: workout).fingerprint)
    }

    /// A new status publishes the access it allows with a revision of its own; the same status again publishes
    /// nothing and takes no revision. A known status never returns to `.unknown`.
    @Test(arguments: [
        (FullVersionStatus.unknown, FullVersionStatus.full, WatchAccess?.some(.granted)),
        (.unknown, .free, .locked),
        (.full, .free, .locked),
        (.free, .full, .granted),
        (.full, .full, nil),
        (.free, .free, nil),
    ])
    func test_fullVersionChanged_publishesTheAccessOnlyWhenTheStatusChanges(
        from: FullVersionStatus,
        to status: FullVersionStatus,
        access: WatchAccess?
    ) async {
        let watch = WatchPublications()
        let store = makeStore(freeVersion([workout], status: from), watch: watch)

        if access == nil {
            await store.send(.internal(.fullVersionChanged(status)))
        } else {
            await store.send(.internal(.fullVersionChanged(status))) {
                $0.fullVersion = status
                $0.settings.fullVersion = status
            }
        }
        await store.finish()

        #expect(watch.accesses.value == access.map { [WatchAccessPublication(revision: 1, access: $0)] } ?? [])
        #expect(watch.revisions.value == (access == nil ? 0 : 1))
    }

    /// The timer follows the status in place: the flag changes, the watch's subscription it started before the change
    /// survives and still delivers, and the run on the iPhone goes on after a refund. The clock has not started, so the
    /// answer carries no run whatever the flag; what the flag does to an answer is pinned in `TimerWatchAccessTests`.
    @Test(arguments: [
        (FullVersionStatus.full, FullVersionStatus.free),
        (.free, .full),
        (.unknown, .full),
    ])
    func test_fullVersionChanged_openTimer_setsWatchControlInPlace_andKeepsItsEffects(
        from: FullVersionStatus,
        to status: FullVersionStatus
    ) async throws {
        var state = freeVersion([workout], status: from)
        state.destination = .timer(timerState(for: workout, allowsWatchControl: from == .full))
        let requests = AsyncStream.makeStream(of: WatchControlRequest.self)
        let answers = Observed<[Int]>([])
        let store = makeStore(state) {
            $0.timerSession.end = { _ in }
            $0.watchCompanion.controlRequests = { _ in requests.stream }
            $0.watchCompanion.refreshHandled = { _, requestID, _ in answers.withValue { $0.append(requestID) } }
        }
        await store.send(.destination(.presented(.timer(.view(.watchTask))))) {
            $0.$destination[case: \.timer]?.activityControls = WorkoutTimerFeature.ActivityControlState()
        }

        await store.send(.internal(.fullVersionChanged(status))) {
            $0.fullVersion = status
            $0.settings.fullVersion = status
            $0.$destination[case: \.timer]?.allowsWatchControl = status == .full
        }

        requests.continuation.yield(WatchControlRequest(id: 4, kind: .refresh))
        await store.receive(.destination(.presented(.timer(.internal(.watchRequestReceived(
            WatchControlRequest(id: 4, kind: .refresh)
        ))))))
        await answers.wait { !$0.isEmpty }
        #expect(answers.value == [4])
        requests.continuation.finish()
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
    }

    enum Shown: CaseIterable, Sendable {
        case nothing
        case purchase
        case alert
    }

    /// Without a timer nothing but the status changes, and nothing reports a destination of the wrong case.
    @Test(arguments: Shown.allCases)
    func test_fullVersionChanged_noTimer_changesOnlyTheStatus(shown: Shown) async {
        var state = freeVersion([workout])
        switch shown {
            case .nothing:
                break
            case .purchase:
                state.destination = .purchase(PurchaseFeature.State(entry: .browse))
            case .alert:
                state.destination = .alert(.mutationFailed)
        }
        let watch = WatchPublications()
        let store = makeStore(state, watch: watch)

        await store.send(.internal(.fullVersionChanged(.full))) {
            $0.fullVersion = .full
            $0.settings.fullVersion = .full
        }
        await store.finish()

        #expect(watch.accesses.value == [WatchAccessPublication(revision: 1, access: .granted)])
    }

    /// Without the full version a Start from the watch is answered at once and starts nothing: no intent, no timer,
    /// no permission request.
    @Test(arguments: [
        (FullVersionStatus.free, WatchStartResult.listUnavailable),
        (.unknown, .openPhoneApp),
    ])
    func test_watchStartRequested_withoutTheFullVersion_isRefusedBeforeAnyPermission(
        status: FullVersionStatus,
        expected: WatchStartResult
    ) async {
        var state = freeVersion([workout], status: status)
        state.hasScenePhase = true
        let answers = LockIsolated<[WatchStartResult]>([])
        let store = makeStore(state, notificationsEnabled: true, healthAccess: nil) {
            $0.watchCompanion.startHandled = { id, result in
                #expect(id == 7)
                answers.withValue { $0.append(result) }
                return true
            }
            $0.backgroundNotifications.access = {
                Issue.record("A refused Start read notification access")
                return .authorized
            }
            $0.workoutHealth.access = {
                Issue.record("A refused Start read Health access")
                return .determined
            }
        }

        await store.send(.internal(.watchStartRequested(request)))
        await store.finish()

        #expect(answers.value == [expected])
        #expect(store.state.startIntent == nil)
        #expect(store.state.destination == nil)
    }

    /// A Start under `.free` or `.unknown` opens a timer the watch does not control, from the workout's screen or as
    /// Continue of a saved run.
    @Test(arguments: [FullVersionStatus.free, .unknown], [false, true])
    func test_start_withoutTheFullVersion_opensATimerTheWatchDoesNotControl(
        status: FullVersionStatus,
        continuesSavedRun: Bool
    ) async throws {
        var state = freeVersion([workout], status: status)
        let saved = try pausedRun(of: workout, at: now)
        if continuesSavedRun {
            state.runRestore = .offered(saved)
            state.destination = .resumeRun(.resumeRun(workoutName: workout.name))
        } else {
            state.path.append(.editor(WorkoutEditorFeature.State(viewing: workout)))
        }
        let editorID = state.path.ids.last
        let store = makeStore(state) {
            $0.date = .constant(now)
            $0.timerSession.end = { _ in }
        }

        if continuesSavedRun {
            let run = try WorkoutRun(schedule: WorkoutSchedule(workout: workout), restoring: saved.record, at: now)
            await store.send(.destination(.presented(.resumeRun(.resume)))) { $0.destination = nil }
            await store.receive(.internal(.resumeRunConfirmed)) {
                $0.runRestore = .presenting(saved)
                $0.destination = .timer(restoredTimerState(for: self.workout, restoring: run, at: self.now, allowsWatchControl: false))
            }
        } else {
            let id = try #require(editorID)
            await store.send(.path(.element(id: id, action: .editor(.delegate(.startRequested(workout)))))) {
                $0.destination = .timer(timerState(for: self.workout, allowsWatchControl: false))
            }
        }
        #expect(store.state.destination?[case: \.timer]?.allowsWatchControl == false)
        await store.send(.view(.timerCoverAppeared)) {
            $0.path = StackState()
            $0.isTimerCoverUp = true
            if continuesSavedRun { $0.runRestore = .resolved }
        }
        await store.send(.destination(.dismiss)) {
            $0.destination = nil
            $0.isTimerCoverUp = false
        }
        await store.finish()
    }

    /// A refund cancels a Start from the watch already accepted and answered but not yet presented: the pass that
    /// learns of it cancels the intent, the watch is not answered again, and a late permission answer opens nothing.
    @Test
    func test_fullVersionChanged_free_cancelsAnAcceptedWatchStart() async {
        let clock = TestClock<Duration>()
        let fixture = WatchStartFixture()
        let watch = WatchPublications()
        let store = makeStore(fixture.pending(clock, stage: .notifications), notificationsEnabled: true, watch: watch) {
            $0.continuousClock = clock
            $0.watchCompanion.startHandled = { _, result in
                Issue.record("The watch was answered again: \(result)")
                return false
            }
        }

        await store.send(.internal(.fullVersionChanged(.free))) {
            $0.fullVersion = .free
            $0.settings.fullVersion = .free
            $0.startIntent = nil
            $0.startGeneration = 2
        }
        await store.send(.internal(.notificationPermissionAnswered(generation: 1, .authorized)))
        await store.finish()

        #expect(store.state.destination == nil)
        #expect(watch.accesses.value == [WatchAccessPublication(revision: 1, access: .locked)])
    }

    /// The same refund leaves a Start from the workout's screen alone: it opens a timer the watch does not control.
    @Test
    func test_fullVersionChanged_free_leavesAnEditorStartToOpenItsTimer() async throws {
        var state = loaded([workout])
        state.runRestore = .resolved
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: workout)))
        let editorID = try #require(state.path.ids.last)
        state.startGeneration = 1
        state.startIntent = AppFeature.StartIntent(generation: 1, origin: .editor(editorID), workout: workout)
        let store = makeStore(state, notificationsEnabled: true) { $0.timerSession.end = { _ in } }

        await store.send(.internal(.fullVersionChanged(.free))) {
            $0.fullVersion = .free
            $0.settings.fullVersion = .free
        }
        await store.send(.internal(.notificationPermissionAnswered(generation: 1, .authorized))) {
            $0.notificationAccess = .authorized
            $0.startIntent = nil
            $0.destination = .timer(timerState(for: self.workout, allowsWatchControl: false))
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
    }
}
