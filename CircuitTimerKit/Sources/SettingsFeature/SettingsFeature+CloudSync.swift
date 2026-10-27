import CloudSync
import ComposableArchitecture

extension SettingsFeature {
    func observeCloudSyncStatus() -> Effect<Action> {
        .run { [cloudSync] send in
            for await status in await cloudSync.status() {
                await send(.internal(.cloudSyncStatusChanged(status)))
            }
        }
        .cancellable(id: CancelID.cloudSyncStatus, cancelInFlight: true)
    }
}

extension SettingsFeature.State {
    /// What the iCloud switch says under it: a change waiting for the next launch first, then that workouts stay on
    /// the device, then why sync does not work. A failed open shows while the switch stays on, since nothing waits then.
    var cloudSyncFootnote: String? {
        guard let cloudSyncStatus else { return nil }
        guard isICloudSyncOn == cloudSyncStatus.isRequested else { return "settings.iCloud.relaunch" }
        guard isICloudSyncOn else { return "settings.iCloud.localOnly" }

        switch cloudSyncStatus.problem {
            case .noAccount: return "settings.iCloud.noAccount"
            case .restricted: return "settings.iCloud.restricted"
            case .temporarilyUnavailable: return "settings.iCloud.unavailable"
            case .quotaExceeded: return "settings.iCloud.quotaExceeded"
            case .syncFailed: return "settings.iCloud.failed"
            case nil: return nil
        }
    }
}
