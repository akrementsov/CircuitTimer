@testable import SettingsFeature

import ComposableArchitecture
import Foundation
import Testing
import TimerPreferences

@MainActor
struct TimerPreferencesTests {
    @Test
    func test_backgroundNotifications_defaultOn_persistsIndependently() async {
        let defaults = UserDefaults.inMemory
        let store = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
        }
        #expect(store.state.isBackgroundNotificationsOn)
        await store.send(.view(.backgroundNotificationsToggled(false))) {
            $0.$isBackgroundNotificationsOn.withLock { $0 = false }
        }
        let reloaded = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: { SettingsFeature.State() }
        #expect(!reloaded.isBackgroundNotificationsOn)
        #expect(reloaded.isSoundOn && reloaded.isVibrationOn && reloaded.isSpeechOn && reloaded.isKeepScreenOn)
        expectStored(false, forKey: "signalBackgroundNotifications", in: defaults, shared: store.state.isBackgroundNotificationsOn)
    }

    @Test
    func test_backgroundNotificationsToggled_on_persistsWithoutEffects() async {
        let defaults = UserDefaults.inMemory
        defaults.set(false, forKey: "signalBackgroundNotifications")
        let store = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
        }
        await store.send(.view(.backgroundNotificationsToggled(true))) {
            $0.$isBackgroundNotificationsOn.withLock { $0 = true }
        }
        expectStored(true, forKey: "signalBackgroundNotifications", in: defaults, shared: store.state.isBackgroundNotificationsOn)
    }

    @Test
    func test_keepScreenOnToggled_disabled_persistsWithoutChangingSignals() async {
        let defaults = UserDefaults.inMemory
        let store = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
        }
        #expect(store.state.isKeepScreenOn)
        await store.send(.view(.keepScreenOnToggled(false))) { $0.$isKeepScreenOn.withLock { $0 = false } }
        let reloaded = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: { SettingsFeature.State() }
        #expect(!reloaded.isKeepScreenOn)
        #expect(reloaded.isSoundOn && reloaded.isVibrationOn && reloaded.isSpeechOn)
        expectStored(false, forKey: "timerKeepScreenOn", in: defaults, shared: store.state.isKeepScreenOn)
        await store.send(.view(.keepScreenOnToggled(true))) { $0.$isKeepScreenOn.withLock { $0 = true } }
    }

    @Test
    func test_toggle_eachSignal_persistsIndependently() async {
        let defaults = UserDefaults.inMemory
        let store = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
        }
        #expect(store.state.isSoundOn && store.state.isVibrationOn && store.state.isSpeechOn)
        await store.send(.view(.soundToggled(false))) { $0.$isSoundOn.withLock { $0 = false } }
        await store.send(.view(.vibrationToggled(false))) { $0.$isVibrationOn.withLock { $0 = false } }
        await store.send(.view(.speechToggled(false))) { $0.$isSpeechOn.withLock { $0 = false } }
        let reloaded = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: { SettingsFeature.State() }
        #expect(!reloaded.isSoundOn && !reloaded.isVibrationOn && !reloaded.isSpeechOn)
        expectStored(false, forKey: "signalSound", in: defaults, shared: store.state.isSoundOn)
        expectStored(false, forKey: "signalVibration", in: defaults, shared: store.state.isVibrationOn)
        expectStored(false, forKey: "signalSpokenStageNames", in: defaults, shared: store.state.isSpeechOn)
        await store.send(.view(.soundToggled(true))) { $0.$isSoundOn.withLock { $0 = true } }
        #expect(!store.state.isVibrationOn && !store.state.isSpeechOn)
    }

    /// Checks what the suite holds for `key`. A mismatch also reports what the store's shared state holds and every
    /// preference in the suite, which tells a write that never reached the suite from a suite that another write
    /// changed.
    private func expectStored(
        _ expected: Bool,
        forKey key: String,
        in defaults: UserDefaults,
        shared: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let preferences = defaults.dictionaryRepresentation()
            .filter { $0.key.hasPrefix("signal") || $0.key.hasPrefix("timer") || $0.key == "iCloudSync" }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        #expect(
            defaults.object(forKey: key) as? Bool == expected,
            "\(key): shared state holds \(shared); the suite holds \(preferences.joined(separator: ", "))",
            sourceLocation: sourceLocation
        )
    }
}
