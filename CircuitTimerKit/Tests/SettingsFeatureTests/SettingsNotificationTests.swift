@testable import SettingsFeature

import BackgroundNotifications
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
            TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
        }
        await store.send(.view(.task))
        await store.send(.view(.appeared))
        await store.send(.view(.scenePhaseChanged(.active)))
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
}
