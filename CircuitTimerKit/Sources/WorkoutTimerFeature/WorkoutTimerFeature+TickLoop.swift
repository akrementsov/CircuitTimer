import ComposableArchitecture
import Foundation
import WorkoutDomain

extension WorkoutTimerFeature {
    // Wakes whenever the stage clock changes its second and ends once its copy of the run stops.
    // Every input is passed in, so the loop reads nothing from the store or the dependencies.
    // swiftlint:disable:next function_parameter_count
    static func tickLoop<C: Clock<Duration>>(
        clock: C,
        date: DateGenerator,
        session: TimerSessionClient,
        owner: UUID,
        run: WorkoutRun,
        generation: Int,
        send: Send<Action>
    ) async throws {
        while true {
            // A loop that starts after its screen closed ends before it sleeps.
            guard await !session.isEnded(owner: owner) else { return }

            // The loop's copy only schedules wake-ups; the reducer commits and shows its own reading.
            let shown = run.snapshot(at: date())
            let stopped = shown.status != .running
            if !stopped {
                try await clock.sleep(for: wakeDelay(stageRemaining: shown.stageRemaining), tolerance: .zero)
            }
            await send(.internal(.ticked(generation: generation, isFinal: stopped)))
            if stopped { return }
        }
    }

    /// Time until `stageRemaining` crosses a whole second, where the stage clock, which rounds up, changes.
    /// Never zero, so the loop never spins.
    static func wakeDelay(stageRemaining: Duration) -> Duration {
        let fraction = stageRemaining - .seconds(stageRemaining.components.seconds)
        return fraction > .zero ? fraction : .seconds(1)
    }

}
