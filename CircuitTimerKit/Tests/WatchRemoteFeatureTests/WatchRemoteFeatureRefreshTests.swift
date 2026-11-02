@testable import WatchRemoteFeature

import ComposableArchitecture
import Foundation
import SwiftUI
import Testing
import WatchLink

@MainActor
@Suite
struct WatchRemoteFeatureRefreshTests {
    /// The order `.active` → `.status(canSend)` → `statusRead`: the status event lands between the activation and
    /// its status read, so the read meets a request in flight. The activation is the initial state, since the read
    /// is synchronous and a test store cannot hold it back; the read must neither send nor queue a second request.
    @Test
    func test_open_activeThenStatusThenStatusRead_sendsOneRequestWithoutDigest() async {
        let sent = SentRequests()
        var state = WatchRemoteFeature.State()
        state.isSceneActive = true
        let store = TestStore(initialState: state) {
            WatchRemoteFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.phoneCompanion.send = { _, request in
                sent.requests.withValue { $0.append(request) }
                try await Task.never()
                throw CancellationError()
            }
        }

        await store.send(.internal(.event(.status(reachable)))) {
            $0.link = reachable
            $0.refresh.inFlight = UUID(0)
            $0.refresh.retryGeneration = 1
        }
        await store.send(.internal(.statusRead(reachable)))

        #expect(store.state.refresh.needsRefresh == false)
        #expect(sent.requests.value == [.refresh(knownCatalogDigest: nil)])
        store.exhaustivity = .off
        await store.skipInFlightEffects()
    }

    @Test
    func test_statusThenActive_sendsOneRequest() async {
        let sent = SentRequests()
        let store = makeWatchStore(sent: sent)
        store.exhaustivity = .off

        let catalog = watchCatalog("Morning")
        sent.answer.setValue { reply($0, phoneState(sequence: 1, catalog: .loaded(catalog), digest: "A")) }

        await store.send(.internal(.event(.status(reachable))))
        await store.send(.view(.scenePhaseChanged(.active)))
        await store.receive(\.internal.statusRead)
        await store.receive(\.internal.refreshAnswered)
        await store.send(.internal(.event(.status(reachable))))

        #expect(sent.requests.value == [.refresh(knownCatalogDigest: nil)])
        #expect(store.state.refresh.hasAnswered)
        #expect(store.state.screen == .list(catalog, dimmed: nil, status: nil))
    }

    @Test
    func test_contextWithoutCatalog_otherDigest_asksOnceWithTheStoredDigest() async {
        let sent = SentRequests()
        let catalog = watchCatalog("Morning")
        var state = stateShowing(catalog, digest: "A")
        state.refresh.hasAnswered = true
        sent.answer.setValue { reply($0, phoneState(sequence: 2, digest: "B")) }
        let store = makeWatchStore(state, sent: sent)
        store.exhaustivity = .off

        await store.send(.internal(.event(.context(phoneState(sequence: 2, digest: "B")))))
        await store.receive(\.internal.refreshAnswered)
        await store.send(.internal(.event(.context(phoneState(sequence: 2, digest: "B")))))
        await store.send(.internal(.event(.message(phoneState(process: 2, sequence: 1, digest: "B")))))
        await store.receive(\.internal.refreshAnswered)
        await store.send(.internal(.event(.message(phoneState(process: 2, sequence: 1, digest: "B")))))
        // The same process's next state with the same digest is another state, so it is asked about once more.
        await store.send(.internal(.event(.message(phoneState(process: 2, sequence: 2, digest: "B")))))
        await store.receive(\.internal.refreshAnswered)

        #expect(sent.requests.value == Array(repeating: .refresh(knownCatalogDigest: "A"), count: 3))
        #expect(store.state.catalog?.lastLoaded == catalog)
        #expect(store.state.catalog?.updatedAt == earlier)
    }

