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

    /// Reads the list again whenever iCloud may have changed the store, for as long as the app runs.
    func observeRemoteChanges() -> Effect<Action> {
        .run { [cloudSync] send in
            for await _ in await cloudSync.remoteChanges() {
                await send(.internal(.workoutsChangedRemotely))
            }
        }
        .cancellable(id: CancelID.remoteChanges)
    }

    /// Shows the stored version on a read-only workout screen, or closes it when the workout is gone. A draft, a
    /// screen with an alert or one starting the timer stays as it is: replacing it would lose what the user is doing.
    func refreshOpenWorkout(_ state: inout State) -> Effect<Action> {
        guard
            state.startIntent == nil,
            case let .loaded(workouts) = state.workouts,
            let id = state.path.ids.last,
            let editor = state.path[id: id, case: \.editor],
            editor.phase == .viewing,
            editor.destination == nil,
            !editor.isStarting
        else { return .none }

        guard let stored = workouts[id: editor.workout.id] else {
            return .send(.path(.element(id: id, action: .editor(.view(.backButtonTapped)))))
        }
        state.path[id: id, case: \.editor]?.showStored(stored)
        return .none
    }
}
