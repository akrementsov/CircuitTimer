@testable import WatchRemoteFeature

import ComposableArchitecture
import Foundation
import TestSupport
import WatchLink
import WorkoutActivity
import WorkoutDomain

/// A running stage that ends `endsIn` seconds after `now`; another `stage` is other content of the same timer.
func runningRun(owner: Int = 1, stage: String = "Work", endsIn seconds: Double = 30, at now: Date = earlier) -> WatchRun {
    WatchRun(
        owner: UUID(watch: 200 + owner),
        attributes: WorkoutActivityAttributes(workoutName: "Morning"),
        content: WorkoutActivityAttributes.ContentState(phase: .running(WorkoutActivityAttributes.Running(
            stage: WorkoutActivityAttributes.Stage(kind: .work, name: stage),
            stageStart: now.addingTimeInterval(seconds - 60),
            stageEnd: now.addingTimeInterval(seconds),
            next: .finish
        )))
    )
}

func heldRun(owner: Int = 1, _ phase: WorkoutActivityAttributes.Phase) -> WatchRun {
    WatchRun(
        owner: UUID(watch: 200 + owner),
        attributes: WorkoutActivityAttributes(workoutName: "Morning"),
        content: WorkoutActivityAttributes.ContentState(phase: phase)
    )
}

let heldStage = WorkoutActivityAttributes.HeldStage(
    stage: WorkoutActivityAttributes.Stage(kind: .work, name: "Work"),
    remainingMilliseconds: 20_000
)

/// A state of the iPhone with `run`, under the list of digest `A` the watch already shows.
func runState(
    process: Int = 1,
    sequence: Int,
    run: WatchRun?,
    live: Bool = true,
    tooLarge: Bool = false,
    digest: String = "A",
    at date: Date = earlier
) -> PhoneState {
    PhoneState(
        processID: UUID(watch: 100 + process),
        sequence: sequence,
        publishedAt: date,
        catalog: nil,
        catalogDigest: digest,
        run: run,
        isRunLive: live,
        isRunTooLarge: tooLarge
    )
}

/// Replies the test gives one at a time, so it decides when each request is answered.
final class HeldReplies: Sendable {
    /// The requests waiting for a reply, oldest first.
    let waiting = Observed<[UUID]>([])
    private let continuations = LockIsolated<[UUID: CheckedContinuation<WatchReplyEnvelope, any Error>]>([:])
    private let cancelled = LockIsolated<Set<UUID>>([])

    func send(_ id: UUID) async throws -> WatchReplyEnvelope {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !cancelled.value.contains(id) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                continuations.withValue { $0[id] = continuation }
                waiting.withValue { $0.append(id) }
            }
        } onCancel: {
            cancelled.withValue { _ = $0.insert(id) }
            waiting.withValue { $0.removeAll { $0 == id } }
            continuations.withValue { $0.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    /// Answers the oldest waiting request with `state`, once one waits; returns its ID.
    @discardableResult
    func answer(_ state: PhoneState) async -> UUID {
        await answer { reply($0, state) }
    }

    @discardableResult
    func answer(_ envelope: @Sendable (UUID) -> WatchReplyEnvelope) async -> UUID {
        await waiting.wait { !$0.isEmpty }
        let id = waiting.withValue { $0.removeFirst() }
        continuations.withValue { $0.removeValue(forKey: id) }?.resume(returning: envelope(id))
        return id
    }

    /// Fails the oldest waiting request with `error`, once one waits; returns its ID.
    @discardableResult
    func fail(_ error: any Error) async -> UUID {
        await waiting.wait { !$0.isEmpty }
        let id = waiting.withValue { $0.removeFirst() }
        continuations.withValue { $0.removeValue(forKey: id) }?.resume(throwing: error)
        return id
    }
}

/// A watch store over a list of digest `A`, in front and in reach, with a test clock, a movable wall clock and
/// replies the test gives.
@MainActor
final class RunHarness {
    let clock = TestClock<Duration>()
    let wall = LockIsolated(earlier)
    let replies = HeldReplies()
    let sent = LockIsolated<[WatchRequest]>([])
    let store: TestStoreOf<WatchRemoteFeature>

    /// `hasAnswered: false` for a watch the iPhone has not answered yet.
    init(_ state: WatchRemoteFeature.State? = nil, hasAnswered: Bool = true) {
        var initial = state ?? stateShowing(watchCatalog("Morning"), digest: "A")
        initial.refresh.hasAnswered = hasAnswered
        let (clock, wall, replies, sent) = (clock, wall, replies, sent)
        store = TestStore(initialState: initial) {
            WatchRemoteFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = clock
            $0.date = DateGenerator { wall.value }
            $0.phoneCompanion.status = { reachable }
            $0.phoneCompanion.send = { id, request in
                sent.withValue { $0.append(request) }
                return try await replies.send(id)
            }
        }
        store.exhaustivity = .off
    }

    var now: Date {
        wall.value
    }

    var state: WatchRemoteFeature.State {
        store.state
    }

    /// How many requests the reducer started, counted synchronously: the send itself runs in an effect.
    var requests: Int {
        store.state.refresh.lastSerial
    }

    /// Moves both clocks together, the wall clock first.
    func advance(seconds: Double) async {
        wall.withValue { $0 = $0.addingTimeInterval(seconds) }
        await clock.advance(by: .milliseconds(Int(seconds * 1_000)))
    }

    /// Shows `run` from a context of `sequence` (the list came in 1), then confirms it with the reply to the request the context started,
    /// `afterSeconds` after its send.
    func confirm(_ run: WatchRun, sequence: Int = 2, afterSeconds elapsed: Double = 0) async {
        await store.send(.internal(.event(.context(runState(sequence: sequence, run: run)))))
        await advance(seconds: elapsed)
        await replies.answer(runState(sequence: sequence + 1, run: run))
        await store.receive(\.internal.refreshAnswered)
    }

    func screen() -> WatchRemoteFeature.State.RunScreen? {
        guard case let .run(screen) = store.state.screen else { return nil }
        return screen
    }

    /// Stops tracking whatever effects are left, if any.
    func finish() async {
        await store.skipInFlightEffects(strict: false)
    }
}

extension WatchRemoteFeature.State {
    /// The list of digest `A`, in front and in reach, showing `run` from a context of `sequence`; `lease` opens one by
    /// request 1 at the test clock's start, 10 s from `earlier`; `inFlight` adds a request sent then.
    static func showing(
        _ run: WatchRun,
        sequence: Int = 2,
        live: Bool = true,
        lease: Bool = false,
        inFlight: Bool = false
    ) -> Self {
        var state = stateShowing(watchCatalog("Morning"), digest: "A")
        state.refresh.hasAnswered = true
        _ = state.order.receive(runState(sequence: sequence, run: run, live: live), from: .context)
        state.run = WatchRemoteFeature.ShownRun(run: run, isLive: live)
        state.runGeneration = 1
        if lease {
            state.refresh.lastSerial = 1
            state.lease = WatchRemoteFeature.Lease(
                serial: 1,
                sentAt: MonotonicInstant(now: TestClock<Duration>()),
                openedAt: earlier,
                deadline: earlier.addingTimeInterval(10)
            )
        }
        if inFlight {
            state.refresh.lastSerial += 1
            state.refresh.inFlight = .sent(UUID(watch: 9), serial: state.refresh.lastSerial)
        }
        return state
    }
}
