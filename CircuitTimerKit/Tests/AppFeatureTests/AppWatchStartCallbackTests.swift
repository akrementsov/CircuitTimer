@testable import AppFeature

import BackgroundNotifications
import ComposableArchitecture
import Foundation
import SwiftUI
import Testing
import WorkoutDomain
import WorkoutStorage

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppWatchStartCallbackTests {
    private let fixture = WatchStartFixture()

    enum Callback: CaseIterable, Sendable { case notificationRead, notificationAnswer, healthAnswer }

    @Test(arguments: Callback.allCases, [false, true])
    func test_permissionCallback_inactive_waitsForActiveWithinOriginalDeadline(callback: Callback, expired: Bool) async {
        let clock = TestClock<Duration>()
        var state = fixture.pending(clock, stage: callback == .healthAnswer ? .health : .notifications)
        state.isSceneActive = false
        let store = makeStore(state) { $0.continuousClock = clock; $0.timerSession.end = { _ in } }
        let action: AppFeature.Action = switch callback {
            case .notificationRead: .internal(.notificationAccessQueried(generation: 1, .authorized))
            case .notificationAnswer: .internal(.notificationPermissionAnswered(generation: 1, .authorized))
            case .healthAnswer: .internal(.healthPermissionAnswered(generation: 1, succeeded: true))
        }
        await store.send(action) {
            if callback == .healthAnswer { $0.healthAccess = .determined } else { $0.notificationAccess = .authorized }
            $0.startIntent?.stage = .awaitingActiveScene
        }
        #expect(store.state.destination == nil)
        await store.send(.view(.scenePhaseChanged(.background)))
        await clock.advance(by: .seconds(expired ? 30 : 29))
        await store.send(.view(.scenePhaseChanged(.active))) {
            $0.isSceneActive = true
            $0.startIntent = nil
            if expired { $0.startGeneration = 2 } else { $0.destination = .timer(self.fixture.timer) }
        }
        if !expired { await store.send(.destination(.dismiss)) { $0.destination = nil } }
        await store.finish()
    }

    enum Stale: CaseIterable, Sendable { case generation, stage, noIntent }

    @Test(arguments: Stale.allCases, [false, true])
    func test_accessRead_oldGenerationWrongStageOrNoIntent_isIgnored(reason: Stale, health: Bool) async {
        let clock = TestClock<Duration>()
        var state = fixture.pending(clock, stage: health ? .health : .notifications)
        if reason == .stage { state.startIntent?.stage = health ? .notifications : .health }
        if reason == .noIntent { state.startIntent = nil }
        let store = makeStore(state, healthAccess: nil) { $0.continuousClock = clock }
        let generation = reason == .generation ? 0 : 1
        let action: AppFeature.Action = health
            ? .internal(.healthAccessQueried(generation: generation, .notDetermined))
            : .internal(.notificationAccessQueried(generation: generation, nil))
        await store.send(action)
        #expect(store.state.startIntent == state.startIntent)
        #expect(store.state.healthAccess == nil)
        #expect(store.state.notificationAccess == nil)
        await store.finish()
    }

    @Test(arguments: [false, true])
    func test_accessRead_nilForInvalidCurrentIntent_cancelsBeforeFallback(health: Bool) async {
        let clock = TestClock<Duration>()
        var state = fixture.pending(clock, stage: health ? .health : .notifications)
        state.workouts = .loaded([])
        let store = makeStore(state, healthAccess: nil) { $0.continuousClock = clock }
        let action: AppFeature.Action = health
            ? .internal(.healthAccessQueried(generation: 1, nil))
            : .internal(.notificationAccessQueried(generation: 1, nil))
        await store.send(action) {
            $0.startIntent = nil
            $0.startGeneration = 2
        }
        #expect(store.state.destination == nil)
        await store.finish()
    }

    @Test(arguments: [AppFeature.StartIntent.Stage.admitting, .notifications, .health, .awaitingActiveScene])
    func test_reloadFailure_eachStage_cancelsAndCannotBeRevived(stage: AppFeature.StartIntent.Stage) async {
        let clock = TestClock<Duration>()
        var state = fixture.pending(clock, stage: stage)
        state.isReloading = true
        state.isHealthRequestOutstanding = true
        let store = makeStore(state, healthAccess: nil) { $0.continuousClock = clock }
        await store.send(.internal(.workoutsLoadingFailed)) {
            $0.isReloading = false
            $0.workouts = .failed
            $0.startIntent = nil
            $0.startGeneration = 2
        }
        await store.send(.internal(.watchStartAdmitted(generation: 1, true)))
        await store.send(.internal(.notificationAccessQueried(generation: 1, nil)))
        await store.send(.internal(.notificationPermissionAnswered(generation: 1, .authorized)))
        await store.send(.internal(.healthAccessQueried(generation: 1, .notDetermined)))
        await store.send(.internal(.healthPermissionAnswered(generation: 1, succeeded: true))) {
            $0.healthAccess = .determined
            $0.isHealthRequestOutstanding = false
        }
        await store.send(.internal(.workoutsLoaded(StoredWorkouts(workouts: [fixture.workout])))) {
            $0.workouts = .loaded([self.fixture.workout])
        }
        #expect(store.state.startIntent == nil)
        #expect(store.state.destination == nil)
        #expect(store.state.notificationAccess == nil)
        await store.finish()
    }

    @Test(arguments: [false, true])
    func test_healthSheet_lateSuccessOrFailure_onlySettlesCache(succeeded: Bool) async {
        let clock = TestClock<Duration>()
        var state = fixture.pending(clock)
        state.isHealthRequestOutstanding = true
        let store = makeStore(state, healthAccess: nil) { $0.continuousClock = clock }
        await store.send(.internal(.watchStartExpired(generation: 1))) {
            $0.startIntent = nil
            $0.startGeneration = 2
        }
        await store.send(.internal(.healthPermissionAnswered(generation: 1, succeeded: succeeded))) {
            $0.isHealthRequestOutstanding = false
            if succeeded { $0.healthAccess = .determined }
        }
        #expect(store.state.destination == nil)
        await store.finish()
    }

    @Test(arguments: [false, true])
    func test_notificationAnswer_atDeadlineOrAfterDeadline_neverStarts(timeoutFirst: Bool) async {
        let clock = TestClock<Duration>()
        let store = makeStore(fixture.pending(clock, stage: .notifications)) { $0.continuousClock = clock }
        await clock.advance(by: .seconds(30))
        if timeoutFirst {
            await store.send(.internal(.watchStartExpired(generation: 1))) {
                $0.startIntent = nil
                $0.startGeneration = 2
            }
        }
        if timeoutFirst {
            await store.send(.internal(.notificationPermissionAnswered(generation: 1, .authorized)))
        } else {
            await store.send(.internal(.notificationPermissionAnswered(generation: 1, .authorized))) {
                $0.notificationAccess = .authorized
                $0.startIntent = nil
                $0.startGeneration = 2
            }
        }
        if !timeoutFirst { await store.send(.internal(.watchStartExpired(generation: 1))) }
        #expect(store.state.destination == nil)
        await store.finish()
    }

    @Test(arguments: [false, true])
    func test_notificationRead_afterDeadline_startsNeitherSheetNorAlert(nilAccess: Bool) async {
        let clock = TestClock<Duration>()
        let store = makeStore(fixture.pending(clock, stage: .notifications)) { $0.continuousClock = clock }
        await clock.advance(by: .seconds(30))
        let access: NotificationAccess? = nilAccess ? nil : .init(authorization: .notDetermined, showsAlerts: false, playsSound: false)
        await store.send(.internal(.notificationAccessQueried(generation: 1, access))) {
            $0.startIntent = nil
            $0.startGeneration = 2
        }
        #expect(store.state.destination == nil)
        await store.finish()
    }
}
