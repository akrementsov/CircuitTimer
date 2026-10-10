@testable import WorkoutDomain
@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation

/// A fixed date of the current epoch, so `Date` arithmetic has production precision.
let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// A date `seconds` after `origin`.
func moment(_ seconds: Double) -> Date {
    origin.addingTimeInterval(seconds)
}

extension UUID {
    /// Deterministic identifiers for fixtures.
    init(fixture number: Int) {
        let high = UInt8(truncatingIfNeeded: number >> 8)
        let low = UInt8(truncatingIfNeeded: number)
        self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, high, low))
    }
}

let timerID = UUID(fixture: 1)

func makeStage(_ number: Int, seconds: Int, _ intensity: Stage.Intensity = .work, name: String? = nil) -> Stage {
    Stage(id: UUID(fixture: 100 + number), name: name ?? "Stage \(number)", duration: .seconds(seconds), intensity: intensity)
}

enum Schedules {
    /// Work 10 s, rest 5 s.
    static let workRest = WorkoutSchedule(
        workout: Workout(id: UUID(fixture: 10), training: [makeStage(1, seconds: 10), makeStage(2, seconds: 5, .rest)])
    )
    /// Work 2 s, a manual pause, work 2 s. Stage indices: 0 work, 1 pause, 2 work.
    static let withPause = WorkoutSchedule(
        workout: Workout(
            id: UUID(fixture: 11),
            warmUp: [makeStage(1, seconds: 2)],
            training: [makeStage(2, seconds: 2)],
            pauseAfterWarmUp: true
        )
    )
    /// Work 2 s.
    static let short = WorkoutSchedule(workout: Workout(id: UUID(fixture: 12), training: [makeStage(1, seconds: 2)]))
    static let empty = WorkoutSchedule(workout: Workout(id: UUID(fixture: 13)))
}

/// A phase a table test starts from.
enum TimerPhase: CaseIterable, Sendable {
    case startCountdown
    case resumeCountdown
    case idle
    case running
    case paused
    case awaitingUser
    case finished
}

extension WorkoutTimerFeature.State {
    static func fresh(_ schedule: WorkoutSchedule = Schedules.workRest) -> Self {
        Self(id: timerID, title: "Workout", schedule: schedule)
    }

    /// The state the reducer leaves at `origin` in `phase` after the clock's first sync, without the loop itself.
    ///
    /// A run that has started did so `elapsed` seconds before `origin`. `.awaitingUser` needs a schedule with a
    /// manual pause.
    static func fixture(_ phase: TimerPhase, schedule: WorkoutSchedule = Schedules.workRest, elapsed: Double = 3) -> Self {
        var state = fresh(schedule)
        state.countdown = nil
        state.clockGeneration = 1
        switch phase {
            case .startCountdown:
                state.countdown = WorkoutTimerFeature.Countdown(.start)
            case .resumeCountdown:
                state.run.start(at: moment(-elapsed))
                state.run.pause(at: origin)
                state.countdown = WorkoutTimerFeature.Countdown(.resume)
            case .idle:
                break
            case .running:
                state.run.start(at: moment(-elapsed))
            case .paused:
                state.run.start(at: moment(-elapsed))
                state.run.pause(at: origin)
            case .awaitingUser, .finished:
                state.run.start(at: moment(-1_000))
        }
        state.settle(at: origin)
        if state.snapshot.status == .running {
            // Every `TestClock` starts at the same instant, so this reading matches the harness clock.
            state.clockAnchor = ClockAnchor(
                date: origin,
                instant: MonotonicInstant(now: TestClock<Duration>()),
                totalElapsed: state.snapshot.totalElapsed
            )
        }
        state.requestedAwake = state.keepsScreenAwake
        state.awakeRevision = state.requestedAwake ? 1 : 2
        return state
    }

    /// A run started `elapsed` seconds before `origin` on a screen that has not appeared yet.
    static func appearing(_ schedule: WorkoutSchedule = Schedules.workRest, elapsed: Double = 0) -> Self {
        var state = fresh(schedule)
        state.countdown = nil
        state.run.start(at: moment(-elapsed))
        state.settle(at: origin)
        return state
    }

    /// What the reducer commits before it acts: the run's progress at `now` and its snapshot.
    mutating func settle(at now: Date) {
        run.tick(at: now)
        snapshot = run.snapshot(at: now)
    }
}

