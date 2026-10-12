import ComposableArchitecture
import Foundation
import SwiftUI

extension WorkoutTimerFeature {
    /// The view only reports the phase; leaving and coming back are decided here.
    ///
    /// `.inactive` changes nothing: Control Center and the App Switcher pass through it too.
    func scenePhaseChanged(_ phase: ScenePhase, _ state: inout State, at now: Date) -> Effect<Action> {
        switch phase {
            case .background:
                guard !state.isInBackground else { return .none }

                state.isInBackground = true
                _ = advance(&state, at: now)
                // Nobody watches a 3-2-1 in the background: it waits at full length and starts again on return.
                if let countdown = state.countdown {
                    state.countdown = Countdown(countdown.purpose)
                }
                // A running run gets an anchor taken as the app leaves, which measures the whole time away on return,
                // and the record gets the position reached.
                return syncClock(&state, at: now)
            case .active:
                guard state.isInBackground else { return .none }

                state.isInBackground = false
                // The anchor of this process spans the suspension: a clock moved back while away is rebased here.
                _ = advance(&state, at: now)
                return syncClock(&state, at: now)
            case .inactive:
                return .none
            @unknown default:
                return .none
        }
    }
}
