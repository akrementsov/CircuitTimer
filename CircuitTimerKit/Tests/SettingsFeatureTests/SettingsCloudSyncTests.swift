@testable import SettingsFeature

import CloudSync
import ComposableArchitecture
import Foundation
import Testing

/// The switch, the status of this launch and the footnote they give.
struct CloudSyncFootnoteCase: Sendable {
    let isOn: Bool
    let status: CloudSyncStatus?
    let footnote: String?

    init(_ isOn: Bool, _ status: CloudSyncStatus?, _ footnote: String?) {
        self.isOn = isOn
        self.status = status
        self.footnote = footnote
    }
}

private func syncStatus(_ isRequested: Bool, _ isMirroring: Bool?, _ problem: CloudSyncProblem?) -> CloudSyncStatus {
    CloudSyncStatus(isRequested: isRequested, isMirroring: isMirroring, problem: problem)
}

/// The switch position, the launch's decision and the sync status, in that order of precedence.
private let footnoteCases: [CloudSyncFootnoteCase] = [
    CloudSyncFootnoteCase(true, nil, nil),
    CloudSyncFootnoteCase(true, syncStatus(true, true, nil), nil),
    CloudSyncFootnoteCase(false, syncStatus(true, true, .noAccount), "settings.iCloud.relaunch"),
    CloudSyncFootnoteCase(true, syncStatus(false, false, nil), "settings.iCloud.relaunch"),
    CloudSyncFootnoteCase(false, syncStatus(false, false, .syncFailed), "settings.iCloud.localOnly"),
    CloudSyncFootnoteCase(true, syncStatus(true, false, .syncFailed), "settings.iCloud.failed"),
    CloudSyncFootnoteCase(true, syncStatus(true, true, .noAccount), "settings.iCloud.noAccount"),
    CloudSyncFootnoteCase(true, syncStatus(true, true, .restricted), "settings.iCloud.restricted"),
    CloudSyncFootnoteCase(true, syncStatus(true, true, .temporarilyUnavailable), "settings.iCloud.unavailable"),
    CloudSyncFootnoteCase(true, syncStatus(true, true, .quotaExceeded), "settings.iCloud.quotaExceeded"),
    CloudSyncFootnoteCase(true, syncStatus(true, true, .syncFailed), "settings.iCloud.failed"),
]

@MainActor
@Suite
struct SettingsCloudSyncTests {
    @Test
    func test_iCloudSyncToggled_offAndOn_persistsUnderItsKeyWhichDefaultsToOn() async {
        #expect(isICloudSyncOn(in: UserDefaults.inMemory))
        let defaults = UserDefaults.inMemory
        let store = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
        }

        await store.send(.view(.iCloudSyncToggled(false))) { $0.$isICloudSyncOn.withLock { $0 = false } }

        #expect(defaults.object(forKey: "iCloudSync") as? Bool == false)
        #expect(!isICloudSyncOn(in: defaults))
        let reloaded = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: { SettingsFeature.State() }
        #expect(!reloaded.isICloudSyncOn)
        #expect(reloaded.isSoundOn && reloaded.isVibrationOn && reloaded.isSpeechOn && reloaded.isKeepScreenOn)
        #expect(reloaded.isBackgroundNotificationsOn)

        await store.send(.view(.iCloudSyncToggled(true))) { $0.$isICloudSyncOn.withLock { $0 = true } }
        #expect(defaults.object(forKey: "iCloudSync") as? Bool == true)
    }

    @Test
    func test_task_cloudSyncStatus_keepsTheLatestAndARepeatedTaskReplacesTheSubscription() async {
        let defaults = UserDefaults.inMemory
        // Notification access is not read, so the status is all the task delivers.
        defaults.set(false, forKey: "signalBackgroundNotifications")
        let first = AsyncStream<CloudSyncStatus>.makeStream()
        let second = AsyncStream<CloudSyncStatus>.makeStream()
        let firstEnded = LockIsolated(false)
        first.continuation.onTermination = { _ in firstEnded.setValue(true) }
        let subscriptions = LockIsolated(0)
        let store = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            TestStore(initialState: SettingsFeature.State()) { SettingsFeature() } withDependencies: {
                $0.cloudSync.status = {
                    let call = subscriptions.withValue { count in
                        count += 1
                        return count
                    }
                    return call == 1 ? first.stream : second.stream
                }
            }
        }
        let opening = syncStatus(true, nil, nil)
        let mirroring = syncStatus(true, true, nil)
        let noAccount = syncStatus(true, true, .noAccount)
        let quotaExceeded = syncStatus(true, true, .quotaExceeded)

        await store.send(.view(.task))
        first.continuation.yield(opening)
        first.continuation.yield(mirroring)
        await store.receive(.internal(.cloudSyncStatusChanged(opening))) { $0.cloudSyncStatus = opening }
        await store.receive(.internal(.cloudSyncStatusChanged(mirroring))) { $0.cloudSyncStatus = mirroring }

        await store.send(.view(.task))
        first.continuation.yield(noAccount)
        second.continuation.yield(quotaExceeded)
        await store.receive(.internal(.cloudSyncStatusChanged(quotaExceeded))) { $0.cloudSyncStatus = quotaExceeded }

        #expect(firstEnded.value)
        #expect(subscriptions.value == 2)
        second.continuation.finish()
        await store.finish()
    }

    @Test(arguments: footnoteCases)
    func test_cloudSyncFootnote_switchAndStatus_showsTheFirstApplicableNote(_ footnoteCase: CloudSyncFootnoteCase) {
        var state = withDependencies {
            $0.defaultAppStorage = UserDefaults.inMemory
        } operation: { SettingsFeature.State() }
        state.$isICloudSyncOn.withLock { $0 = footnoteCase.isOn }
        state.cloudSyncStatus = footnoteCase.status

        #expect(state.cloudSyncFootnote == footnoteCase.footnote)
    }

    /// What the launch reads to decide whether this process syncs.
    private func isICloudSyncOn(in defaults: UserDefaults) -> Bool {
        withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            @SharedReader(.iCloudSync) var isOn
            return isOn
        }
    }
}