    @Test
    func test_reply_confirmingTheDigest_keepsTheListAndMovesItsTime() async {
        let sent = SentRequests()
        let catalog = watchCatalog("Morning")
        var state = stateShowing(catalog, digest: "A", inFront: false)
        // A newer process answered «unknown»: the list is marked as earlier.
        _ = state.order.receive(phoneState(process: 2, sequence: 0), from: .reply)
        #expect(state.screen == .list(catalog, dimmed: nil, status: .earlierList(updatedAt: earlier)))
        sent.answer.setValue { reply($0, phoneState(process: 2, sequence: 1, digest: "A", at: later)) }
        let store = makeWatchStore(state, sent: sent)
        store.exhaustivity = .off

        await store.send(.view(.scenePhaseChanged(.active)))
        await store.receive(\.internal.statusRead)
        await store.receive(\.internal.refreshAnswered)

        #expect(sent.requests.value.count == 1)
        #expect(store.state.catalog?.lastLoaded == catalog)
        #expect(store.state.catalog?.updatedAt == later)
        #expect(store.state.screen == .list(catalog, dimmed: nil, status: nil))
        #expect(store.state.refresh.inFlight == nil)
    }

    @Test
    func test_reply_unknownFromANewProcess_keepsTheListAsEarlierWithoutAsking() async {
        let sent = SentRequests()
        let catalog = watchCatalog("Morning")
        sent.answer.setValue { reply($0, phoneState(process: 2, sequence: 0)) }
        let store = makeWatchStore(stateShowing(catalog, digest: "A", inFront: false), sent: sent)
        store.exhaustivity = .off

        await store.send(.view(.scenePhaseChanged(.active)))
        await store.receive(\.internal.statusRead)
        await store.receive(\.internal.refreshAnswered)

        #expect(sent.requests.value.count == 1)
        #expect(store.state.screen == .list(catalog, dimmed: nil, status: .earlierList(updatedAt: earlier)))

        let newer = watchCatalog("Evening")
        await store.send(.internal(.event(.context(phoneState(process: 2, sequence: 1, catalog: .loaded(newer), digest: "B", at: later)))))
        #expect(store.state.screen == .list(newer, dimmed: nil, status: nil))
    }

    @Test
    func test_reply_olderSequenceAfterANewerContext_keepsTheContextsList() async {
        let sent = SentRequests()
        let clock = TestClock()
        let first = watchCatalog("First")
        let second = watchCatalog("Second")
        let answer = AsyncStream<WatchReplyEnvelope>.makeStream()
        let store = TestStore(initialState: stateShowing(first, digest: "A", sequence: 5, inFront: false)) {
            WatchRemoteFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = clock
            $0.phoneCompanion.status = { reachable }
            $0.phoneCompanion.send = { _, request in
                sent.requests.withValue { $0.append(request) }
                for await envelope in answer.stream {
                    return envelope
                }
                throw CancellationError()
            }
        }
        store.exhaustivity = .off

        await store.send(.view(.scenePhaseChanged(.active)))
        await store.receive(\.internal.statusRead)
        await store.send(.internal(.event(.context(phoneState(sequence: 7, catalog: .loaded(second), digest: "B", at: later)))))
        let answered = phoneState(sequence: 6, catalog: .loaded(first), digest: "A", at: later.addingTimeInterval(60))
        answer.continuation.yield(reply(UUID(0), answered))
        await store.receive(\.internal.refreshAnswered)

        #expect(store.state.catalog?.lastLoaded == second)
        #expect(store.state.catalog?.updatedAt == later)
        #expect(store.state.order.lastSequence == 7)
        #expect(store.state.refresh.inFlight == nil)
        #expect(sent.requests.value.count == 1)
    }

