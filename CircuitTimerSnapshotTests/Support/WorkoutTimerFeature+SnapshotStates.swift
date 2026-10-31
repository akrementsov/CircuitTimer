@testable import AppFeature
@testable import WorkoutTimerFeature

import Foundation
import WorkoutDomain

/// Timer states as the screen shows them once it has appeared, built from the state Start creates.
///
/// Every factory ends with `markAppeared()`, after the run and the path are set: the timer's appearance then changes
/// nothing on screen, whenever its actions arrive.
extension WorkoutTimerFeature.State {
    /// The start 3-2-1 on its first digit.
    static func startCountdown(_ workout: Workout) -> Self {
        var state = AppFeature().timerState(for: workout)
        state.markAppeared()
        return state
    }

    /// Paused by the user 20 s into the first round's Burpees.
    static func paused(_ workout: Workout) -> Self {
        var state = pausedRun(workout)
        state.markAppeared()
        return state
    }

    static func finished(_ workout: Workout) -> Self {
        let now = TimerSnapshotDependencies.now
        var state = AppFeature().timerState(for: workout)
        state.countdown = nil
        state.run.start(at: now)
        for _ in state.run.schedule.stages {
            state.run.skipToNextStage(at: now)
        }
        state.settle(at: now)
        state.markAppeared()
        return state
    }

    /// The stage list pushed over the paused run, as the Stages button leaves it.
    static func stageList(_ workout: Workout) -> Self {
        var state = pausedRun(workout)
        state.path.append(.stageList(state.outline))
        state.markAppeared()
        return state
    }

    /// Whether the state is a fixed point of the timer's appearance, so its appear actions leave the first frame as it is.
    var hasAppearedForSnapshot: Bool {
        var appeared = self
        appeared.markAppeared()
        return appeared == self
    }

    private static func pausedRun(_ workout: Workout) -> Self {
        let now = TimerSnapshotDependencies.now
        let stageStart = now.adding(.seconds(-20))
        var state = AppFeature().timerState(for: workout)
        state.countdown = nil
        state.run.start(at: stageStart)
        // Jumping jacks → Arm circles → the pause after the warm-up → the first round's Burpees.
        for _ in 0..<3 {
            state.run.skipToNextStage(at: stageStart)
        }
        state.run.pause(at: now)
        state.settle(at: now)
        return state
    }

    private mutating func settle(at now: Date) {
        run.tick(at: now)
        snapshot = run.snapshot(at: now)
    }

    /// What the timer's first `.task`, notification access and active scene leave on screen; the clock never runs.
    private mutating func markAppeared() {
        clockGeneration = max(clockGeneration, 1)
        isPreparingCountdown = false
        isInBackground = false
        isSceneActive = true
        notifications.access = .authorized
        haptic = nil
        // An open stage list keeps no baseline, as `signal()` leaves it.
        signals.last = path.isEmpty ? SignalMoment(self) : nil
    }
}
