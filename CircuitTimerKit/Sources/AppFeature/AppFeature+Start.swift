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
        var acceptedAt: MonotonicInstant?

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
                // A refund or a revoked Family Sharing grant cancels a Start from the watch not yet presented.
                guard state.fullVersion == .full, case let .loaded(workouts) = state.workouts, let stored = workouts[id: workout.id],
                      stored.isPlayable, WorkoutSchedule(workout: stored).fingerprint == WorkoutSchedule(workout: workout).fingerprint
                else { return false }
                return state.path.allSatisfy { element in
                    guard case let .editor(editor) = element else { return false }
                    return editor.phase == .viewing && editor.destination == nil && !editor.isSaving
                }
        }
    }

    /// The one way to the timer after a Start. A Start that is no longer current is released, so its button works
    /// again even when no intent is left to cancel.
    func presentTimer(_ workout: Workout, origin: StartIntent.Origin, _ state: inout State) -> Bool {
        guard state.destination == nil, isCurrentStart(workout, origin: origin, state),
              !origin.isWatch || (state.isSceneActive && state.hasScenePhase
                  && state.startIntent.map({ !isWatchStartExpired($0) }) == true) else {
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
        state.destination = .timer(timerState(for: current, allowsWatchControl: state.fullVersion == .full))
        return true
    }

    /// Opens the timer and ends the Start's intent, if it has one, either way.
    func openTimer(_ workout: Workout, origin: StartIntent.Origin, _ state: inout State) -> Effect<Action> {
        if origin.isWatch {
            guard let intent = state.startIntent, startCanContinue(intent, state) else { return cancelStartIntent(&state) }
            guard state.hasScenePhase, state.isSceneActive else {
                state.startIntent?.stage = .awaitingActiveScene
                return .merge(.cancel(id: CancelID.notificationPermissionStall), .cancel(id: CancelID.healthStall))
            }
        }
        guard presentTimer(workout, origin: origin, &state) else { return cancelStartIntent(&state) }

        state.startIntent = nil
        return .merge(
            .cancel(id: CancelID.notificationPermissionStall),
            .cancel(id: CancelID.healthStall),
            .cancel(id: CancelID.watchStartDeadline)
        )
    }

    func cancelStartIntent(_ state: inout State) -> Effect<Action> {
        guard let intent = state.startIntent else { return .none }
        if case let .editor(editorID) = intent.origin { state.path[id: editorID, case: \.editor]?.cancelStart() }
        return discardStartIntent(&state)
    }

    /// Drops the intent without touching its Start: a new tap already holds it.
    func discardStartIntent(_ state: inout State) -> Effect<Action> {
        if state.startIntent?.origin.isWatch == true, state.destination?.is(\.permissionStalled) == true {
            state.destination = nil
        }
        state.startIntent = nil
        state.startGeneration += 1
        return .merge(
            .cancel(id: CancelID.notificationPermission),
            .cancel(id: CancelID.notificationPermissionStall),
            .cancel(id: CancelID.healthPermission),
            .cancel(id: CancelID.healthStall),
            .cancel(id: CancelID.watchStartDeadline)
        )
    }

    /// The permission stages and a stalled notification cleanup go on only in an active scene.
    func sceneChanged(_ phase: ScenePhase, _ state: inout State) -> Effect<Action> {
        state.hasScenePhase = true
        state.isSceneActive = phase == .active
        let startEffect: Effect<Action>
        if let intent = state.startIntent, !startCanContinue(intent, state) {
            startEffect = cancelStartIntent(&state)
        } else if phase == .active, let intent = state.startIntent, intent.stage == .awaitingActiveScene {
            startEffect = openTimer(intent.workout, origin: intent.origin, &state)
        } else {
            startEffect = .none
        }
        guard phase == .active else {
            return .merge(startEffect, .cancel(id: CancelID.notificationPermissionStall), .cancel(id: CancelID.healthStall))
        }
        return .merge(
            startEffect,
            permissionStallTimer(state),
            healthSceneActivated(&state),
            state.isNotificationCleanupStalled ? cleanupNotifications(reportSuccess: true) : .none
        )
    }

    // A timer's state is built only here and in `restoredTimerState`, so both get the same identifiers and title.

    // Each caller decides whether the watch may control the timer: the full version, which the watch app is part of.

    func timerState(for workout: Workout, allowsWatchControl: Bool) -> WorkoutTimerFeature.State {
        var timer = WorkoutTimerFeature.State(
            id: uuid(),
            workoutID: workout.id,
            title: workout.displayName,
            workoutName: workout.name,
            schedule: WorkoutSchedule(workout: workout)
        )
        timer.setWatchControl(allowsWatchControl)
        return timer
    }

    /// A timer over a saved run already settled at `now`.
    func restoredTimerState(
        for workout: Workout,
        run: WorkoutRun,
        at now: Date,
        allowsWatchControl: Bool
    ) -> WorkoutTimerFeature.State {
        var timer = WorkoutTimerFeature.State(
            id: uuid(),
            workoutID: workout.id,
            title: workout.displayName,
            workoutName: workout.name,
            restoring: run,
            at: now
        )
        timer.setWatchControl(allowsWatchControl)
        return timer
    }
}
