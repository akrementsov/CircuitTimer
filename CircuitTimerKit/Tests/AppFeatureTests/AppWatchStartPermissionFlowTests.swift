@testable import AppFeature

import BackgroundNotifications
import ComposableArchitecture
import Foundation
import SwiftUI
import Testing
import WorkoutDomain

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppWatchStartPermissionFlowTests {
    private let fixture = WatchStartFixture()
    private let undetermined = NotificationAccess(authorization: .notDetermined, showsAlerts: false, playsSound: false)
    private struct PermissionFailure: Error {}

    @Test
    func test_admittedWatchStart_requestsNotificationsThenHealthBeforeTimer() async {
        let clock = TestClock<Duration>()
        let notificationSheet = Gate()
        let healthSheet = Gate()
        let calls = LockIsolated<[String]>([])
        let store = makeStore(fixture.pending(clock, stage: .admitting), notificationsEnabled: true, healthAccess: nil) {
            $0.continuousClock = clock
            $0.timerSession.end = { _ in }
            $0.backgroundNotifications.access = { calls.withValue { $0.append("notification read") }; return undetermined }
            $0.backgroundNotifications.requestAuthorization = {
                calls.withValue { $0.append("notification sheet") }
                await notificationSheet.wait()
                return .authorized
            }
            $0.workoutHealth.access = { calls.withValue { $0.append("health read") }; return .notDetermined }
            $0.workoutHealth.requestAuthorization = {
                calls.withValue { $0.append("health sheet") }
                await healthSheet.wait()
            }
        }
        await store.send(.internal(.watchStartAdmitted(generation: 1, true))) { $0.startIntent?.stage = .notifications }
        await store.receive(.internal(.notificationAccessQueried(generation: 1, undetermined))) {
            $0.startIntent?.isAwaitingAuthorization = true
        }
        #expect(store.state.destination == nil)
        notificationSheet.open()
        await store.receive(.internal(.notificationPermissionAnswered(generation: 1, .authorized))) {
            $0.notificationAccess = .authorized
            $0.startIntent?.stage = .health
        }
        await store.receive(.internal(.healthAccessQueried(generation: 1, .notDetermined))) {
            $0.healthAccess = .notDetermined
            $0.isHealthRequestOutstanding = true
        }
        healthSheet.open()
        await store.receive(.internal(.healthPermissionAnswered(generation: 1, succeeded: true))) {
            $0.healthAccess = .determined
            $0.isHealthRequestOutstanding = false
            $0.startIntent = nil
            $0.destination = .timer(self.fixture.timer)
        }
        #expect(calls.value == ["notification read", "notification sheet", "health read", "health sheet"])
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
    }

    @Test(arguments: [false, true], [false, true])
    func test_notificationRead_nilAccess_showsAlertAndChoiceContinuesUnderSceneGuard(wait: Bool, active: Bool) async {
        let clock = TestClock<Duration>()
        var state = fixture.pending(clock, stage: .notifications)
        state.isSceneActive = active
        let store = makeStore(state) {
            $0.continuousClock = clock
            $0.timerSession.end = { _ in }
            $0.backgroundNotifications.access = { .authorized }
        }
        await store.send(.internal(.notificationAccessQueried(generation: 1, nil))) {
            $0.destination = .permissionStalled(.permissionStalled)
        }
        #expect(store.state.startIntent == state.startIntent)
        await store.send(.destination(.presented(.permissionStalled(wait ? .wait : .startNow)))) { $0.destination = nil }
        if wait {
            await store.receive(.internal(.notificationPermissionWait))
            await store.receive(.internal(.notificationAccessQueried(generation: 1, .authorized))) {
                $0.notificationAccess = .authorized
                if active {
                    $0.startIntent = nil
                    $0.destination = .timer(self.fixture.timer)
                } else {
                    $0.startIntent?.stage = .awaitingActiveScene
                }
            }
        } else {
            await store.receive(.internal(.startIntentConfirmed(generation: 1))) {
                if active {
                    $0.startIntent = nil
                    $0.destination = .timer(self.fixture.timer)
                } else {
                    $0.startIntent?.stage = .awaitingActiveScene
                }
            }
        }
        if active { await store.send(.destination(.dismiss)) { $0.destination = nil } }
        await store.finish()
    }

    @Test
    func test_notificationAuthorization_error_deliversNilAndContinuesImmediately() async {
        let clock = TestClock<Duration>()
        let store = makeStore(fixture.pending(clock, stage: .notifications)) {
            $0.continuousClock = clock
            $0.timerSession.end = { _ in }
            $0.backgroundNotifications.requestAuthorization = { throw PermissionFailure() }
        }
        await store.send(.internal(.notificationAccessQueried(generation: 1, undetermined))) {
            $0.startIntent?.isAwaitingAuthorization = true
        }
        await store.receive(.internal(.notificationPermissionAnswered(generation: 1, nil))) {
            $0.startIntent = nil
            $0.destination = .timer(self.fixture.timer)
        }
        #expect(store.state.notificationAccess == nil)
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await clock.advance(by: .seconds(31))
        await store.finish()
    }

    @Test(arguments: [ScenePhase.inactive, .background])
    func test_notificationAuthorization_inactiveClientRequest_isNotRepeatedOnActive(phase: ScenePhase) async {
        let clock = TestClock<Duration>()
        let sheet = Gate()
        let requests = LockIsolated(0)
        let store = makeStore(fixture.pending(clock, stage: .notifications)) {
            $0.continuousClock = clock
            $0.timerSession.end = { _ in }
            $0.backgroundNotifications.requestAuthorization = {
                requests.withValue { $0 += 1 }
                await sheet.wait()
                return .authorized
            }
        }
        await store.send(.view(.scenePhaseChanged(phase))) { $0.isSceneActive = false }
        await store.send(.internal(.notificationAccessQueried(generation: 1, undetermined))) {
            $0.startIntent?.isAwaitingAuthorization = true
        }
        await clock.advance(by: .seconds(11))
        #expect(store.state.destination == nil)
        await store.send(.view(.scenePhaseChanged(.active))) { $0.isSceneActive = true }
        await clock.advance(by: .seconds(10))
        await store.receive(.internal(.notificationPermissionStalled(generation: 1))) {
            $0.destination = .permissionStalled(.permissionStalled)
        }
        sheet.open()
        await store.receive(.internal(.notificationPermissionAnswered(generation: 1, .authorized))) {
            $0.notificationAccess = .authorized
            $0.destination = nil
        }
        await store.receive(.internal(.startIntentConfirmed(generation: 1))) {
            $0.startIntent = nil
            $0.destination = .timer(self.fixture.timer)
        }
        #expect(requests.value == 1)
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
    }

    @Test(arguments: [ScenePhase.inactive, .background])
    func test_healthRead_inactive_readsButAuthorizationWaitsForActive(phase: ScenePhase) async {
        let clock = TestClock<Duration>()
        let sheet = Gate()
        let requests = LockIsolated(0)
        let store = makeStore(fixture.pending(clock, stage: .admitting), healthAccess: nil) {
            $0.continuousClock = clock
            $0.timerSession.end = { _ in }
            $0.workoutHealth.access = { .notDetermined }
            $0.workoutHealth.requestAuthorization = { requests.withValue { $0 += 1 }; await sheet.wait() }
        }
        await store.send(.view(.scenePhaseChanged(phase))) { $0.isSceneActive = false }
        await store.send(.internal(.watchStartAdmitted(generation: 1, true))) { $0.startIntent?.stage = .health }
        await store.receive(.internal(.healthAccessQueried(generation: 1, .notDetermined))) { $0.healthAccess = .notDetermined }
        #expect(requests.value == 0)
        await clock.advance(by: .seconds(20))
        await store.send(.view(.scenePhaseChanged(.active))) {
            $0.isSceneActive = true
            $0.isHealthRequestOutstanding = true
        }
        sheet.open()
        await store.receive(.internal(.healthPermissionAnswered(generation: 1, succeeded: true))) {
            $0.isHealthRequestOutstanding = false
            $0.healthAccess = .determined
            $0.startIntent = nil
            $0.destination = .timer(self.fixture.timer)
        }
        #expect(requests.value == 1)
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
    }

    @Test
    func test_takeover_skipsHealthAfterNotifications_evenWhileOldSheetIsOutstanding() async {
        let clock = TestClock<Duration>()
        var state = fixture.pending(clock)
        state.startIntent?.hasStalled = true
        state.isHealthRequestOutstanding = true
        let store = makeStore(state, notificationsEnabled: true, healthAccess: nil) {
            $0.continuousClock = clock
            $0.timerSession.end = { _ in }
            $0.backgroundNotifications.access = { .authorized }
            $0.workoutHealth.access = { Issue.record("Takeover read Health again"); return .determined }
            $0.watchCompanion.startHandled = { _, result in
                #expect(result == .accepted(asksOnPhone: true))
                return true
            }
        }
        await store.send(.internal(.watchStartRequested(fixture.request))) {
            $0.startGeneration = 3
            $0.startIntent = .init(
                generation: 3,
                origin: .watch(requestID: 7),
                workout: self.fixture.workout,
                stage: .admitting,
                skipsHealth: true,
                acceptedAt: MonotonicInstant(now: clock)
            )
        }
        await store.receive(.internal(.watchStartAdmitted(generation: 3, true))) { $0.startIntent?.stage = .notifications }
        await store.receive(.internal(.notificationAccessQueried(generation: 3, .authorized))) {
            $0.notificationAccess = .authorized
            $0.startIntent = nil
            $0.destination = .timer(self.fixture.timer)
        }
        #expect(store.state.isHealthRequestOutstanding)
        await store.send(.internal(.healthPermissionAnswered(generation: 1, succeeded: true))) {
            $0.healthAccess = .determined
            $0.isHealthRequestOutstanding = false
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await clock.advance(by: .seconds(31))
        await store.finish()
    }

    @Test
    func test_healthStalled_lateNotDeterminedAndSceneReturn_doNotAskAgain() async {
        let clock = TestClock<Duration>()
        let requests = LockIsolated(0)
        let store = makeStore(fixture.pending(clock), healthAccess: nil) {
            $0.continuousClock = clock
            $0.workoutHealth.requestAuthorization = { requests.withValue { $0 += 1 } }
        }
        await store.send(.internal(.healthStalled(generation: 1))) { $0.startIntent?.hasStalled = true }
        await store.send(.internal(.healthAccessQueried(generation: 1, .notDetermined))) { $0.healthAccess = .notDetermined }
        await store.send(.view(.scenePhaseChanged(.inactive))) { $0.isSceneActive = false }
        await store.send(.view(.scenePhaseChanged(.active))) { $0.isSceneActive = true }
        await clock.advance(by: .seconds(11))
        #expect(requests.value == 0)
        #expect(store.state.startIntent?.hasStalled == true)
        #expect(store.state.destination == nil)
        await store.finish()
    }

}
