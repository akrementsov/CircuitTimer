import Foundation
import WorkoutDomain

extension Workout {
    /// The name the list shows, and the base of a copy's name: a blank name reads as "Untitled workout"
    /// in the current language, while storage keeps it blank.
    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "workouts.untitled", bundle: .module)
            : name
    }

    /// A workout with nothing to play has no timer.
    var isPlayable: Bool {
        totalDuration > .zero
    }
}
