@testable import WatchRemoteFeature

import ComposableArchitecture
import Foundation
import Testing
import WatchLink
import WorkoutDomain

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WatchStartTests {
    private let catalog = watchCatalog("Morning")

    private func pending(_ clock: TestClock<Duration>) -> WatchRemoteFeature.StartRequest {
        WatchRemoteFeature.StartRequest(id: UUID(0), beganAt: MonotonicInstant(now: clock))
    }

    @Test
    func test_start_backWhileSending_keepsRequestAndWaitsThirtyFiveSecondsAfterAccepted() async throws {
        let clock = TestClock<Duration>()
        var state = stateShowing(catalog, digest: "A")
        state.path.append(.selected(id: UUID(watch: 1), fingerprint: catalog.entries[0].scheduleFingerprint))
        let selected = try #require(state.path.ids.last)
        let sent = SentRequests()
        let current = phoneState(sequence: 1, digest: "A")
        let held = HeldReplies()
        let store = makeWatchStore(state, sent: sent, clock: clock) {
            $0.phoneCompanion.send = { id, request in
                sent.requests.withValue { $0.append(request) }
                return try await held.send(id)
            }
        }

        await store.send(.view(.startButtonTapped)) { $0.start = self.pending(clock) }
        await store.send(.path(.popFrom(id: selected))) { $0.path.removeAll() }
        await held.answer { id in WatchReplyEnvelope(requestID: id, reply: .start(.accepted(asksOnPhone: true), current)) }
        await store.receive(\.internal.startAnswered) {
            $0.start?.stage = .waiting(asksOnPhone: true)
            $0.start?.timeoutGeneration = 1
        }
        #expect(store.state.startStatus == .asksOnPhone)
        #expect(sent.requests.value == [
            .start(workoutID: UUID(watch: 1), scheduleFingerprint: catalog.entries[0].scheduleFingerprint, knownCatalogDigest: "A"),
        ])
        await clock.advance(by: .seconds(35))
        await store.receive(\.internal.startTimedOut) {
            $0.start = nil
            $0.startNote = .checkPhone
        }
        await store.finish()
    }

    @Test
    func test_start_replyOvertakenByNewerState_stillAppliesItsOwnAdmission() async {
        let clock = TestClock<Duration>()
        var state = stateShowing(catalog, digest: "A", sequence: 5)
        state.start = pending(clock)
        let store = makeWatchStore(state, clock: clock)
        let old = phoneState(sequence: 1, digest: "A")
        let envelope = WatchReplyEnvelope(requestID: UUID(0), reply: .start(.accepted(asksOnPhone: false), old))

        await store.send(.internal(.startAnswered(sentID: UUID(0), envelope))) {
            $0.start?.stage = .waiting(asksOnPhone: false)
            $0.start?.timeoutGeneration = 1
        }
        #expect(store.state.order.lastSequence == 5)
        #expect(store.state.lease == nil)
        await store.send(.view(.scenePhaseChanged(.background))) {
            $0.isSceneActive = false
            $0.start = nil
        }
        await store.finish()
    }

    @Test
    func test_start_unknownDigestAndLateOldReply_cannotSendOrReviveARequest() async {
        let clock = TestClock<Duration>()
        var state = stateShowing(catalog, digest: "A")
        state.path.append(.selected(id: UUID(watch: 1), fingerprint: catalog.entries[0].scheduleFingerprint))
        _ = state.order.receive(phoneState(sequence: 2, digest: "B"), from: .message)
        let sent = SentRequests()
        let store = makeWatchStore(state, sent: sent, clock: clock)
        await store.send(.view(.startButtonTapped))
        #expect(!store.state.canStartSelected)
        #expect(sent.requests.value.isEmpty)
        let envelope = WatchReplyEnvelope(requestID: UUID(0), reply: .start(.accepted(asksOnPhone: true), phoneState(sequence: 3)))
        await store.send(.internal(.startAnswered(sentID: UUID(0), envelope)))
        #expect(store.state.start == nil)
        await store.finish()
    }

    @Test
    func test_start_catalogChangesDuringRequest_closesSelectionButKeepsPending() async {
        let clock = TestClock<Duration>()
        var state = stateShowing(catalog, digest: "A")
        state.link = unreachable
        state.path.append(.selected(id: UUID(watch: 1), fingerprint: catalog.entries[0].scheduleFingerprint))
        state.start = pending(clock)
        let store = makeWatchStore(state, clock: clock)
        let empty = WatchCatalog(entries: [])
        let changed = phoneState(sequence: 2, catalog: .loaded(empty), digest: "B")
        await store.send(.internal(.event(.message(changed)))) {
            _ = $0.order.receive(changed, from: .message)
            $0.catalog = .init(lastLoaded: empty, updatedAt: earlier)
            $0.path.removeAll()
        }
        #expect(store.state.startStatus == .sending)
        await store.send(.view(.scenePhaseChanged(.background))) {
            $0.isSceneActive = false
            $0.start = nil
        }
        await store.finish()
    }

    @Test
    func test_start_runOvertakesAccepted_keepsRunAndClearsWaitingWithoutOpeningLease() async {
        let clock = TestClock<Duration>()
        var state = stateShowing(catalog, digest: "A")
        state.link = unreachable
        state.start = pending(clock)
        let store = makeWatchStore(state, clock: clock)
        let run = heldRun(.paused(heldStage))
        let published = runState(sequence: 2, run: run)
        await store.send(.internal(.event(.message(published)))) {
            _ = $0.order.receive(published, from: .message)
            $0.run = .init(run: run, isLive: true)
            $0.runGeneration = 1
            $0.start = nil
        }
        let accepted = WatchReplyEnvelope(requestID: UUID(0), reply: .start(.accepted(asksOnPhone: false), phoneState(sequence: 1)))
        await store.send(.internal(.startAnswered(sentID: UUID(0), accepted)))
        #expect(store.state.run?.run == run)
        #expect(store.state.startStatus == nil)
        #expect(store.state.lease == nil)
        await store.finish()
    }
}
