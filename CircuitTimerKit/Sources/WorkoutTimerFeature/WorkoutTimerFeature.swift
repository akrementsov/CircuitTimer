import ComposableArchitecture
import Foundation
import os
import WorkoutDomain

/// Plays one workout: a 3-2-1 countdown, then its stages over a `WorkoutRun`.
@Reducer
public struct WorkoutTimerFeature: Sendable {
    // An alert with actions needs a hand-written `Action`: with a macro-generated one the scoped
    // binding would drop the user's choice. See AGENTS.md › TCA.
    @Reducer
    public enum Destination {
        @ReducerCaseIgnored
        case closeConfirmation(AlertState<CloseConfirmation>)

        @CasePathable
        public enum Action: Equatable, Sendable {
            case closeConfirmation(CloseConfirmation)
        }
    }

    public enum CloseConfirmation: Equatable, Sendable {
        case finish
        /// Stays on the timer; a purpose starts that countdown again.
        case stay(restart: Countdown.Purpose?)
    }

    public struct Countdown: Equatable, Sendable {
        public enum Purpose: Equatable, Sendable {
            case start
            case resume
        }

        static let length = 3

        public let purpose: Purpose
        /// Whole seconds left, 3…1.
        public internal(set) var remaining: Int
    }

    @ObservableState
    public struct State: Equatable, Identifiable, Sendable {
        public let id: UUID
        public let title: String
        var run: WorkoutRun
        public internal(set) var snapshot: WorkoutRun.Snapshot
        /// `.start` with 3 s at init, unless the schedule is empty.
        public internal(set) var countdown: Countdown?
        /// Set when a clock loop failed; the screen says so until Play starts the clock again.
        public internal(set) var hasClockFailed = false
        /// The clock loop whose actions count; 0 until the screen first appears.
        var clockGeneration = 0
        /// Set while a tick loop runs, and refreshed on every tick.
        var clockAnchor: ClockAnchor?
        @Presents public var destination: Destination.State?

        public init(id: UUID, title: String, schedule: WorkoutSchedule) {
            self.id = id
            self.title = title
            run = WorkoutRun(schedule: schedule)
            // A new run is idle, or finished when the schedule is empty; neither reads the date.
            snapshot = run.snapshot(at: .distantPast)
            countdown = schedule.stages.isEmpty ? nil : Countdown(.start)
        }
    }

    public enum Action: ViewAction, Equatable, Sendable {
        case view(View)
        case `internal`(Internal)
        case destination(PresentationAction<Destination.Action>)

        @CasePathable
        public enum View: Equatable, Sendable {
            case task
            case closeButtonTapped
            case playPauseButtonTapped
            case nextButtonTapped
        }

        @CasePathable
        public enum Internal: Equatable, Sendable {
            case countdownTicked(generation: Int)
            /// `isFinal`: the loop saw its copy stop and has ended.
            case ticked(generation: Int, isFinal: Bool)
            case clockFailed(generation: Int)
        }
    }

    private enum CancelID: Hashable, Sendable {
        case clock(generation: Int)
    }

