import ComposableArchitecture
import Foundation
import os
import PurchaseFeature
import Purchases
import SettingsFeature

extension AppFeature {
    /// Workouts the free version can create up to, the seeded sample included. A commercial rule, not a limit of the
    /// workout model: it blocks only new workouts, so every stored one stays visible, editable and playable.
    static let freeWorkoutLimit = 2

    /// New workouts need the full version once the list shows this many; until StoreKit answers they need it too, and
    /// a purchase sheet opened then closes by itself when the full version arrives. Copies of one workout from iCloud
    /// count once, as the list shows them.
    func isAtFreeWorkoutLimit(_ state: State) -> Bool {
        guard state.fullVersion != .full, case let .loaded(workouts) = state.workouts else { return false }

        return workouts.count >= Self.freeWorkoutLimit
    }

    func fullVersionRequested(_ request: SettingsFeature.FullVersionRequest, _ state: inout State) -> Effect<Action> {
        switch request {
            case .buy:
                state.purchaseRequest = .browse
            case .restore:
                state.purchaseRequest = .restore
            case .iCloudSync:
                state.purchaseRequest = .limit(.iCloudSync)
        }
        return .none
    }

    /// This pass orders the change against the watch's requests: a command or a Start handled after it follows the new
    /// status, the open timer included; the watch link learns of it from the effect.
    func fullVersionChanged(_ status: FullVersionStatus, _ state: inout State) -> Effect<Action> {
        let isChanged = state.fullVersion != status
        state.fullVersion = status
        // One subscription for both tabs: Settings shows the status the list already knows on its first frame.
        state.settings.fullVersion = status
        if state.destination?.is(\.timer) == true {
            // In place: replacing the destination would cancel the timer's effects.
            state.destination?.modify(\.timer) { $0.allowsWatchControl = status == .full }
        }
        return isChanged ? publishWatchAccess(status) : .none
    }

    /// Runs after every action. Shows a requested sheet once the launch's question about a saved run is settled and
    /// nothing else is presented: the sheet never takes the place of that question, an alert or the timer. Not on a
    /// presentation's own actions: a sheet or an alert going away there is still on screen, and what waited for it
    /// follows from a later action.
    func presentRequestedPurchase(after action: Action, _ state: inout State) -> Effect<Action> {
        if case .destination = action { return .none }
        guard let entry = state.purchaseRequest else { return .none }

        if state.fullVersion == .full {
            // Nothing left to sell, whichever way the sheet was asked for.
            state.purchaseRequest = nil
            return .none
        }
        guard isRunRestoreSettled(state) else { return .none }

        switch state.destination {
            case nil:
                state.purchaseRequest = nil
                state.destination = .purchase(PurchaseFeature.State(entry: entry, iCloudOutlook: iCloudOutlook(state)))
            case .timer:
                // The user went on with a workout; a sheet after it would come out of nowhere.
                Self.logger.notice("Dropped a purchase sheet request under the timer")
                state.purchaseRequest = nil
            case .alert, .resumeRun, .permissionStalled, .purchase:
                // Waits for the alert to be answered, or for the sheet already up to go.
                break
        }
        return .none
    }

    /// What a purchase in the sheet will mean for iCloud, so its thanks say only what is true. A status not read yet
    /// counts as a store on the device, which a purchase leaves so until the next launch.
    private func iCloudOutlook(_ state: State) -> PurchaseFeature.ICloudOutlook {
        guard state.settings.isICloudSyncOn else { return .off }

        return state.settings.cloudSyncStatus?.isMirroring == true ? .alreadySyncing : .startsNextLaunch
    }

    /// The question about a saved run is asked, answered or not coming: a failed first load cannot ask it until a
    /// retry loads the list.
    private func isRunRestoreSettled(_ state: State) -> Bool {
        switch state.runRestore {
            case .resolved:
                true
            case .found:
                state.workouts == .failed
            case .idle, .reading, .offered, .presenting:
                false
        }
    }

    /// The sheet's `onDismiss` shows what waited for it, once SwiftUI has taken it away.
    func purchaseCloseRequested(_ state: inout State) -> Effect<Action> {
        state.destination = nil
        return .none
    }

    /// What waited for a free presentation shows from a later action, once SwiftUI has taken an alert away: a
    /// requested sheet, a saved run found under the sheet, a write error that failed under it.
    func scheduleWhatWaited(_ state: State) -> Effect<Action> {
        guard state.hasPendingMutationAlert || state.runRestore.isFound || state.purchaseRequest != nil else { return .none }

        return .run { send in
            await send(.internal(.presentationFreed))
        }
    }

    /// A saved run found while a purchase sheet was up is offered now; a write that failed under the sheet says so. A
    /// requested sheet follows from the tail reducer, which runs after this action.
    func showWhatWaitedForPresentation(_ state: inout State) -> Effect<Action> {
        guard state.destination == nil else { return .none }

        let restore = resolveRestore(&state)
        if state.hasPendingMutationAlert, state.destination == nil {
            state.hasPendingMutationAlert = false
            state.destination = .alert(.mutationFailed)
        }
        return restore
    }

    func observeFullVersion() -> Effect<Action> {
        .run { [purchases] send in
            for await status in await purchases.changes() {
                await send(.internal(.fullVersionChanged(status)))
            }
        }
        .cancellable(id: CancelID.fullVersion, cancelInFlight: true)
    }
}

extension AppFeature.RunRestore {
    fileprivate var isFound: Bool {
        if case .found = self { true } else { false }
    }
}
