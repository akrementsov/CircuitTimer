@testable import SettingsFeature

import BackgroundNotifications
import CloudSync
import ComposableArchitecture
import Foundation
import Testing

@MainActor
struct SettingsNotificationTests {
    @Test
    func test_backgroundNotificationsToggled_off_persistsWithoutRequestingPermission() async {
        let store = withDependencies {
            $0.defaultAppStorage = UserDefaults.inMemory
        } operation: {
            TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
        }
        #expect(store.state.isBackgroundNotificationsOn)
        await store.send(.view(.backgroundNotificationsToggled(false))) {
            $0.$isBackgroundNotificationsOn.withLock { $0 = false }
            $0.notificationAccessGeneration = 1
        }
    }

    @Test
    func test_backgroundNotificationsToggled_on_readsCurrentAccessWithoutRequestingPermission() async {
        let defaults = UserDefaults.inMemory
        defaults.set(false, forKey: "signalBackgroundNotifications")
        let access = NotificationAccess(authorization: .denied, showsAlerts: false, playsSound: false)
        let store = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            TestStore(initialState: SettingsFeature.State()) { SettingsFeature() } withDependencies: {
                $0.backgroundNotifications.access = { access }
            }
        }
        await store.send(.view(.backgroundNotificationsToggled(true))) {
            $0.$isBackgroundNotificationsOn.withLock { $0 = true }
            $0.notificationAccessGeneration = 1
        }
        await store.receive(.internal(.notificationAccessLoaded(generation: 1, access))) {
            $0.notificationAccess = access
        }
        #expect(store.state.notificationFootnote == "settings.notifications.denied")
    }

    @Test
    func test_notificationAccessLoaded_oldGeneration_keepsLatestAccess() async {
        var state = SettingsFeature.State()
        state.notificationAccessGeneration = 2
        let store = TestStore(initialState: state) { SettingsFeature() }
        let denied = NotificationAccess(authorization: .denied, showsAlerts: false, playsSound: false)
        await store.send(.internal(.notificationAccessLoaded(generation: 1, denied)))
    }

    @Test
    func test_task_disabled_doesNotReadAccess() async {
        let defaults = UserDefaults.inMemory
        defaults.set(false, forKey: "signalBackgroundNotifications")
        let store = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            TestStore(initialState: SettingsFeature.State()) { SettingsFeature() } withDependencies: {
                $0.cloudSync = .previewValue
            }
        }
        await store.send(.view(.task))
        await store.send(.view(.appeared))
        await store.send(.view(.scenePhaseChanged(.active)))
    }

    @Test
    func test_scenePhaseChanged_enabled_readsOnlyOnActiveWithNewGeneration() async {
        let access = NotificationAccess(authorization: .authorized, showsAlerts: true, playsSound: true)
        let reads = LockIsolated(0)
        let store = withDependencies {
            $0.defaultAppStorage = UserDefaults.inMemory
        } operation: {
            TestStore(initialState: SettingsFeature.State()) { SettingsFeature() } withDependencies: {
                $0.backgroundNotifications.access = {
                    reads.withValue { $0 += 1 }
                    return access
                }
            }
        }
        await store.send(.view(.scenePhaseChanged(.inactive)))
        await store.send(.view(.scenePhaseChanged(.background)))
        #expect(reads.value == 0)
        await store.send(.view(.scenePhaseChanged(.active))) { $0.notificationAccessGeneration = 1 }
        await store.receive(.internal(.notificationAccessLoaded(generation: 1, access))) {
            $0.notificationAccess = access
        }
        #expect(reads.value == 1)
    }

    @Test
    func test_backgroundNotificationsToggled_off_discardsLateAccess() async {
        let store = withDependencies {
            $0.defaultAppStorage = UserDefaults.inMemory
        } operation: {
            var state = SettingsFeature.State()
            state.notificationAccess = .authorized
            state.notificationAccessGeneration = 1
            return TestStore(initialState: state) { SettingsFeature() }
        }
        await store.send(.view(.backgroundNotificationsToggled(false))) {
            $0.$isBackgroundNotificationsOn.withLock { $0 = false }
            $0.notificationAccess = nil
            $0.notificationAccessGeneration = 2
        }
        await store.send(.internal(.notificationAccessLoaded(generation: 1, .authorized)))
        #expect(store.state.notificationAccess == nil)
    }

    @Test
    func test_notificationFootnote_prioritizesPreferenceAndAccess() {
        var state = SettingsFeature.State()
        state.$isBackgroundNotificationsOn.withLock { $0 = false }
        #expect(state.notificationFootnote == "settings.notifications.off")
        state.$isBackgroundNotificationsOn.withLock { $0 = true }
        #expect(state.notificationFootnote == "settings.notifications.unknown")
        state.notificationAccess = NotificationAccess(authorization: .notDetermined, showsAlerts: false, playsSound: false)
        #expect(state.notificationFootnote == "settings.notifications.notAsked")
        state.notificationAccess = NotificationAccess(authorization: .denied, showsAlerts: false, playsSound: false)
        #expect(state.notificationFootnote == "settings.notifications.denied")
        state.notificationAccess = NotificationAccess(authorization: .authorized, showsAlerts: false, playsSound: true)
        #expect(state.notificationFootnote == "settings.notifications.alertsOff")
        state.notificationAccess = .authorized
        #expect(state.notificationFootnote == "settings.notifications.coverage")
    }

    @Test
    func test_appeared_enabled_readsCurrentAccessWithoutChangingPreference() async {
        let access = NotificationAccess(authorization: .denied, showsAlerts: false, playsSound: false)
        let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() } withDependencies: {
            $0.backgroundNotifications.access = { access }
        }
        await store.send(.view(.appeared)) { $0.notificationAccessGeneration = 1 }
        await store.receive(.internal(.notificationAccessLoaded(generation: 1, access))) {
            $0.notificationAccess = access
        }
        #expect(store.state.isBackgroundNotificationsOn)
        #expect(store.state.notificationFootnote == "settings.notifications.denied")
    }

    @Test
    func test_notificationAccess_latestReadFailed_clearsStalePermissionAndShowsUnknown() async {
        var state = SettingsFeature.State()
        state.notificationAccess = .authorized
        state.notificationAccessGeneration = 1
        let store = TestStore(initialState: state) { SettingsFeature() }
        await store.send(.internal(.notificationAccessLoaded(generation: 1, nil))) {
            $0.notificationAccess = nil
        }
        #expect(store.state.notificationFootnote == "settings.notifications.unknown")
    }

    @Test
    func test_openSettings_failed_showsManualPathAndRetry_successClearsFailure() async {
        let result = LockIsolated(false)
        let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() } withDependencies: {
            $0.backgroundNotifications.openSystemSettings = { result.value }
        }
        await store.send(.view(.openNotificationSettingsTapped))
        await store.receive(.internal(.notificationSettingsOpened(false))) { $0.openSettingsFailed = true }
        result.setValue(true)
        await store.send(.view(.openNotificationSettingsTapped))
        await store.receive(.internal(.notificationSettingsOpened(true))) { $0.openSettingsFailed = false }
    }

    @Test
    func test_openSettings_lateFirstResponseDoesNotReplaceSecondResult() async throws {
        let started = AsyncStream<(Int, CheckedContinuation<Bool, Never>)>.makeStream()
        let completed = AsyncStream<Int>.makeStream()
        let count = LockIsolated(0)
        let completions = LockIsolated<[(Int, Bool)]>([])
        let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() } withDependencies: {
            $0.backgroundNotifications.openSystemSettings = {
                let call = count.withValue { value in
                    value += 1
                    return value
                }
                let result = await withCheckedContinuation { continuation in
                    started.continuation.yield((call, continuation))
                }
                completions.withValue { $0.append((call, result)) }
                completed.continuation.yield(call)
                return result
            }
        }
        var starts = started.stream.makeAsyncIterator()
        var finishes = completed.stream.makeAsyncIterator()
        await store.send(.view(.openNotificationSettingsTapped))
        let first = try #require(await starts.next())
        #expect(first.0 == 1)
        await store.send(.view(.openNotificationSettingsTapped))
        let second = try #require(await starts.next())
        #expect(second.0 == 2)
        second.1.resume(returning: true)
        let secondFinished = await finishes.next()
        #expect(secondFinished == 2)
        await store.receive(.internal(.notificationSettingsOpened(true)))
        #expect(completions.value.map(\.0) == [2])
        first.1.resume(returning: false)
        let firstFinished = await finishes.next()
        #expect(firstFinished == 1)
        await store.finish()
        #expect(completions.value.map(\.0) == [2, 1])
        #expect(completions.value.map(\.1) == [true, false])
        #expect(!store.state.openSettingsFailed)
    }

}