    @Test(arguments: [
        (PhoneLinkError.unreachable, WatchRemoteFeature.LinkProblem.unreachable, true),
        (.timedOut, .failed, true),
        (.payloadTooLarge, .failed, true),
        (.failed, .failed, true),
        (.inactive, .unreachable, false),
        (.companionMissing, .companionMissing, false),
        (.incompatible(peerSchemaVersion: nil), .incompatible(.phone), false),
        (.incompatible(peerSchemaVersion: 1), .incompatible(.phone), false),
        (.incompatible(peerSchemaVersion: 2), .incompatible(.watch), false),
    ])
    func test_refreshFailed_error_setsTheProblemAndRetriesOnlyWhenItMayPass(
        error: PhoneLinkError,
        problem: WatchRemoteFeature.LinkProblem,
        retries: Bool
    ) async {
        let sent = SentRequests()
        let clock = TestClock()
        sent.answer.setValue { _ in throw error }
        var state = WatchRemoteFeature.State()
        state.link = reachable
        state.isSceneActive = true
        let store = makeWatchStore(state, sent: sent, clock: clock)
        store.exhaustivity = .off

        await store.send(.internal(.statusRead(reachable)))
        await store.receive(\.internal.refreshFailed)
        #expect(store.state.problem == problem)
        // A reason that came while the request was in flight is spent only by a failure that retries.
        await clock.advance(by: .seconds(5))
        #expect(sent.requests.value.count == (retries ? 2 : 1))
        if retries {
            await store.skipReceivedActions()
            await store.skipInFlightEffects()
        }
    }

    @Test
    func test_retries_waitFiveTenTwentyThenTwentySeconds() async {
        let sent = SentRequests()
        let clock = TestClock()
        var state = WatchRemoteFeature.State()
        state.link = reachable
        state.isSceneActive = true
        let store = makeWatchStore(state, sent: sent, clock: clock)
        store.exhaustivity = .off

        await store.send(.internal(.statusRead(reachable)))
        for delay in [5, 10, 20, 20] {
            let before = sent.requests.value.count
            await clock.advance(by: .seconds(delay - 1))
            #expect(sent.requests.value.count == before)
            await clock.advance(by: .seconds(1))
            #expect(sent.requests.value.count == before + 1)
        }
        await store.skipReceivedActions()
        await store.skipInFlightEffects()
    }

    @Test
    func test_reply_wrongIDOrNoReply_isIncompatibleWithoutRetry() async {
        let clock = TestClock()
        let answers: [@Sendable (UUID) throws -> WatchReplyEnvelope] = [
            { _ in WatchReplyEnvelope.unreadable },
            { _ in reply(UUID(watch: 99), phoneState(sequence: 9, catalog: .loaded(watchCatalog("X")), digest: "X")) },
        ]
        for answer in answers {
            let problem = WatchRemoteFeature.LinkProblem.incompatible(.phone)
            let sent = SentRequests()
            sent.answer.setValue(answer)
            var state = WatchRemoteFeature.State()
            state.link = reachable
            state.isSceneActive = true
            let store = makeWatchStore(state, sent: sent, clock: clock)
            store.exhaustivity = .off

            await store.send(.internal(.statusRead(reachable)))
            await store.receive(\.internal.refreshAnswered)
            await clock.advance(by: .seconds(30))

            #expect(store.state.problem == problem)
            #expect(store.state.catalog == nil)
            #expect(store.state.refresh.inFlight == nil)
            #expect(sent.requests.value.count == 1)
        }
    }

    @Test
    func test_timeout_failsOnlyItsRequestAndRetries() async {
        let clock = TestClock()
        let sent = SentRequests()
        let store = TestStore(initialState: {
            var state = WatchRemoteFeature.State()
            state.link = reachable
            state.isSceneActive = true
            return state
        }()) {
            WatchRemoteFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = clock
            $0.phoneCompanion.status = { reachable }
            $0.phoneCompanion.send = { _, request in
                sent.requests.withValue { $0.append(request) }
                try await Task.never()
                throw CancellationError()
            }
        }
        store.exhaustivity = .off

        await store.send(.internal(.statusRead(reachable)))
        await store.send(.internal(.refreshTimedOut(sentID: UUID(watch: 42))))
        #expect(store.state.refresh.inFlight == UUID(0))
        await clock.advance(by: .seconds(10))
        await store.receive(\.internal.refreshTimedOut)
        #expect(store.state.problem == .failed)
        #expect(store.state.refresh.inFlight == nil)
        await clock.advance(by: .seconds(5))
        #expect(sent.requests.value.count == 2)
        await store.skipReceivedActions()
        await store.skipInFlightEffects()
    }

