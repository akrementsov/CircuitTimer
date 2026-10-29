import BackgroundExecution
import BackgroundNotifications
import ComposableArchitecture
import Foundation
import os
import SwiftUI
import TimerPreferences
import WorkoutActivity
import WorkoutDomain
import WorkoutHealth
import WorkoutStorage

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

    /// Screens pushed over the timer. The stage list has no logic of its own: it carries its outline.
    @Reducer
    public enum Path {
        @ReducerCaseIgnored
        case stageList(WorkoutOutline)
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
        /// Also identifies this screen's session in `TimerSessionClient`.
        public let id: UUID
        public let workoutID: Workout.ID
        public let title: String
        /// The workout's name as stored; the Live Activity decides how a blank one reads.
        public let workoutName: String
        var run: WorkoutRun
        public internal(set) var snapshot: WorkoutRun.Snapshot
        /// `.start` with 3 s at init, unless the schedule is empty.
        public internal(set) var countdown: Countdown?
        /// Set when a clock loop failed; the screen says so until Play starts the clock again.
        public internal(set) var hasClockFailed = false
        /// The clock loop whose actions count; 0 until the screen first appears.
        var clockGeneration = 0
        /// The first digit waits for native audio preparation; the clock starts when this becomes false.
        var isPreparingCountdown = false
        /// Set while a tick loop runs, and refreshed on every tick.
        var clockAnchor: ClockAnchor?
        /// The keep-awake vote last sent for this screen, and its revision.
        var requestedAwake = false
        var awakeRevision = 0
        /// What the record file holds, as far as this screen knows.
        var recordSync = RecordSync.unknown
        /// Set while the newest record write failed: a relaunch may bring back no run, or an earlier state of one.
        public internal(set) var hasRecordFailed = false
        /// Whether the Lock Screen cannot show the workout; the newest serial wins.
        public internal(set) var liveActivityNotice: LiveActivityNotice?
        /// Exists for the timer stack's control subscription, independently of its clock loops.
        var activityControls: ActivityControlState?
        /// Set once the screen starts closing, also before the control subscription exists.
        var isClosing = false
        /// Between `.background` and the next `.active`; no countdown runs meanwhile.
        var isInBackground = false
        @SharedReader(.keepScreenOn) var isKeepScreenOn = true
        @SharedReader(.soundSignals) var isSoundOn = true
        @SharedReader(.vibrationSignals) var isVibrationOn = true
        @SharedReader(.spokenStageNames) var isSpeechOn = true
        @SharedReader(.backgroundNotifications) var isBackgroundNotificationsOn = true
        var notifications = NotificationState()
        var signals = SignalTrack()
        var isSceneActive = false
        var haptic: HapticCue?
        var cueFailures: Set<CueFailure> = []
        @Presents public var destination: Destination.State?
        public internal(set) var path = StackState<Path.State>()

        public init(id: UUID, workoutID: Workout.ID, title: String, workoutName: String, schedule: WorkoutSchedule) {
            self.id = id
            self.workoutID = workoutID
            self.title = title
            self.workoutName = workoutName
            // `@ObservableState` makes stored properties computed, so `self.run` can't be read before every property is set.
            let run = WorkoutRun(schedule: schedule)
            self.run = run
            // A new run is idle, or finished when the schedule is empty; neither reads the date.
            snapshot = run.snapshot(at: .distantPast)
            countdown = schedule.stages.isEmpty ? nil : Countdown(.start)
            isPreparingCountdown = countdown != nil
        }

        /// A saved run brought back after the process was gone; `run` is already settled at `now`.
        ///
        /// No countdown: the user saw the run going before, so it continues as it was, running or paused.
        public init(id: UUID, workoutID: Workout.ID, title: String, workoutName: String, restoring run: WorkoutRun, at now: Date) {
            self.id = id
            self.workoutID = workoutID
            self.title = title
            self.workoutName = workoutName
            var run = run
            // Already settled at `now`; the tick keeps the rule that a snapshot follows a tick.
            run.tick(at: now)
            self.run = run
            snapshot = run.snapshot(at: now)
            countdown = nil
        }

        /// A run waiting for the user lets the screen lock.
        var keepsScreenAwake: Bool {
            isKeepScreenOn && (countdown != nil || snapshot.status == .running)
        }
    }

    public enum Action: ViewAction, Equatable, Sendable {
        case view(View)
        case `internal`(Internal)
        case destination(PresentationAction<Destination.Action>)
        case path(StackActionOf<Path>)

        @CasePathable
        public enum View: Equatable, Sendable {
            case task
            case activityTask
            case closeButtonTapped
            case playPauseButtonTapped
            case nextButtonTapped
            case stagesButtonTapped
            case scenePhaseChanged(ScenePhase)
            case notificationPreferencesChanged
        }

        @CasePathable
        public enum Internal: Equatable, Sendable {
            case countdownPrepared(generation: Int, CueResult)
            case countdownTicked(generation: Int)
            /// `isFinal`: the loop saw its copy stop and has ended.
            case ticked(generation: Int, isFinal: Bool)
            case clockFailed(generation: Int)
            case cueFinished(revision: Int, CueResult)
            case recordWritten(revision: Int, succeeded: Bool)
            case notificationAccessLoaded(generation: Int, NotificationAccess?)
            case notificationsSynced(revision: Int, report: NotificationSyncReport?)
            case liveActivityNoticeChanged(LiveActivityNotice)
            case activityRequestsReady
            case activityRequestsEnded
            case activityRequestReceived(LiveActivityControlRequest)
            case activitySynchronized(revision: Int, LiveActivitySyncResult)
        }
    }

    enum CancelID: Hashable, Sendable {
        case clock(generation: Int)
        case cues
        case notificationAccess
        case activityRequests
    }

    /// The two clocks may disagree by this much before it counts as a jump of the wall clock.
    static let jumpTolerance: Duration = .milliseconds(250)

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "WorkoutTimer")

    @Dependency(\.backgroundNotifications) var backgroundNotifications
    @Dependency(\.backgroundTask) var backgroundTask
    @Dependency(\.cues) var cues
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date) var date
    @Dependency(\.dismiss) var dismiss
    @Dependency(\.liveActivity) var liveActivity
    @Dependency(\.preferredLocales) var preferredLocales
    @Dependency(\.timerSession) var timerSession
    @Dependency(\.workoutHealth) var workoutHealth
    @Dependency(\.workoutRunRecord) var workoutRunRecord

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            let controlMoment = ControlMoment(state)
            let effect: Effect<Action> = switch action {
                case let .view(action):
                    reduce(into: &state, action)
                case let .internal(action):
                    reduce(into: &state, action)
                case let .destination(.presented(.closeConfirmation(choice))):
                    closeConfirmed(choice, &state)
                case .destination:
                    .none
                case .path:
                    // Leaving the stage list keeps the run paused, like the original app.
                    .none
            }
            updateControlGeneration(&state, after: action, from: controlMoment)
            return effect
        }
        .ifLet(\.$destination, action: \.destination)
        .forEach(\.path, action: \.path)
        Reduce { state, action in
            // Presentation and stack reducers settle visibility before cues compare the screen's moment.
            if case .destination(.presented(.closeConfirmation(.finish))) = action { return .none }
            if case .view(.closeButtonTapped) = action, state.snapshot.status == .finished { return .none }
            let now = date()
            let signals = signal(&state)
            let awake = syncScreenAwake(&state)
            let notifications = syncNotifications(&state, after: action, at: now)
            let activity = syncLiveActivity(&state, after: action, at: now)
            let health = startHealthSession(state, after: action, at: now)
            return .merge(signals, awake, notifications, activity, health, finishActivityControl(&state))
        }
    }

    // Every action decides on the phase settled at `now`. It syncs the clock only when the settle changed the
    // status or the action changed the countdown or the run; otherwise the running loop stays as it is.

    private func reduce(into state: inout State, _ action: Action.View) -> Effect<Action> {
        // The close alert relies on a stopped clock; a control that slips under it would restart the clock or
        // replace the alert. Leaving and coming back still count: the clock is stopped, and the run is saved.
        if action != .task, action != .activityTask, !action.is(\.scenePhaseChanged), action != .notificationPreferencesChanged,
           state.destination != nil { return .none }

        let now = date()
        switch action {
            case .task:
                // The loops belong to the store, so a later appearance finds them running.
                guard state.clockGeneration == 0 else { return .none }

                return syncClock(&state, at: now)
            case .activityTask:
                guard state.activityControls == nil else { return .none }
                state.activityControls = ActivityControlState()
                return subscribeActivityRequests(state.id)
            case .notificationPreferencesChanged:
                return .none
            case .closeButtonTapped:
                return close(&state, at: now)
            case .playPauseButtonTapped:
                return playPause(&state, at: now)
            case .nextButtonTapped:
                return next(&state, at: now)
            case .stagesButtonTapped:
                return showStageList(&state, at: now)
            case let .scenePhaseChanged(phase):
                return scenePhaseChanged(phase, &state, at: now)
        }
    }

    private func reduce(into state: inout State, _ action: Action.Internal) -> Effect<Action> {
        switch action {
            case .activityRequestsReady:
                guard state.activityControls?.isEnding == false else { return .none }
                state.activityControls?.isReady = true
                let now = date()
                return advance(&state, at: now) ? syncClock(&state, at: now) : .none
            case .activityRequestsEnded:
                state.activityControls?.isReady = false
                guard let pending = state.activityControls?.pending else { return .none }
                state.activityControls?.pending = nil
                return acknowledgeActivityRequest(state.id, requestID: pending.id, result: .unavailable)
            case let .activityRequestReceived(request):
                return handleActivityRequest(request, &state, at: date())
            case let .activitySynchronized(revision, result):
                activitySynchronized(revision: revision, result: result, &state)
                return .none
            case let .notificationAccessLoaded(generation, access):
                guard generation == state.notifications.accessGeneration, state.isBackgroundNotificationsOn else { return .none }
                state.notifications.access = access
                return .none
            case let .notificationsSynced(revision, report):
                notificationsSynced(revision: revision, report: report, &state)
                return .none
            case let .liveActivityNoticeChanged(notice):
                liveActivityNoticeChanged(notice, &state)
                return .none
            case let .cueFinished(revision, result):
                cueFinished(revision: revision, result: result, &state)
                return .none
            case let .recordWritten(revision, succeeded):
                recordWritten(revision: revision, succeeded: succeeded, &state)
                return .none
            case let .countdownPrepared(generation, result):
                if let stale = stopIfStale(generation, state) { return stale }
                guard state.isPreparingCountdown, let countdown = state.countdown else { return .none }

                state.isPreparingCountdown = false
                cueFinished(revision: state.signals.cueRevision, result: result, &state)
                return runCountdown(remaining: countdown.remaining, owner: state.id, generation: generation)
            case let .countdownTicked(generation):
                if let stale = stopIfStale(generation, state) { return stale }

                return countdownTicked(&state, at: date())
            case let .ticked(generation, isFinal):
                if let stale = stopIfStale(generation, state) { return stale }

                return ticked(isFinal: isFinal, &state, at: date())
            case let .clockFailed(generation):
                if let stale = stopIfStale(generation, state) { return stale }

                let now = date()
                _ = advance(&state, at: now)
                state.run.pause(at: now)
                state.countdown = nil
                state.hasClockFailed = true
                return syncClock(&state, at: now)
        }
    }

    /// A replaced loop may have started after its cancel ran, so its own action cancels it again.
    private func stopIfStale(_ generation: Int, _ state: State) -> Effect<Action>? {
        generation == state.clockGeneration ? nil : .cancel(id: CancelID.clock(generation: generation))
    }

    private func countdownTicked(_ state: inout State, at now: Date) -> Effect<Action> {
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
    }

    private func ticked(isFinal: Bool, _ state: inout State, at now: Date) -> Effect<Action> {
        let mustSync = advance(&state, at: now)
        // A loop that has ended leaves a still running run without a clock, so it is restarted.
        guard !mustSync, !isFinal, state.snapshot.status == .running else { return syncClock(&state, at: now) }

        // Measuring each jump check over one tick keeps a slow slew of the wall clock from adding up.
        state.clockAnchor = anchor(at: now, totalElapsed: state.snapshot.totalElapsed)
        return .none
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

    /// The list hides the clock, so a running stage pauses and a 3-2-1 stops while it is open; Play starts either
    /// again, as the original app did.
    private func showStageList(_ state: inout State, at now: Date) -> Effect<Action> {
        // A second tap while the list is being pushed opens nothing.
        guard state.path.isEmpty else { return .none }

        var mustSync = advance(&state, at: now)
        if state.countdown != nil {
            state.countdown = nil
            mustSync = true
        } else if state.snapshot.status == .running {
            state.run.pause(at: now)
            mustSync = true
        }
        state.path.append(.stageList(state.outline))
        return mustSync ? syncClock(&state, at: now) : .none
    }

    /// Handles a clock jump, commits the progress made by `now` and returns whether the clock must follow:
    /// a jump was found or the status changed.
    func advance(_ state: inout State, at now: Date) -> Bool {
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
            // `elapsed(since:)` stops at zero, so a jump back past the anchor is measured from the other side.
            let jump = now < anchor.date ? monotonic + anchor.date.elapsed(since: now) : monotonic - wall
            Self.logger.notice(
                "The wall clock went back by \(jump.inMilliseconds) ms; keeping \(kept.inMilliseconds) ms of the run"
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

    /// Replaces the loop and saves the settled run: every operation, jump and status change reaches the record file,
    /// while a tick that changes none of them does not. Screen wake follows the phase and the stored preference.
    func syncClock(_ state: inout State, at now: Date) -> Effect<Action> {
        .merge(replaceClockLoop(&state, at: now), persist(&state), syncScreenAwake(&state))
    }

    /// Reconcile on every action so a preference change never restarts the clock or rewrites the run.
    private func syncScreenAwake(_ state: inout State) -> Effect<Action> {
        guard state.clockGeneration > 0, state.keepsScreenAwake != state.requestedAwake else { return .none }

        state.requestedAwake = state.keepsScreenAwake
        state.awakeRevision += 1
        let id = state.id
        let awake = state.requestedAwake
        let revision = state.awakeRevision
        return .run { [timerSession] _ in
            await timerSession.requestAwake(owner: id, awake: awake, revision: revision)
        }
    }

    private func replaceClockLoop(_ state: inout State, at now: Date) -> Effect<Action> {
        state.run.tick(at: now)
        state.snapshot = state.run.snapshot(at: now)
        let cancelled = Effect<Action>.cancel(id: CancelID.clock(generation: state.clockGeneration))
        let suspend: Effect<Action> = if state.isPreparingCountdown {
            .run { [cues, id = state.id, revision = state.signals.cueRevision] _ in await cues.suspend(id, revision) }
        } else {
            .none
        }
        let replaced = Effect<Action>.merge(cancelled, suspend)
        state.isPreparingCountdown = false
        state.clockGeneration += 1
        state.clockAnchor = nil

        if let countdown = state.countdown {
            state.hasClockFailed = false
            guard !state.isInBackground else { return replaced }
            if state.isSoundOn {
                state.isPreparingCountdown = true
                guard state.isSceneActive else { return replaced }

                state.signals.last = nil
                state.haptic = nil
                state.signals.cueRevision += 1
                return .merge(
                    replaced,
                    prepareCountdown(owner: state.id, revision: state.signals.cueRevision, generation: state.clockGeneration)
                )
            }

            return .merge(replaced, runCountdown(remaining: countdown.remaining, owner: state.id, generation: state.clockGeneration))
        }
        if state.snapshot.status == .running {
            state.hasClockFailed = false
            state.clockAnchor = anchor(at: now, totalElapsed: state.snapshot.totalElapsed)
            return .merge(replaced, runTicks(state.run, owner: state.id, generation: state.clockGeneration))
        }
        if state.snapshot.status == .finished {
            // A finished run has nothing left to continue, so it shows its end rather than a stopped clock.
            state.hasClockFailed = false
        }
        return replaced
    }

    private func runTicks(_ run: WorkoutRun, owner: UUID, generation: Int) -> Effect<Action> {
        .run { [clock, date, timerSession] send in
            do {
                try await Self.tickLoop(
                    clock: clock,
                    date: date,
                    session: timerSession,
                    owner: owner,
                    run: run,
                    generation: generation,
                    send: send
                )
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("The tick clock failed: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.clockFailed(generation: generation)))
            }
        }
        .cancellable(id: CancelID.clock(generation: generation))
    }

}

extension WorkoutTimerFeature.Destination.State: Equatable, Sendable {}
extension WorkoutTimerFeature.Path.State: Equatable, Sendable {}
extension WorkoutTimerFeature.Path.Action: Equatable, Sendable {}

extension WorkoutTimerFeature.Countdown {
    init(_ purpose: Purpose) {
        self.init(purpose: purpose, remaining: Self.length)
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
