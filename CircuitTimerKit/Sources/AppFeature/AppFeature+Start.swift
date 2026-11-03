import ComposableArchitecture
import Foundation
import SwiftUI
import WorkoutDomain
import WorkoutTimerFeature

extension AppFeature {
    /// A Start waiting for permissions before the timer opens: notifications first, then Health.
    struct StartIntent: Equatable, Sendable {
        enum Origin: Equatable, Sendable {
            case editor(StackElementID)
            case watch(requestID: Int)

            var isWatch: Bool {
                if case .watch = self { true } else { false }
            }
        }

        enum Stage: Equatable, Sendable {
            case admitting
            case awaitingActiveScene
            case notifications
            case health
        }

        let generation: Int
        let origin: Origin
        let workout: Workout
        var stage = Stage.notifications
        var isAwaitingAuthorization = false
        /// The Health stage has not finished in time and Start is free again; a new tap goes on without Health.
        var hasStalled = false
        var skipsHealth = false

        var isStalledHealth: Bool { stage == .health && hasStalled }
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
            guard intent.isStalledHealth else { return refuseStart(&state) }

            return .merge(discardStartIntent(&state), openTimer(workout, origin: .editor(editorID), &state))
        }
        return prepareNotificationPermission(workout, origin: .editor(editorID), &state)
    }

    /// The screen marked its Start busy before sending it; a refused Start frees it, unless an earlier intent holds it.
    private func refuseStart(_ state: inout State) -> Effect<Action> {
        guard state.startIntent == nil || state.startIntent?.origin.isWatch == true,
              let editorID = state.path.ids.last else { return .none }

        state.path[id: editorID, case: \.editor]?.cancelStart()
        return .none
    }

    func isCurrentStart(_ workout: Workout, origin: StartIntent.Origin, _ state: State) -> Bool {
        switch origin {
            case let .editor(editorID):
                guard state.selectedTab == .workouts, state.path.ids.last == editorID,
                      let editor = state.path[id: editorID, case: \.editor] else { return false }
                return editor.phase == .viewing && editor.workout == workout
            case .watch:
                guard case let .loaded(workouts) = state.workouts, let stored = workouts[id: workout.id],
                      stored.isPlayable, WorkoutSchedule(workout: stored).fingerprint == WorkoutSchedule(workout: workout).fingerprint
                else { return false }
                return state.path.allSatisfy { element in
                    guard case let .editor(editor) = element else { return false }
                    return editor.phase == .viewing && editor.destination == nil
                }
        }
    }

    /// The one way to the timer after a Start. A Start that is no longer current is released, so its button works
    /// again even when no intent is left to cancel.
    func presentTimer(_ workout: Workout, origin: StartIntent.Origin, _ state: inout State) -> Bool {
        guard state.destination == nil, isCurrentStart(workout, origin: origin, state) else {
            Self.logger.notice("A Start was no longer current when its timer was about to open")
            if case let .editor(editorID) = origin { state.path[id: editorID, case: \.editor]?.cancelStart() }
            return false
        }
        let current: Workout
        if origin.isWatch, case let .loaded(workouts) = state.workouts, let stored = workouts[id: workout.id] {
            current = stored
        } else {
            current = workout
        }
        state.destination = .timer(timerState(for: current))
        return true
    }

    /// Opens the timer and ends the Start's intent, if it has one, either way.
    func openTimer(_ workout: Workout, origin: StartIntent.Origin, _ state: inout State) -> Effect<Action> {
        guard presentTimer(workout, origin: origin, &state) else { return cancelStartIntent(&state) }

        state.startIntent = nil
        return .merge(.cancel(id: CancelID.notificationPermissionStall), .cancel(id: CancelID.healthStall))
    }

    func cancelStartIntent(_ state: inout State) -> Effect<Action> {
        guard let intent = state.startIntent else { return .none }
        if case let .editor(editorID) = intent.origin { state.path[id: editorID, case: \.editor]?.cancelStart() }
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
