import ComposableArchitecture
import Foundation
import SwiftUI
import WorkoutDomain
import WorkoutTimerFeature

extension AppFeature {
    /// A Start waiting for permissions before the timer opens: notifications first, then Health.
    struct StartIntent: Equatable, Sendable {
        enum Stage: Equatable, Sendable {
            case notifications
            case health
        }

        let generation: Int
        let editorID: StackElementID
        let workout: Workout
        var stage = Stage.notifications
        var isAwaitingAuthorization = false
        /// The Health stage has not finished in time and Start is free again; a new tap goes on without Health.
        var hasStalled = false
    }

    /// Presents the timer over the tab bar; the Workouts stack returns to the list once the cover is up.
    func startWorkout(_ workout: Workout, _ state: inout State) -> Effect<Action> {
        // The workout's screen offers Start only for a playable workout and never under a presentation.
        guard state.destination == nil else {
            Self.logger.error("Refused to start a workout while something is presented")
            return refuseStart(&state)
        }
        guard workout.isPlayable else {
            Self.logger.error("Refused to start a workout with nothing to play")
            return refuseStart(&state)
        }
        guard let editorID = state.path.ids.last else {
            Self.logger.error("Refused to start a workout without its screen")
            return .none
        }
        if let intent = state.startIntent {
            // Start is free again only once the Health stage has stalled; this tap goes on without it.
            guard intent.stage == .health, intent.hasStalled else { return .none }

            return .merge(discardStartIntent(&state), openTimer(workout, editorID: editorID, &state))
        }
        return prepareNotificationPermission(workout, editorID: editorID, &state)
    }

    /// The screen marked its Start busy before sending it; a refused Start frees it, unless an earlier intent holds it.
    private func refuseStart(_ state: inout State) -> Effect<Action> {
        guard state.startIntent == nil, let editorID = state.path.ids.last else { return .none }

        state.path[id: editorID, case: \.editor]?.cancelStart()
        return .none
    }

    func isCurrentStart(_ workout: Workout, editorID: StackElementID, _ state: State) -> Bool {
        guard state.selectedTab == .workouts, state.path.ids.last == editorID,
              let editor = state.path[id: editorID, case: \.editor] else { return false }
        return editor.phase == .viewing && editor.workout == workout
    }

    /// The one way to the timer after a Start. A Start that is no longer current is released, so its button works
    /// again even when no intent is left to cancel.
    func presentTimer(_ workout: Workout, editorID: StackElementID, _ state: inout State) -> Bool {
        guard state.destination == nil, isCurrentStart(workout, editorID: editorID, state) else {
            Self.logger.notice("A Start was no longer current when its timer was about to open")
            state.path[id: editorID, case: \.editor]?.cancelStart()
            return false
        }
        state.destination = .timer(timerState(for: workout))
        return true
    }

    /// Opens the timer and ends the Start's intent, if it has one, either way.
    func openTimer(_ workout: Workout, editorID: StackElementID, _ state: inout State) -> Effect<Action> {
        guard presentTimer(workout, editorID: editorID, &state) else { return cancelStartIntent(&state) }

        state.startIntent = nil
        return .merge(.cancel(id: CancelID.notificationPermissionStall), .cancel(id: CancelID.healthStall))
    }

    func cancelStartIntent(_ state: inout State) -> Effect<Action> {
        guard let intent = state.startIntent else { return .none }
        state.path[id: intent.editorID, case: \.editor]?.cancelStart()
        return discardStartIntent(&state)
    }

    /// Drops the intent without touching its Start: a new tap already holds it.
    func discardStartIntent(_ state: inout State) -> Effect<Action> {
        state.startIntent = nil
        state.startGeneration += 1
        return .merge(
            .cancel(id: CancelID.notificationPermission),
            .cancel(id: CancelID.notificationPermissionStall),
            .cancel(id: CancelID.healthPermission),
            .cancel(id: CancelID.healthStall)
        )
    }

    /// The permission stages and a stalled notification cleanup go on only in an active scene.
    func sceneChanged(_ phase: ScenePhase, _ state: inout State) -> Effect<Action> {
        state.isSceneActive = phase == .active
        guard phase == .active else {
            return .merge(.cancel(id: CancelID.notificationPermissionStall), .cancel(id: CancelID.healthStall))
        }
        return .merge(
            permissionStallTimer(state),
            healthSceneActivated(&state),
            state.isNotificationCleanupStalled ? cleanupNotifications(reportSuccess: true) : .none
        )
    }

    // A timer's state is built only here and in `restoredTimerState`, so both get the same identifiers and title.

    func timerState(for workout: Workout) -> WorkoutTimerFeature.State {
        WorkoutTimerFeature.State(
            id: uuid(),
            workoutID: workout.id,
            title: workout.displayName,
            workoutName: workout.name,
            schedule: WorkoutSchedule(workout: workout)
        )
    }

    /// A timer over a saved run already settled at `now`.
    func restoredTimerState(for workout: Workout, run: WorkoutRun, at now: Date) -> WorkoutTimerFeature.State {
        WorkoutTimerFeature.State(
            id: uuid(),
            workoutID: workout.id,
            title: workout.displayName,
            workoutName: workout.name,
            restoring: run,
            at: now
        )
    }
}
