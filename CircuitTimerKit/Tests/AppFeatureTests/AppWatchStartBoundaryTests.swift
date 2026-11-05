@testable import AppFeature
@testable import WorkoutEditorFeature

import BackgroundNotifications
import ComposableArchitecture
import Foundation
import Testing
import WatchLink
import WorkoutDomain
import WorkoutHealth

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppWatchStartBoundaryTests {
    private let fixture = WatchStartFixture()

    enum Busy: CaseIterable, Sendable {
        case destination, purchase, mutationAlert, intent, restoreIdle, mutations, needsReload, deferred
        case editorNew, editorAlert, editorSaving, editorStarting, firstLoading
    }

    @Test(arguments: Busy.allCases)
    func test_watchRequest_busyGuard_answersOnceWithoutReadingPermissionsOrChangingDraft(reason: Busy) async throws {
        let clock = TestClock<Duration>()
        var state = fixture.ready()
        switch reason {
            case .destination: state.destination = .alert(.mutationFailed)
            case .purchase: state.purchaseRequest = .browse
            case .mutationAlert: state.hasPendingMutationAlert = true
            case .intent: state = fixture.pending(clock)
            case .restoreIdle: state.runRestore = .idle
            case .mutations: state.pendingMutations = [.delete(makeWorkout(2).id)]
            case .needsReload: state.needsReload = true
            case .deferred: state.deferredScreen = .create
            case .firstLoading:
                state.workouts = .loading
                state.runRestore = .reading
            case .editorNew, .editorAlert, .editorSaving, .editorStarting:
                var editor = WorkoutEditorFeature.State(viewing: fixture.workout)
                switch reason {
                    case .editorNew:
                        editor = WorkoutEditorFeature.State(
                            newWorkoutID: UUID(fixture: 90),
                            warmUpStageID: UUID(fixture: 91),
                            trainingStageID: UUID(fixture: 92),
                            coolDownStageID: UUID(fixture: 93)
                        )
                    case .editorAlert: editor.destination = .saveFailedAlert(.saveFailed)
                    case .editorSaving: editor.isSaving = true
                    case .editorStarting: editor.isStarting = true
                    default: break
                }
                state.path.append(.editor(editor))
        }
        let answers = LockIsolated<[WatchStartResult]>([])
        let originalPath = state.path
        let store = makeStore(state, notificationsEnabled: true, healthAccess: nil) {
            $0.continuousClock = clock
            $0.backgroundNotifications.access = { Issue.record("Busy Start read notifications"); return .authorized }
            $0.workoutHealth.access = { Issue.record("Busy Start read Health"); return .determined }
            $0.watchCompanion.startHandled = { id, result in
                #expect(id == 7)
                answers.withValue { $0.append(result) }
                return true
            }
        }
        if reason == .purchase {
            await store.send(.internal(.watchStartRequested(fixture.request))) { $0.purchaseRequest = nil }
        } else {
            await store.send(.internal(.watchStartRequested(fixture.request)))
        }
        await store.finish()
        #expect(answers.value == [.busy])
        #expect(store.state.path == originalPath)
        #expect(store.state.startIntent == state.startIntent)
    }

    @Test(arguments: [false, true])
    func test_watchRequest_guardPriority_sceneThenBusyBeforeUnavailableList(active: Bool) async {
        var state = fixture.ready()
        state.isSceneActive = active
        state.pendingMutations = [.delete(fixture.workout.id)]
        state.workouts = .failed
        let answers = LockIsolated<[WatchStartResult]>([])
        let store = makeStore(state) {
            $0.watchCompanion.startHandled = { _, result in answers.withValue { $0.append(result) }; return true }
        }
        await store.send(.internal(.watchStartRequested(fixture.request)))
        await store.finish()
        #expect(answers.value == [active ? .busy : .openPhoneApp])
    }

    @Test(arguments: [
        (false, HealthAccess?.none, false, false, true),
        (false, .some(.unavailable), false, false, false),
        (false, .some(.determined), false, false, false),
        (false, .some(.notDetermined), false, false, true),
        (true, .none, false, false, true),
        (true, .some(.unavailable), false, false, true),
        (true, .some(.determined), false, false, true),
        (true, .some(.notDetermined), false, false, true),
        (true, .some(.unavailable), false, true, false),
        (true, .none, true, true, false),
        (true, .none, true, false, true),
    ])
    func test_admission_asksOnPhone_reflectsOnlyPermissionsStillNeeded(
        notifications: Bool, health: HealthAccess?, outstanding: Bool, knownNotifications: Bool, expected: Bool
    ) async {
        let clock = TestClock<Duration>()
        let held = Gate()
        let answers = LockIsolated<[WatchStartResult]>([])
        let defaults = UserDefaults.inMemory
        defaults.set(notifications, forKey: "signalBackgroundNotifications")
        let store = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            var state = fixture.ready()
            state.isHealthRequestOutstanding = outstanding
            if knownNotifications { state.notificationAccess = .authorized }
            return makeStore(state, notificationsEnabled: notifications, healthAccess: health) {
                $0.defaultAppStorage = defaults
                $0.continuousClock = clock
                $0.watchCompanion.startHandled = { _, result in
                    answers.withValue { $0.append(result) }
                    await held.wait()
                    return false
                }
            }
        }
        #expect(store.state.isBackgroundNotificationsOn == notifications)
        await store.send(.internal(.watchStartRequested(fixture.request))) {
            $0.startGeneration = 1
            $0.startIntent = self.fixture.pending(clock, stage: .admitting).startIntent
        }
        held.open()
        await store.receive(.internal(.watchStartAdmitted(generation: 1, false))) {
            $0.startIntent = nil
            $0.startGeneration = 2
        }
        #expect(answers.value == [.accepted(asksOnPhone: expected)])
        await clock.advance(by: .seconds(31))
        await store.finish()
    }

    @Test(arguments: [false, true])
    func test_watchIntent_tabSwitch_preservesReadOnlyEditorAndIntent(withEditor: Bool) async {
        let clock = TestClock<Duration>()
        var state = fixture.pending(clock)
        if withEditor { state.path.append(.editor(WorkoutEditorFeature.State(viewing: fixture.workout))) }
        let store = makeStore(state) { $0.continuousClock = clock }
        await store.send(.view(.tabSelected(.settings))) { $0.selectedTab = .settings }
        await store.send(.view(.tabSelected(.workouts))) { $0.selectedTab = .workouts }
        #expect(store.state.startIntent == state.startIntent)
        #expect(store.state.path == state.path)
        await store.finish()
    }

    @Test(arguments: [false, true])
    func test_watchIntent_missingOrForeignClockReading_failsClosed(foreign: Bool) async {
        let clock = TestClock<Duration>()
        var state = fixture.pending(clock)
        state.startIntent?.acceptedAt = foreign ? MonotonicInstant(now: ContinuousClock()) : nil
        let store = makeStore(state) { $0.continuousClock = clock }
        await store.send(.view(.scenePhaseChanged(.inactive))) {
            $0.isSceneActive = false
            $0.startIntent = nil
            $0.startGeneration = 2
        }
        #expect(store.state.destination == nil)
        await store.finish()
    }

    @Test
    func test_watchAdmission_obsoleteOrWrongStage_doesNotAdvanceCurrentIntent() async {
        let clock = TestClock<Duration>()
        let state = fixture.pending(clock)
        let store = makeStore(state) { $0.continuousClock = clock }
        await store.send(.internal(.watchStartAdmitted(generation: 0, true)))
        await store.send(.internal(.watchStartAdmitted(generation: 1, true)))
        await store.send(.internal(.watchStartExpired(generation: 0)))
        #expect(store.state.startIntent == state.startIntent)
        await store.finish()
    }
}
