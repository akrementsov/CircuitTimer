import ComposableArchitecture
import Foundation
import WorkoutHealth

extension AppFeature {
    /// Ends what a timer owned when its cover goes without its own close. The watch comes first, as in the timer's
    /// close: no request confirms this run on the watch from here.
    func endTimerOwners(_ id: UUID, track: WorkoutHealthTrack, at now: Date) -> Effect<Action> {
        .run { [watchCompanion, timerSession, workoutHealth, cues, backgroundNotifications, liveActivity] _ in
            await watchCompanion.end(id)
            await timerSession.end(owner: id)
            await workoutHealth.end(id, track, now)
            await cues.end(id)
            await backgroundNotifications.end(id)
            await liveActivity.end(id)
        }
    }
}
