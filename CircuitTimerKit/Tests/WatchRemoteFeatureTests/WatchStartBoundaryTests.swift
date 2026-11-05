@testable import WatchRemoteFeature

import ComposableArchitecture
import Foundation
import Testing
import WatchLink
import WorkoutDomain

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WatchStartBoundaryTests {
    private let catalog = watchCatalog("Morning", "Evening")

    private func selected() -> WatchRemoteFeature.State {
        var state = stateShowing(catalog, digest: "A")
        state.path.append(.selected(id: UUID(watch: 1), fingerprint: catalog.entries[0].scheduleFingerprint))
        return state
    }

    enum Blocker: CaseIterable, Sendable {
        case incompatible, inactive, noLink, unreachable, pending, run, largeRun, unconfirmed, noSelection
    }

    @Test(arguments: Blocker.allCases)
    func test_startButton_blocked_sendsNothing(blocker: Blocker) async {
        let clock = TestClock<Duration>()
        var state = selected()
        switch blocker {
            case .incompatible: state.problem = .incompatible(.watch)
            case .inactive: state.isSceneActive = false
            case .noLink: state.link = nil
            case .unreachable: state.link = unreachable
            case .pending: state.start = .init(id: UUID(watch: 50), beganAt: MonotonicInstant(now: clock))
            case .run: state.run = .init(run: heldRun(.paused(heldStage)), isLive: false)
            case .largeRun: state.isRunTooLarge = true
            case .unconfirmed: _ = state.order.receive(phoneState(sequence: 2, digest: "B"), from: .message)
            case .noSelection: state.path.removeAll()
        }
        #expect(!state.canStartSelected)
        let sent = SentRequests()
        let store = makeWatchStore(state, sent: sent, clock: clock)
        if blocker == .incompatible || blocker == .run || blocker == .largeRun {
            await store.send(.view(.startButtonTapped)) { $0.path.removeAll() }
        } else {
            await store.send(.view(.startButtonTapped))
        }
        #expect(sent.requests.value.isEmpty)
        if blocker == .pending {
            await store.send(.view(.scenePhaseChanged(.background))) {
                $0.isSceneActive = false
                $0.start = nil
            }
        }
        await store.finish()
    }

    enum SelectionCase: CaseIterable, Sendable {
        case noCatalog, noLoaded, unavailable, gone, changed, notPlayable, ready, unconfirmed
    }

    @Test(arguments: SelectionCase.allCases)
    func test_selection_catalogBoundary_obeysPriority(variant: SelectionCase) {
        var state = selected()
        let entry = catalog.entries[0]
        let expected: WatchRemoteFeature.State.Selection
        switch variant {
            case .noCatalog:
                state.catalog = nil
                expected = .unavailable
            case .noLoaded:
                state.catalog?.lastLoaded = nil
                expected = .unavailable
            case .unavailable:
                state.catalog?.unavailable = .loadFailed
                state.catalog?.lastLoaded = WatchCatalog(entries: [])
                expected = .unavailable
            case .gone:
                state.catalog?.lastLoaded = WatchCatalog(entries: [])
                expected = .gone
            case .changed, .notPlayable:
                state.catalog?.lastLoaded = WatchCatalog(entries: [
                    WatchCatalog.Entry(
                        id: entry.id,
                        name: entry.name,
                        totalMilliseconds: 0,
                        isPlayable: false,
                        scheduleFingerprint: variant == .changed ? "changed" : entry.scheduleFingerprint
                    ),
                ])
                expected = variant == .changed ? .changed : .notPlayable
            case .ready:
                expected = .ready(entry)
            case .unconfirmed:
                _ = state.order.receive(phoneState(sequence: 2, digest: "B"), from: .message)
                expected = .unconfirmed(entry)
        }
        #expect(state.selection(id: entry.id, fingerprint: entry.scheduleFingerprint) == expected)
    }

    @Test
    func test_selectionStatus_catalogStatus_isIndependentOfButtonAndPending() {
        var state = selected()
        state.problem = .failed
        #expect(state.canStartSelected)
        #expect(state.selectionStatus == .failed(updatedAt: earlier))
        #expect(state.startStatus == nil)
        #expect(state.screen == .list(catalog, dimmed: nil, status: .failed(updatedAt: earlier)))
        state.problem = nil
        _ = state.order.receive(phoneState(sequence: 2, digest: "B"), from: .message)
        #expect(state.selectionStatus == nil)
        #expect(!state.canStartSelected)
        _ = state.order.receive(phoneState(sequence: 3, digest: "A"), from: .reply)
        #expect(state.canStartSelected)
        state.start = .init(id: UUID(watch: 50), beganAt: MonotonicInstant(now: TestClock<Duration>()))
        #expect(!state.canStartSelected)
        #expect(state.selectionStatus == nil)
        #expect(state.startStatus == .sending)
        state.start = nil
        state.isSceneActive = false
        #expect(!state.canStartSelected)
        #expect(state.selectionStatus == nil)
        state.catalog = nil
        #expect(state.selectionStatus == nil)
    }

    @Test(arguments: [false, true])
    func test_accepted_recordsBothWaitingStatesWithoutGrantingCatalogFreshness(asks: Bool) async {
        let clock = TestClock<Duration>()
        var state = selected()
        state.link = unreachable
        _ = state.order.receive(phoneState(sequence: 2, digest: "B"), from: .message)
        state.start = .init(id: UUID(watch: 50), beganAt: MonotonicInstant(now: clock))
        let store = makeWatchStore(state, clock: clock)
        let envelope = WatchReplyEnvelope(requestID: UUID(watch: 50), reply: .start(
            .accepted(asksOnPhone: asks), phoneState(sequence: 3)
        ))
        await store.send(.internal(.startAnswered(sentID: UUID(watch: 50), envelope))) {
            _ = $0.order.receive(phoneState(sequence: 3), from: .reply)
            $0.start?.stage = .waiting(asksOnPhone: asks)
            $0.start?.timeoutGeneration = 1
        }
        #expect(!store.state.order.vouchesForCatalog)
        #expect(store.state.startStatus == (asks ? .asksOnPhone : .starting))
        #expect(!store.state.path.isEmpty)
        await store.send(.view(.scenePhaseChanged(.background))) {
            $0.isSceneActive = false
            $0.start = nil
        }
        await store.finish()
    }

    @Test(arguments: [
        PhoneLinkError.failed, .unreachable,
        .incompatible(peerSchemaVersion: nil), .incompatible(peerSchemaVersion: WatchLinkSchema.version + 1),
    ])
    func test_send_failure_reportsNeutralOutcomeOrUpdate(error: PhoneLinkError) async {
        let clock = TestClock<Duration>()
        let sent = SentRequests()
        sent.answer.setValue { _ in throw error }
        let store = makeWatchStore(selected(), sent: sent, clock: clock)
        await store.send(.view(.startButtonTapped)) {
            $0.start = .init(id: UUID(0), beganAt: MonotonicInstant(now: clock))
        }
        await store.receive(.internal(.startFailed(sentID: UUID(0), error))) {
            $0.start = nil
            if case let .incompatible(version) = error {
                $0.problem = .incompatible(version == nil ? .phone : .watch)
                $0.path.removeAll()
            } else {
                $0.startNote = .checkPhone
            }
        }
        #expect(sent.requests.value.count == 1)
        await store.finish()
    }

    @Test(arguments: [false, true])
    func test_reply_mismatchedEnvelope_closesSelectionAndRequestsUpdate(wrongID: Bool) async {
        let clock = TestClock<Duration>()
        var state = selected()
        state.start = .init(id: UUID(watch: 50), beganAt: MonotonicInstant(now: clock))
        let store = makeWatchStore(state, clock: clock)
        let envelope = WatchReplyEnvelope(
            requestID: wrongID ? UUID(watch: 51) : UUID(watch: 50),
            reply: wrongID
                ? .start(.accepted(asksOnPhone: false), phoneState(sequence: 2))
                : .state(phoneState(sequence: 2))
        )
        await store.send(.internal(.startAnswered(sentID: UUID(watch: 50), envelope))) {
            $0.start = nil
            $0.path.removeAll()
            $0.problem = .incompatible(.phone)
        }
        await store.finish()
    }

    @Test
    func test_waiting_lateReplyFailureAndOldUUIDTimeout_doNotRestartWait() async {
        let clock = TestClock<Duration>()
        var state = selected()
        state.start = .init(
            id: UUID(watch: 50),
            beganAt: MonotonicInstant(now: clock),
            stage: .waiting(asksOnPhone: false),
            timeoutGeneration: 1
        )
        let store = makeWatchStore(state, clock: clock)
        let envelope = WatchReplyEnvelope(requestID: UUID(watch: 50), reply: .start(.busy, phoneState(sequence: 2)))
        await store.send(.internal(.startAnswered(sentID: UUID(watch: 50), envelope)))
        await store.send(.internal(.startFailed(sentID: UUID(watch: 50), .failed)))
        await store.send(.internal(.startTimedOut(sentID: UUID(watch: 49), generation: 1)))
        await store.send(.internal(.startAnswered(sentID: UUID(watch: 49), envelope)))
        await store.send(.internal(.startFailed(sentID: UUID(watch: 49), .failed)))
        #expect(store.state.start == state.start)
        await store.send(.internal(.startTimedOut(sentID: UUID(watch: 50), generation: 1))) {
            $0.start = nil
            $0.startNote = .checkPhone
        }
        await store.finish()
    }

    @Test(arguments: [false, true])
    func test_anyAction_elapsedMonotonicDeadline_clearsPendingWithoutTimeoutAction(waiting: Bool) async {
        let clock = TestClock<Duration>()
        var state = selected()
        state.start = .init(
            id: UUID(watch: 50),
            beganAt: MonotonicInstant(now: clock),
            stage: waiting ? .waiting(asksOnPhone: false) : .sending
        )
        let store = makeWatchStore(state, clock: clock)
        await clock.advance(by: .seconds(waiting ? 35 : 10))
        await store.send(.view(.scenePhaseChanged(.inactive))) {
            $0.start = nil
            $0.startNote = .checkPhone
        }
        await store.finish()
    }

    @Test
    func test_start_secondTapAndBackground_preserveOneSendThenCancelLocalWait() async {
        let clock = TestClock<Duration>()
        let held = HeldReplies()
        let sent = SentRequests()
        let store = makeWatchStore(selected(), sent: sent, clock: clock) {
            $0.phoneCompanion.send = { id, request in
                sent.requests.withValue { $0.append(request) }
                return try await held.send(id)
            }
        }
        await store.send(.view(.startButtonTapped)) {
            $0.start = .init(id: UUID(0), beganAt: MonotonicInstant(now: clock))
        }
        await held.waiting.wait { $0.count == 1 }
        await store.send(.view(.startButtonTapped))
        await store.send(.view(.scenePhaseChanged(.inactive)))
        #expect(store.state.startStatus == .sending)
        #expect(sent.requests.value.count == 1)
        await store.send(.view(.scenePhaseChanged(.background))) {
            $0.isSceneActive = false
            $0.start = nil
        }
        await held.waiting.wait { $0.isEmpty }
        await clock.advance(by: .seconds(40))
        await store.finish()
    }
}
