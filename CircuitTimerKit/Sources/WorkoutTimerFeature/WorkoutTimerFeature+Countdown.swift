import ComposableArchitecture
import Foundation

extension WorkoutTimerFeature {
    func prepareCountdown(owner: UUID, revision: Int, generation: Int) -> Effect<Action> {
        .run { [cues] send in
            do {
                let result = try await cues.prepare(owner, revision)
                try Task.checkCancellation()
                await send(.internal(.countdownPrepared(generation: generation, result)))
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Preparing countdown audio failed: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.countdownPrepared(generation: generation, CueResult(failures: [.playerFailed]))))
            }
        }
        .cancellable(id: CancelID.clock(generation: generation))
    }

    func runCountdown(remaining: Int, owner: UUID, generation: Int) -> Effect<Action> {
        let start = MonotonicInstant(now: clock)
        return .run { [clock, timerSession] send in
            do {
                try await Self.countdownLoop(
                    clock: clock,
                    session: timerSession,
                    owner: owner,
                    remaining: remaining,
                    generation: generation,
                    send: send,
                    startingAt: start
                )
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("The countdown clock failed: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.clockFailed(generation: generation)))
            }
        }
        .cancellable(id: CancelID.clock(generation: generation))
    }

    // Wakes once per remaining second. Every deadline is measured from one reading, so late wake-ups never add up.
    // Every input is passed in, so the loop reads nothing from the store or the dependencies.
    // swiftlint:disable:next function_parameter_count
    static func countdownLoop<C: Clock<Duration>>(
        clock: C,
        session: TimerSessionClient,
        owner: UUID,
        remaining: Int,
        generation: Int,
        send: Send<Action>,
        startingAt: MonotonicInstant? = nil
    ) async throws {
        let start = try startingAt.map { try $0.instant(for: clock) } ?? clock.now
        for second in stride(from: 1, through: remaining, by: 1) {
            guard await !session.isEnded(owner: owner) else { return }

            try await clock.sleep(until: start.advanced(by: .seconds(second)), tolerance: .zero)
            await send(.internal(.countdownTicked(generation: generation)))
        }
    }
}
