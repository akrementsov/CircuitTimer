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
        let trace = TimerPreferenceTrace(defaults, label: #function)
        let store = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
        }
        #expect(store.state.isBackgroundNotificationsOn)
        trace.mark("before send 1")
        await store.send(.view(.backgroundNotificationsToggled(false))) {
            $0.$isBackgroundNotificationsOn.withLock { $0 = false }
        }
        let reloaded = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: { SettingsFeature.State() }
        #expect(!reloaded.isBackgroundNotificationsOn)
        #expect(reloaded.isSoundOn && reloaded.isVibrationOn && reloaded.isSpeechOn && reloaded.isKeepScreenOn)
        expectStored(
            false,
            forKey: "signalBackgroundNotifications",
            in: defaults,
            shared: store.state.isBackgroundNotificationsOn,
            trace: trace
        )
    }

    @Test
    func test_backgroundNotificationsToggled_on_persistsWithoutEffects() async {
        let defaults = UserDefaults.inMemory
        let trace = TimerPreferenceTrace(defaults, label: #function)
        defaults.set(false, forKey: "signalBackgroundNotifications")
        let store = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
        }
        trace.mark("before send 2")
        await store.send(.view(.backgroundNotificationsToggled(true))) {
            $0.$isBackgroundNotificationsOn.withLock { $0 = true }
        }
        expectStored(
            true,
            forKey: "signalBackgroundNotifications",
            in: defaults,
            shared: store.state.isBackgroundNotificationsOn,
            trace: trace
        )
    }

    @Test
    func test_keepScreenOnToggled_disabled_persistsWithoutChangingSignals() async {
        let defaults = UserDefaults.inMemory
        let trace = TimerPreferenceTrace(defaults, label: #function)
        let store = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
        }
        #expect(store.state.isKeepScreenOn)
        trace.mark("before send 3")
        await store.send(.view(.keepScreenOnToggled(false))) { $0.$isKeepScreenOn.withLock { $0 = false } }
        let reloaded = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: { SettingsFeature.State() }
        #expect(!reloaded.isKeepScreenOn)
        #expect(reloaded.isSoundOn && reloaded.isVibrationOn && reloaded.isSpeechOn)
        expectStored(
            false,
            forKey: "timerKeepScreenOn",
            in: defaults,
            shared: store.state.isKeepScreenOn,
            trace: trace
        )
        trace.mark("before send 4")
        await store.send(.view(.keepScreenOnToggled(true))) { $0.$isKeepScreenOn.withLock { $0 = true } }
    }

    @Test
    func test_toggle_eachSignal_persistsIndependently() async {
        let defaults = UserDefaults.inMemory
        let trace = TimerPreferenceTrace(defaults, label: #function)
        let store = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
        }
        #expect(store.state.isSoundOn && store.state.isVibrationOn && store.state.isSpeechOn)
        trace.mark("before send 5")
        await store.send(.view(.soundToggled(false))) { $0.$isSoundOn.withLock { $0 = false } }
        trace.mark("before send 6")
        await store.send(.view(.vibrationToggled(false))) { $0.$isVibrationOn.withLock { $0 = false } }
        trace.mark("before send 7")
        await store.send(.view(.speechToggled(false))) { $0.$isSpeechOn.withLock { $0 = false } }
        let reloaded = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: { SettingsFeature.State() }
        #expect(!reloaded.isSoundOn && !reloaded.isVibrationOn && !reloaded.isSpeechOn)
        expectStored(
            false,
            forKey: "signalSound",
            in: defaults,
            shared: store.state.isSoundOn,
            trace: trace
        )
        expectStored(
            false,
            forKey: "signalVibration",
            in: defaults,
            shared: store.state.isVibrationOn,
            trace: trace
        )
        expectStored(
            false,
            forKey: "signalSpokenStageNames",
            in: defaults,
            shared: store.state.isSpeechOn,
            trace: trace
        )
        trace.mark("before send 8")
        await store.send(.view(.soundToggled(true))) { $0.$isSoundOn.withLock { $0 = true } }
        #expect(!store.state.isVibrationOn && !store.state.isSpeechOn)
    }

    /// A mismatch includes shared state, the current suite and the changes observed before the direct read.
    /// Missing change notifications alone do not identify why a write failed.
    private func expectStored(
        _ expected: Bool,
        forKey key: String,
        in defaults: UserDefaults,
        shared: Bool,
        trace: TimerPreferenceTrace,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        trace.mark("direct read key=\(key) value=\(String(describing: defaults.object(forKey: key)))")
        let preferences = defaults.dictionaryRepresentation()
            .filter { $0.key.hasPrefix("signal") || $0.key.hasPrefix("timer") || $0.key == "iCloudSync" }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        #expect(
            defaults.object(forKey: key) as? Bool == expected,
            "\(key): shared state holds \(shared); the suite holds \(preferences.joined(separator: ", ")); trace: \(trace.report)",
            sourceLocation: sourceLocation
        )
    }
}