    /// The two clocks may disagree by this much before it counts as a jump of the wall clock.
    static let jumpTolerance: Duration = .milliseconds(250)

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "WorkoutTimer")

    @Dependency(\.continuousClock) private var clock
    @Dependency(\.date) private var date
    @Dependency(\.dismiss) private var dismiss

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
                case let .view(action):
                    reduce(into: &state, action)
                case let .internal(action):
                    reduce(into: &state, action)
                case let .destination(.presented(.closeConfirmation(choice))):
                    closeConfirmed(choice, &state)
                case .destination:
                    .none
            }
        }
        .ifLet(\.$destination, action: \.destination)
    }

    // Every action decides on the phase settled at `now`. It syncs the clock only when the settle changed the
    // status or the action changed the countdown or the run; otherwise the running loop stays as it is.

    private func reduce(into state: inout State, _ action: Action.View) -> Effect<Action> {
        let now = date()
        switch action {
            case .task:
                // The loops belong to the store, so a later appearance finds them running.
                guard state.clockGeneration == 0 else { return .none }

                return syncClock(&state, at: now)
            case .closeButtonTapped:
                return close(&state, at: now)
            case .playPauseButtonTapped:
                return playPause(&state, at: now)
            case .nextButtonTapped:
                return next(&state, at: now)
        }
    }

    private func reduce(into state: inout State, _ action: Action.Internal) -> Effect<Action> {
        // A replaced loop may have started after its cancel ran, so its own action cancels it again.
        guard action.generation == state.clockGeneration else {
            return .cancel(id: CancelID.clock(generation: action.generation))
        }

        let now = date()
        switch action {
            case .countdownTicked:
                guard var countdown = state.countdown else { return .none }

                countdown.remaining -= 1
                if countdown.remaining > 0 {
                    state.countdown = countdown
                    return .none
                }

                state.countdown = nil
                switch countdown.purpose {
                    case .start:
                        state.run.start(at: now)
                    case .resume:
                        state.run.resume(at: now)
                }
                return syncClock(&state, at: now)
            case let .ticked(_, isFinal):
                let mustSync = advance(&state, at: now)
                // A loop that has ended leaves a still running run without a clock, so it is restarted.
                guard !mustSync, !isFinal, state.snapshot.status == .running else { return syncClock(&state, at: now) }

                // Measuring each jump check over one tick keeps a slow slew of the wall clock from adding up.
                state.clockAnchor = anchor(at: now, totalElapsed: state.snapshot.totalElapsed)
                return .none
            case .clockFailed:
                _ = advance(&state, at: now)
                state.run.pause(at: now)
                state.countdown = nil
                state.hasClockFailed = true
                return syncClock(&state, at: now)
        }
    }

    private func playPause(_ state: inout State, at now: Date) -> Effect<Action> {
        let mustSync = advance(&state, at: now)
        if state.countdown != nil {
            state.countdown = nil
            return syncClock(&state, at: now)
        }

        switch state.snapshot.status {
            case .idle:
                state.countdown = Countdown(.start)
            case .running:
                state.run.pause(at: now)
            case .paused, .awaitingUser:
                state.run.resume(at: now)
            case .finished:
                return mustSync ? syncClock(&state, at: now) : .none
        }
        return syncClock(&state, at: now)
    }

    private func next(_ state: inout State, at now: Date) -> Effect<Action> {
        let mustSync = advance(&state, at: now)
        let countdown = state.countdown
        state.countdown = nil
        switch state.snapshot.status {
            case .idle:
                state.run.start(at: now)
            case .paused:
                // A stay countdown was about to resume, so the next stage runs; a plain pause stays paused.
                if countdown != nil {
                    state.run.resume(at: now)
                }
                state.run.skipToNextStage(at: now)
            case .running, .awaitingUser:
                state.run.skipToNextStage(at: now)
            case .finished:
                return mustSync ? syncClock(&state, at: now) : .none
        }
        return syncClock(&state, at: now)
    }

    private func close(_ state: inout State, at now: Date) -> Effect<Action> {
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
                    return .merge(syncClock(&state, at: now), .run { [dismiss] _ in await dismiss() })
            }
        }
        state.destination = .closeConfirmation(.closeConfirmation(restart: restart))
        return mustSync ? syncClock(&state, at: now) : .none
    }

    private func closeConfirmed(_ choice: CloseConfirmation, _ state: inout State) -> Effect<Action> {
        switch choice {
            case .finish:
                return .run { [dismiss] _ in await dismiss() }
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

    /// Handles a clock jump, commits the progress made by `now` and returns whether the clock must follow:
    /// a jump was found or the status changed.
    private func advance(_ state: inout State, at now: Date) -> Bool {
        let status = state.snapshot.status
        let jumped = reconcile(&state, at: now)
        state.run.tick(at: now)
        state.snapshot = state.run.snapshot(at: now)
        return jumped || state.snapshot.status != status
    }

    /// Compares the time since the anchor on both clocks. After a backward jump the run keeps the progress the
    /// monotonic clock vouches for; a forward jump keeps its progress, like time spent in the background.
    private func reconcile(_ state: inout State, at now: Date) -> Bool {
        guard let anchor = state.clockAnchor else { return false }
        guard let monotonic = anchor.instant.duration(toNowOf: clock) else {
            Self.logger.error("The clock anchor was taken on another clock; clock jumps go undetected")
            return false
        }

        let wall = now.elapsed(since: anchor.date)
        if wall + Self.jumpTolerance < monotonic {
            let kept = anchor.totalElapsed + monotonic
            Self.logger.notice(
                "The wall clock went back by \((monotonic - wall).inMilliseconds) ms; keeping \(kept.inMilliseconds) ms of the run"
            )
            state.run.rebase(at: now, keepingTotalElapsed: kept)
            return true
        }
        if wall > monotonic + Self.jumpTolerance {
            Self.logger.notice("The wall clock jumped forward by \((wall - monotonic).inMilliseconds) ms; the run keeps its progress")
            return true
        }
        return false
    }

    private func anchor(at now: Date, totalElapsed: Duration) -> ClockAnchor {
        ClockAnchor(date: now, instant: MonotonicInstant(now: clock), totalElapsed: totalElapsed)
    }

    /// Replaces the current clock loop with the one the settled state needs, if any.
    private func syncClock(_ state: inout State, at now: Date) -> Effect<Action> {
        state.run.tick(at: now)
        state.snapshot = state.run.snapshot(at: now)
        let replaced = Effect<Action>.cancel(id: CancelID.clock(generation: state.clockGeneration))
        state.clockGeneration += 1
        state.clockAnchor = nil

        if let countdown = state.countdown {
            state.hasClockFailed = false
            return .merge(replaced, runCountdown(remaining: countdown.remaining, generation: state.clockGeneration))
        }
        if state.snapshot.status == .running {
            state.hasClockFailed = false
            state.clockAnchor = anchor(at: now, totalElapsed: state.snapshot.totalElapsed)
            return .merge(replaced, runTicks(state.run, generation: state.clockGeneration))
        }
        return replaced
    }

    private func runCountdown(remaining: Int, generation: Int) -> Effect<Action> {
        .run { [clock] send in
            do {
                try await Self.countdownLoop(clock: clock, remaining: remaining, generation: generation, send: send)
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("The countdown clock failed: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.clockFailed(generation: generation)))
            }
        }
        .cancellable(id: CancelID.clock(generation: generation))
    }

    private func runTicks(_ run: WorkoutRun, generation: Int) -> Effect<Action> {
        .run { [clock, date] send in
            do {
                try await Self.tickLoop(clock: clock, date: date, run: run, generation: generation, send: send)
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("The tick clock failed: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.clockFailed(generation: generation)))
            }
        }
        .cancellable(id: CancelID.clock(generation: generation))
    }

    /// Wakes whenever the stage clock changes its second and ends once its copy of the run stops.
    static func tickLoop<C: Clock<Duration>>(
        clock: C,
        date: DateGenerator,
        run: WorkoutRun,
        generation: Int,
        send: Send<Action>
    ) async throws {
        while true {
            // The loop's copy only schedules wake-ups; the reducer commits and shows its own reading.
            let shown = run.snapshot(at: date())
            let stopped = shown.status != .running
            if !stopped {
                try await clock.sleep(for: wakeDelay(stageRemaining: shown.stageRemaining))
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

    /// Wakes once per remaining second. Every deadline is measured from one reading, so late wake-ups never add up.
    static func countdownLoop<C: Clock<Duration>>(
        clock: C,
        remaining: Int,
        generation: Int,
        send: Send<Action>
    ) async throws {
        let start = clock.now
        for second in stride(from: 1, through: remaining, by: 1) {
            try await clock.sleep(until: start.advanced(by: .seconds(second)), tolerance: nil)
            await send(.internal(.countdownTicked(generation: generation)))
        }
    }
}

extension WorkoutTimerFeature.Destination.State: Equatable, Sendable {}

extension WorkoutTimerFeature.Countdown {
    init(_ purpose: Purpose) {
        self.init(purpose: purpose, remaining: Self.length)
    }
}

private extension WorkoutTimerFeature.Action.Internal {
    var generation: Int {
        switch self {
            case let .countdownTicked(generation), let .ticked(generation, _), let .clockFailed(generation):
                generation
        }
    }
}

extension AlertState where Action == WorkoutTimerFeature.CloseConfirmation {
    static func closeConfirmation(restart: WorkoutTimerFeature.Countdown.Purpose?) -> Self {
        AlertState {
            TextState("timer.close.title", bundle: .module)
        } actions: {
            ButtonState(role: .cancel, action: .stay(restart: restart)) {
                TextState("timer.close.stay", bundle: .module)
            }
            ButtonState(role: .destructive, action: .finish) {
                TextState("timer.close.finish", bundle: .module)
            }
        } message: {
            TextState("timer.close.message", bundle: .module)
        }
    }
}
