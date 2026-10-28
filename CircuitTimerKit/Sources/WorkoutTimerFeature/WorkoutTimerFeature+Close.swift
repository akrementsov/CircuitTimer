import BackgroundExecution
import ComposableArchitecture
import Foundation

extension WorkoutTimerFeature {
    func close(_ state: inout State, at now: Date) -> Effect<Action> {
        var mustSync = advance(&state, at: now)
        let restart: Countdown.Purpose?
        if let countdown = state.countdown {
            state.countdown = nil
            restart = countdown.purpose
            mustSync = true
        } else {
            switch state.snapshot.status {
                case .running:
                    state.run.pause(at: now)
                    restart = .resume
                    mustSync = true
                case .idle, .paused, .awaitingUser:
                    restart = nil
                case .finished:
                    let stop = syncClock(&state, at: now)
                    return .merge(stop, closeScreen(&state))
            }
        }
        state.destination = .closeConfirmation(.closeConfirmation(restart: restart))
        return mustSync ? syncClock(&state, at: now) : .none
    }

    func closeConfirmed(_ choice: CloseConfirmation, _ state: inout State) -> Effect<Action> {
        switch choice {
            case .finish:
                return closeScreen(&state)
            case let .stay(restart):
                let now = date()
                let mustSync = advance(&state, at: now)
                // The alert was shown for this phase; anything else has nothing to restart.
                switch (restart, state.snapshot.status) {
                    case (.start, .idle):
                        state.countdown = Countdown(.start)
                    case (.resume, .paused):
                        state.countdown = Countdown(.resume)
                    default:
                        return mustSync ? syncClock(&state, at: now) : .none
                }
                return syncClock(&state, at: now)
        }
    }

    /// The only way the timer closes; its clock must have stopped already.
    private func closeScreen(_ state: inout State) -> Effect<Action> {
        state.activityControls?.isEnding = true
        assert(!state.requestedAwake, "The timer closes only after its clock has stopped")
        let revision = workoutRunRecord.nextRevision()
        let token = backgroundTask.begin("Clear the closed workout run")
        let id = state.id
        let now = date()
        let notifications = backgroundNotifications
        let activity = liveActivity
        let health = workoutHealth
        let record = workoutRunRecord
        // `end` finishes before `dismiss` starts the teardown. A loop whose cancellation registers before the
        // teardown is cancelled by it; one that registers later checks `isEnded` after registering, finds the
        // session ended and returns before it sleeps.
        let close = Effect<Action>.run { [timerSession, health, cues, notifications, activity, dismiss, record, backgroundTask] _ in
            await timerSession.end(owner: id)
            await health.end(id, now)
            await cues.end(id)
            await notifications.end(id)
            // The client bounds the wait; the activity goes in the background after that.
            await activity.end(id)
            await dismiss()
            // After the dismissal, so a slow disk never holds the screen. The teardown cancels this effect, but the
            // write does not stop for that, so a cancellation is no failure.
            do {
                try await record.write(nil, revision)
            } catch is CancellationError {
                await backgroundTask.end(token)
                return
            } catch {
                Self.logger.error("Clearing the closed run's record failed: \(String(reflecting: error), privacy: .public)")
            }
            await backgroundTask.end(token)
        }
        return .merge(.cancel(id: CancelID.cues), close)
    }
}
