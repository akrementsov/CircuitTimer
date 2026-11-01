import ComposableArchitecture
import Foundation
import os
import WorkoutEditorFeature

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

    /// Starts the launch's iCloud decision, and the StoreKit read it waits for, beside the run record read: the list
    /// opens the store only after both, so they overlap instead of adding up.
    func prepareCloudSyncDecision() -> Effect<Action> {
        .run { [cloudSync] _ in
            await cloudSync.prepareDecision()
        }
    }

    func presentDeferredScreen(_ state: inout State) -> Effect<Action> {
        guard let request = state.deferredScreen else { return .none }

        // A request that cannot open now is dropped rather than kept for a surprise later.
        state.deferredScreen = nil
        // An empty stack also drops a second tap made while the editor is being pushed, and an empty destination
        // one made while the timer is being presented.
        guard state.destination == nil, state.path.isEmpty, state.selectedTab == .workouts else { return .none }

        switch request {
            case .create:
                // Checked here, on the list a queued write or a reload has just made current.
                guard !isAtFreeWorkoutLimit(state) else {
                    requestPurchase(.limit(.workoutLimit), &state)
                    return .none
                }
                state.path.append(
                    .editor(
                        WorkoutEditorFeature.State(
                            newWorkoutID: uuid(),
                            warmUpStageID: uuid(),
                            trainingStageID: uuid(),
                            coolDownStageID: uuid()
                        )
                    )
                )
            case let .open(id):
                // The workout may be gone by now; then there is nothing to show.
                guard case let .loaded(workouts) = state.workouts, let workout = workouts[id: id] else { return .none }

                state.path.append(.editor(WorkoutEditorFeature.State(viewing: workout)))
        }
        return .none
    }

    /// Later writes were derived from a list that storage did not accept; drops them, says so and resyncs.
    func mutationFailed(_ state: inout State) -> Effect<Action> {
        state.pendingMutations = []
        state.needsReload = false
        state.deferredScreen = nil
        switch state.destination {
            case .timer:
                // A presented timer is never replaced: it would close without ending its session. No write starts
                // under the cover yet, so this is defensive; the reload still resyncs the list.
                break
            case .purchase:
                // Replacing the sheet would cut a purchase short; the alert waits for it to close.
                state.hasPendingMutationAlert = true
            case .alert, .resumeRun, .permissionStalled, nil:
                state.destination = .alert(.mutationFailed)
        }
        return loadWorkouts(&state)
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

    /// Shows the stored version on a read-only workout screen, or closes it when the workout is gone. A screen the
    /// user is doing something on stays as it is: replacing it would lose that. A Health stage that stalled has freed
    /// Start; the new version makes its late answer stale, so it no longer opens the timer.
    func refreshOpenWorkout(_ state: inout State) -> Effect<Action> {
        guard
            state.startIntent == nil || state.startIntent?.hasStalled == true,
            case let .loaded(workouts) = state.workouts,
            let id = state.path.ids.last,
            let editor = state.path[id: id, case: \.editor],
            editor.acceptsStoredVersion
        else { return .none }

        guard let stored = workouts[id: editor.workout.id] else {
            return .send(.path(.element(id: id, action: .editor(.view(.backButtonTapped)))))
        }
        state.path[id: id, case: \.editor]?.showStored(stored)
        return .none
    }
}
