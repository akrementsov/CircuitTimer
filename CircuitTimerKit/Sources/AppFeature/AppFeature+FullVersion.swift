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

    /// Asks for the purchase sheet; `presentRequestedPurchase` shows it once nothing is in the way. The latest request
    /// wins.
    func requestPurchase(_ entry: PurchaseFeature.Entry, _ state: inout State) {
        state.purchaseRequest = entry
    }

    func fullVersionRequested(_ request: SettingsFeature.FullVersionRequest, _ state: inout State) -> Effect<Action> {
        switch request {
            case .buy:
                requestPurchase(.browse, &state)
            case .restore:
                requestPurchase(.restore, &state)
            case .iCloudSync:
                requestPurchase(.limit(.iCloudSync), &state)
        }
        return .none
    }

    /// Runs after every action. Shows a requested sheet once the launch's question about a saved run is settled and
    /// nothing else is presented: the sheet never takes the place of that question, an alert or the timer.
    func presentRequestedPurchase(_ state: inout State) -> Effect<Action> {
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
                state.destination = .purchase(PurchaseFeature.State(entry: entry))
            case .timer:
                // The user went on with a workout; a sheet after it would come out of nowhere.
                Self.logger.notice("Dropped a purchase sheet request under the timer")
                state.purchaseRequest = nil
            case .alert, .resumeRun, .permissionStalled, .purchase:
                // Waits for the alert to be answered.
                break
        }
        return .none
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

    func purchaseCloseRequested(_ state: inout State) -> Effect<Action> {
        state.destination = nil
        return scheduleWhatWaited(state)
    }

    /// What waited for a free presentation shows from a later action, once SwiftUI has taken the sheet or alert away.
    func scheduleWhatWaited(_ state: State) -> Effect<Action> {
        guard state.hasPendingMutationAlert || state.runRestore.isFound else { return .none }

        return .run { send in
            await send(.internal(.presentationFreed))
        }
    }

    /// A saved run found while a purchase sheet was up is offered now; a write that failed under the sheet says so.
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
