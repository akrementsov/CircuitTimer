@testable import AppFeature
@testable import SettingsFeature

import CloudSync
import ComposableArchitecture
import SnapshotCapture
import Testing

extension SnapshotTests {
    @MainActor
    @Suite
    struct SettingsSnapshotTests {
        // The iCloud card stands below the five signal switches and is not measured to fit the first frame at AX5.
        @Test(arguments: SnapshotTextSize.currentCases(in: [.large]))
        func test_settings_iCloudSyncOff_matchesReference(textSize: SnapshotTextSize) async throws {
            try await assertAppSnapshot(textSize: textSize) { _ in
                var state = AppFeature.State.list([])
                state.selectedTab = .settings
                state.settings.$isICloudSyncOn.withLock { $0 = false }
                state.settings.cloudSyncStatus = CloudSyncStatus(isRequested: false, isMirroring: false, problem: nil)
                state.settings.fullVersion = .full
                return state
            }
        }

        // Large only, like the switch above: the rows under the card do not fit the first frame at AX5.
        @Test(arguments: SnapshotTextSize.currentCases(in: [.large]))
        func test_settings_withoutTheFullVersion_matchesReference(textSize: SnapshotTextSize) async throws {
            try await assertAppSnapshot(textSize: textSize) { _ in
                var state = AppFeature.State.list([])
                state.selectedTab = .settings
                state.settings.cloudSyncStatus = CloudSyncStatus(isRequested: true, isMirroring: false, problem: nil)
                state.settings.fullVersion = .free
                return state
            }
        }
    }
}
