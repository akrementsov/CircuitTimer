import ComposableArchitecture
import Foundation
import WorkoutDomain
import WorkoutHealth

extension WorkoutTimerFeature {
    /// Holds a workout session while the cover is open, so iOS keeps the app running in the background and lets it end
    /// the card and notifications when the app is closed. HealthKit refuses a start from the background, so it waits
    /// for an active scene once the clock has started; the client ignores a repeat, and a start that failed is tried
    /// again on the next return to the app.
    func startHealthSession(_ state: State, after action: Action, at now: Date) -> Effect<Action> {
        guard action == .view(.task) || action == .view(.scenePhaseChanged(.active)),
              state.isSceneActive, state.clockGeneration > 0, !state.isClosing
        else { return .none }

        return .run { [workoutHealth, id = state.id] _ in
            await workoutHealth.start(id, now)
        }
    }

    /// Follows the run into the Health track and sends a changed track, so the session can save the workout up to where
    /// the run stands whenever it closes. A tick moves the track only when it rebases the run.
    func syncHealthTrack(_ state: inout State, at now: Date) -> Effect<Action> {
        if let phase = state.healthPhase { state.healthTrack.follow(phase, at: now) }
        guard !state.isClosing, state.healthTrack != state.sentHealthTrack else { return .none }

        state.healthRevision += 1
        state.sentHealthTrack = state.healthTrack
        return .run { [workoutHealth, id = state.id, revision = state.healthRevision, track = state.healthTrack] _ in
            await workoutHealth.sync(id, revision, track)
        }
    }
}

extension WorkoutTimerFeature.State {
    /// The run as its Health track sees it; `nil` until it starts. The start countdown is not part of the workout.
    var healthPhase: WorkoutHealthTrack.Phase? {
        switch run.phase {
            case .idle: nil
            case .running: run.automaticStopDate.map { .running(stopsAt: $0) }
            case .paused, .awaitingUser: .halted
            case .finished: .finished
        }
    }
}