/// What the timer asked of the outside world, in order.
enum TimerCall: Equatable, Sendable {
    case requestAwake(owner: UUID, awake: Bool, revision: Int)
    case end(owner: UUID)
    case dismiss

    static func awake(_ awake: Bool, _ revision: Int) -> Self {
        .requestAwake(owner: timerID, awake: awake, revision: revision)
    }
}

struct ClockFailure: Error {}

/// A `TestClock` whose next `failures` sleeps throw.
struct FailingClock: Clock {
    let base: TestClock<Duration>
    let failures: LockIsolated<Int>

    var now: TestClock<Duration>.Instant {
        base.now
    }

    var minimumResolution: Duration {
        base.minimumResolution
    }

    func sleep(until deadline: TestClock<Duration>.Instant, tolerance: Duration?) async throws {
        let fails = failures.withValue { count in
            defer { count = max(count - 1, 0) }
            return count > 0
        }
        if fails { throw ClockFailure() }

        try await base.sleep(until: deadline, tolerance: tolerance)
    }
}

/// A clock that wakes every sleeper `lateness` after its deadline and records the deadlines; never suspends.
struct LateClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Self {
            Self(offset: offset + duration)
        }

        func duration(to other: Self) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    let lateness: Duration
    let state = LockIsolated((now: Instant(offset: .zero), deadlines: [Instant]()))

    var now: Instant {
        state.value.now
    }

    var minimumResolution: Duration {
        .zero
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        state.withValue {
            $0.deadlines.append(deadline)
            $0.now = deadline.advanced(by: lateness)
        }
    }
}

/// A timer store with a test clock, a movable wall clock and a recorder for the session and `dismiss`.
@MainActor
final class TimerHarness {
    let clock: TestClock<Duration>
    let wall: LockIsolated<Date>
    let calls: LockIsolated<[TimerCall]>
    let ended: LockIsolated<Set<UUID>>
    /// How many of the next sleeps fail.
    let failures: LockIsolated<Int>
    let store: TestStoreOf<WorkoutTimerFeature>

    init(_ state: WorkoutTimerFeature.State) {
        let clock = TestClock<Duration>()
        let wall = LockIsolated(origin)
        let calls = LockIsolated<[TimerCall]>([])
        let ended = LockIsolated<Set<UUID>>([])
        let failures = LockIsolated(0)
        self.clock = clock
        self.wall = wall
        self.calls = calls
        self.ended = ended
        self.failures = failures
        store = TestStore(initialState: state) {
            WorkoutTimerFeature()
        } withDependencies: {
            $0.continuousClock = FailingClock(base: clock, failures: failures)
            $0.date = DateGenerator { wall.value }
            $0.dismiss = DismissEffect { calls.withValue { $0.append(.dismiss) } }
            $0.timerSession = TimerSessionClient(
                requestAwake: { owner, awake, revision in
                    calls.withValue { $0.append(.requestAwake(owner: owner, awake: awake, revision: revision)) }
                },
                end: { owner in
                    calls.withValue { $0.append(.end(owner: owner)) }
                    ended.withValue { _ = $0.insert(owner) }
                },
                isEnded: { owner in
                    ended.value.contains(owner)
                }
            )
        }
    }

    var now: Date {
        wall.value
    }

    /// Moves both clocks together, the wall clock first: a loop reads the date as soon as it wakes.
    func advance(seconds: Double) async {
        wall.withValue { $0 = $0.addingTimeInterval(seconds) }
        await clock.advance(by: .seconds(seconds))
    }

    /// Moves only the wall clock, like a change of the system time.
    func moveWall(seconds: Double) {
        wall.withValue { $0 = $0.addingTimeInterval(seconds) }
    }

    /// Sends the first `.task` to a running state, which starts the tick loop of generation 1.
    func appearRunning() async {
        await store.send(.view(.task)) {
            $0.clockGeneration = 1
            $0.clockAnchor = self.anchor(totalElapsed: $0.snapshot.totalElapsed)
            $0.requestedAwake = true
            $0.awakeRevision = 1
        }
    }

    /// Cancels the clock loop a test left running once it has asserted everything it checks.
    func cancelClockLoop() async {
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.skipInFlightEffects(strict: false)
    }

    /// The anchor the reducer takes now.
    func anchor(totalElapsed: Duration) -> ClockAnchor {
        ClockAnchor(date: now, instant: MonotonicInstant(now: clock), totalElapsed: totalElapsed)
    }
}
