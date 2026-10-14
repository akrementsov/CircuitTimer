@testable import SettingsFeature

import ComposableArchitecture
import Foundation
import Testing
import TimerPreferences

@MainActor
struct TimerPreferencesTests {
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
        #expect(defaults.object(forKey: "timerKeepScreenOn") as? Bool == false)
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
        #expect(defaults.object(forKey: "signalSound") as? Bool == false)
        #expect(defaults.object(forKey: "signalVibration") as? Bool == false)
        #expect(defaults.object(forKey: "signalSpokenStageNames") as? Bool == false)
        await store.send(.view(.soundToggled(true))) { $0.$isSoundOn.withLock { $0 = true } }
        #expect(!store.state.isVibrationOn && !store.state.isSpeechOn)
    }
}
