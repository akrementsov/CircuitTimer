import ComposableArchitecture
import Foundation
import os

extension AppFeature {
    /// Storage changed without a write of this list: read it again, but never over a write still in the queue, a
    /// reload already running or the first load, which each read again once they finish.
    func outsideChange(_ state: inout State) -> Effect<Action> {
        switch state.workouts {
            case .loading:
                state.needsReload = true
                return .none
            case .loaded:
                guard state.pendingMutations.isEmpty, !state.isReloading else {
                    state.needsReload = true
                    return .none
                }
                return loadWorkouts(&state)
            case .idle, .failed:
                // Nothing is shown yet, or the list offers Retry.
                return .none
        }
    }

    func loadWorkouts(_ state: inout State) -> Effect<Action> {
        // A shown list stays until the new one arrives: a spinner in its place would flash, and a push right after the
        // reload would carry the spinner's picture of the tab bar on iOS 26.
        if case .loaded = state.workouts {
            state.isReloading = true
        } else {
            state.workouts = .loading
        }
        return .run { [workoutStorage] send in
            do {
                let stored = try await workoutStorage.fetchAll()
                await send(.internal(.workoutsLoaded(stored)))
            } catch is CancellationError {
                // Superseded by a newer load; not a failure.
                return
            } catch {
                Self.logger.error("Failed to load workouts: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.workoutsLoadingFailed))
            }
        }
        .cancellable(id: CancelID.load, cancelInFlight: true)
    }
}