    @Test
    func test_sceneLeaves_dropsTheRequestAndTheReturnAsksAgain() async {
        let clock = TestClock()
        let sent = SentRequests()
        let store = TestStore(initialState: {
            var state = WatchRemoteFeature.State()
            state.link = reachable
            return state
        }()) {
            WatchRemoteFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = clock
            $0.phoneCompanion.status = { reachable }
            $0.phoneCompanion.send = { _, request in
                sent.requests.withValue { $0.append(request) }
                try await Task.never()
                throw CancellationError()
            }
        }
        store.exhaustivity = .off

        await store.send(.view(.scenePhaseChanged(.active)))
        await store.receive(\.internal.statusRead)
        #expect(store.state.refresh.inFlight == UUID(0))
        await store.send(.view(.scenePhaseChanged(.background)))
        #expect(store.state.refresh.inFlight == nil)
        let late = phoneState(sequence: 1, catalog: .loaded(watchCatalog("Late")), digest: "L")
        await store.send(.internal(.refreshAnswered(sentID: UUID(0), reply(UUID(0), late))))
        #expect(store.state.catalog == nil)
        await clock.advance(by: .seconds(10))

        await store.send(.view(.scenePhaseChanged(.active)))
        await store.receive(\.internal.statusRead)
        #expect(store.state.refresh.inFlight == UUID(1))
        #expect(sent.requests.value.count == 2)
        await store.skipInFlightEffects()
    }

    @Test
    func test_needsRefresh_aReasonDuringARequest_asksOnceMoreAfterIt() async {
        let sent = SentRequests()
        let catalog = watchCatalog("Morning")
        let answers = AsyncStream<WatchReplyEnvelope>.makeStream()
        let store = TestStore(initialState: stateShowing(catalog, digest: "A")) {
            WatchRemoteFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.phoneCompanion.status = { reachable }
            $0.phoneCompanion.send = { _, request in
                sent.requests.withValue { $0.append(request) }
                for await envelope in answers.stream {
                    return envelope
                }
                throw CancellationError()
            }
        }
        store.exhaustivity = .off

        await store.send(.internal(.statusRead(reachable)))
        await store.send(.internal(.event(.message(phoneState(process: 2, sequence: 1, digest: "B")))))
        #expect(store.state.refresh.needsRefresh)
        answers.continuation.yield(reply(UUID(0), phoneState(sequence: 1, digest: "A")))
        await store.receive(\.internal.refreshAnswered)
        #expect(sent.requests.value.count == 2)
        #expect(!store.state.refresh.needsRefresh)
        await store.skipInFlightEffects()
    }

    @Test
    func test_task_again_replacesTheEventReader() async {
        let streams = LockIsolated<[AsyncStream<PhoneLinkEvent>.Continuation]>([])
        let store = TestStore(initialState: WatchRemoteFeature.State()) {
            WatchRemoteFeature()
        } withDependencies: {
            $0.phoneCompanion.events = {
                let (stream, continuation) = AsyncStream.makeStream(of: PhoneLinkEvent.self)
                streams.withValue { $0.append(continuation) }
                return stream
            }
        }

        await store.send(.view(.task))
        await store.send(.view(.task))
        await Task.megaYield()
        streams.value.last?.yield(.status(unreachable))
        await store.receive(\.internal.event) { $0.link = unreachable }
        streams.value.first?.yield(.status(reachable))
        await Task.megaYield()
        streams.value.last?.finish()
        await store.finish()
    }
}
