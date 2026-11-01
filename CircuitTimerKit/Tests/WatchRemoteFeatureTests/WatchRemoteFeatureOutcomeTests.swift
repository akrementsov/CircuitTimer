@testable import WatchRemoteFeature

import ComposableArchitecture
import Foundation
import SwiftUI
import Testing
import WatchLink

/// How each end of a request, and each state the iPhone sends, changes what the watch shows and whether it asks again.
@MainActor
@Suite
struct WatchRemoteFeatureOutcomeTests {
    private static let current = UUID(watch: 50)
    private static let finished = UUID(watch: 49)

    enum Outcome: String, CaseIterable, Sendable {
        case answered, timedOut, unreachable, linkTimedOut, payloadTooLarge, failed
        case incompatible, companionMissing, inactive, unreadable, wrongID

        var spendsNeedsRefresh: Bool {
            switch self {
                case .answered, .timedOut, .unreachable, .linkTimedOut, .payloadTooLarge, .failed: true
                case .incompatible, .companionMissing, .inactive, .unreadable, .wrongID: false
            }
        }

        func action(for id: UUID) -> WatchRemoteFeature.Action {
            switch self {
                case .answered: .internal(.refreshAnswered(sentID: id, reply(id, phoneState(sequence: 1))))
                case .timedOut: .internal(.refreshTimedOut(sentID: id))
                case .unreachable: .internal(.refreshFailed(sentID: id, .unreachable))
                case .linkTimedOut: .internal(.refreshFailed(sentID: id, .timedOut))
                case .payloadTooLarge: .internal(.refreshFailed(sentID: id, .payloadTooLarge))
                case .failed: .internal(.refreshFailed(sentID: id, .failed))
                case .incompatible: .internal(.refreshFailed(sentID: id, .incompatible(peerSchemaVersion: nil)))
                case .companionMissing: .internal(.refreshFailed(sentID: id, .companionMissing))
                case .inactive: .internal(.refreshFailed(sentID: id, .inactive))
                case .unreadable: .internal(.refreshAnswered(sentID: id, .unreadable))
                case .wrongID: .internal(.refreshAnswered(sentID: id, reply(UUID(watch: 99), phoneState(sequence: 1))))
            }
        }
    }

    /// An open scene, a reachable iPhone and a request in flight.
    private static func asking(needsRefresh: Bool = false) -> WatchRemoteFeature.State {
        var state = WatchRemoteFeature.State()
        state.link = reachable
        state.isSceneActive = true
        state.refresh.inFlight = current
        state.refresh.needsRefresh = needsRefresh
        return state
    }

    /// A store whose requests never end, so a test sees each one start and nothing after it.
    private static func heldStore(
        _ state: WatchRemoteFeature.State,
        sent: SentRequests,
        clock: TestClock<Duration> = TestClock()
    ) -> TestStoreOf<WatchRemoteFeature> {
        TestStore(initialState: state) {
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
    }

    @Test(arguments: Outcome.allCases)
    func test_requestEnds_reasonWaiting_asksOnceMoreOnlyWhenTheEndMayPass(outcome: Outcome) async {
        let sent = SentRequests()
        let store = Self.heldStore(Self.asking(needsRefresh: true), sent: sent)
        store.exhaustivity = .off

        await store.send(outcome.action(for: Self.current))

        if outcome.spendsNeedsRefresh {
            #expect(store.state.refresh.inFlight == UUID(0))
            #expect(!store.state.refresh.needsRefresh)
            #expect(sent.requests.value.count == 1)
            await store.skipInFlightEffects()
        } else {
            #expect(store.state.refresh.inFlight == nil)
            #expect(store.state.refresh.needsRefresh)
            #expect(sent.requests.value.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func test_reason_sceneInactiveOrIPhoneOutOfReach_asksNothingAndKeepsNoFlag(sceneActive: Bool) async {
        let sent = SentRequests()
        var state = stateShowing(watchCatalog("Morning"), digest: "A")
        state.isSceneActive = sceneActive
        state.link = sceneActive ? unreachable : reachable
        let store = Self.heldStore(state, sent: sent)
        store.exhaustivity = .off

        await store.send(.internal(.event(.message(phoneState(sequence: 2, digest: "B")))))

        #expect(store.state.refresh.inFlight == nil)
        #expect(!store.state.refresh.needsRefresh)
        #expect(sent.requests.value.isEmpty)
    }

    /// With a request in flight the flag is set before the scene and the link are checked, so the reason survives a
    /// link that went away meanwhile.
    @Test
    func test_reason_requestInFlightIPhoneOutOfReach_setsTheFlag() async {
        let sent = SentRequests()
        var state = stateShowing(watchCatalog("Morning"), digest: "A")
        state.refresh.inFlight = Self.current
        state.link = unreachable
        let store = Self.heldStore(state, sent: sent)
        store.exhaustivity = .off

        await store.send(.internal(.event(.message(phoneState(sequence: 2, digest: "B")))))

        #expect(store.state.refresh.inFlight == Self.current)
        #expect(store.state.refresh.needsRefresh)
        #expect(sent.requests.value.isEmpty)
    }

    /// A request started for another reason cancels the retry scheduled before it: the store would fail on its
    /// `retryDue` five seconds later.
    @Test
    func test_newRequest_afterARetryWasScheduled_cancelsTheRetry() async {
        let clock = TestClock()
        let store = Self.heldStore(Self.asking(), sent: SentRequests(), clock: clock)

        await store.send(.internal(.refreshFailed(sentID: Self.current, .unreachable))) {
            $0.refresh.inFlight = nil
            $0.refresh.failures = 1
            $0.refresh.retryGeneration = 1
            $0.problem = .unreachable
        }
        await store.send(.internal(.statusRead(reachable))) {
            $0.refresh.inFlight = UUID(0)
            $0.refresh.retryGeneration = 2
        }
        await clock.advance(by: .seconds(5))
        await store.send(.view(.scenePhaseChanged(.inactive))) {
            $0.isSceneActive = false
            $0.refresh.inFlight = nil
        }
    }

    @Test
    func test_retryDue_olderGeneration_changesNothing() async {
        let sent = SentRequests()
        var state = Self.asking()
        state.refresh.inFlight = nil
        state.refresh.retryGeneration = 3
        let store = Self.heldStore(state, sent: sent)

        await store.send(.internal(.retryDue(2)))
        #expect(sent.requests.value.isEmpty)
        await store.send(.internal(.retryDue(3))) {
            $0.refresh.inFlight = UUID(0)
            $0.refresh.retryGeneration = 4
        }

        #expect(sent.requests.value.count == 1)
        store.exhaustivity = .off
        await store.skipInFlightEffects()
    }

    /// Every action of a finished request, and a second answer to the current one, leaves the state as it is.
    @Test
    func test_actionsOfAFinishedRequest_changeNothing() async {
        let store = Self.heldStore(Self.asking(), sent: SentRequests())
        let late = reply(Self.finished, phoneState(sequence: 9, catalog: .loaded(watchCatalog("Late")), digest: "L"))

        await store.send(.internal(.refreshAnswered(sentID: Self.finished, late)))
        await store.send(.internal(.refreshFailed(sentID: Self.finished, .unreachable)))
        await store.send(.internal(.refreshTimedOut(sentID: Self.finished)))
        await store.send(.internal(.refreshFailed(sentID: Self.current, .companionMissing))) {
            $0.refresh.inFlight = nil
            $0.problem = .companionMissing
        }
        await store.send(.internal(.refreshAnswered(sentID: Self.current, reply(Self.current, phoneState(sequence: 1)))))
    }

    /// An answer before the timeout cancels it: the store would fail on a timeout it did not expect.
    @Test
    func test_answer_beforeTheTimeout_cancelsIt() async {
        let clock = TestClock()
        let sent = SentRequests()
        let answered = phoneState(sequence: 1, catalog: .loaded(watchCatalog("Morning")), digest: "A", at: later)
        sent.answer.setValue { reply($0, answered) }
        var state = WatchRemoteFeature.State()
        state.link = reachable
        state.isSceneActive = true
        let store = makeWatchStore(state, sent: sent, clock: clock)

        await store.send(.internal(.statusRead(reachable))) {
            $0.refresh.inFlight = UUID(0)
            $0.refresh.retryGeneration = 1
        }
        await store.receive(\.internal.refreshAnswered) {
            $0.refresh.inFlight = nil
            $0.refresh.hasAnswered = true
            _ = $0.order.receive(answered, from: .reply)
            $0.catalog = .init(lastLoaded: watchCatalog("Morning"), updatedAt: later)
        }
        await clock.advance(by: .seconds(10))
    }

    @Test
    func test_reply_equalSequence_confirmsAndMovesTheTime() async {
        let sent = SentRequests()
        let catalog = watchCatalog("Morning")
        sent.answer.setValue { reply($0, phoneState(sequence: 5, digest: "A", at: later)) }
        let store = makeWatchStore(stateShowing(catalog, digest: "A", sequence: 5), sent: sent)
        store.exhaustivity = .off

        await store.send(.internal(.statusRead(reachable)))
        await store.receive(\.internal.refreshAnswered)

        #expect(store.state.catalog == .init(lastLoaded: catalog, updatedAt: later))
        #expect(sent.requests.value.count == 1)
    }

    @Test
    func test_sendThrowsOutsideTheLink_failsTheRequest() async {
        struct Other: Error {}
        let sent = SentRequests()
        sent.answer.setValue { _ in throw Other() }
        var state = WatchRemoteFeature.State()
        state.link = reachable
        state.isSceneActive = true
        let store = makeWatchStore(state, sent: sent)
        store.exhaustivity = .off

        await store.send(.internal(.statusRead(reachable)))
        await store.receive(.internal(.refreshFailed(sentID: UUID(0), .failed)))

        #expect(store.state.problem == .failed)
        await store.skipInFlightEffects()
    }

    /// A cancelled send reports nothing: the store would fail on an action it did not expect.
    @Test
    func test_sendCancelled_reportsNothing() async {
        let sent = SentRequests()
        sent.answer.setValue { _ in throw CancellationError() }
        var state = WatchRemoteFeature.State()
        state.link = reachable
        state.isSceneActive = true
        let store = makeWatchStore(state, sent: sent)

        await store.send(.internal(.statusRead(reachable))) {
            $0.refresh.inFlight = UUID(0)
            $0.refresh.retryGeneration = 1
        }
        await Task.megaYield()
        await store.send(.view(.scenePhaseChanged(.inactive))) {
            $0.isSceneActive = false
            $0.refresh.inFlight = nil
        }

        #expect(sent.requests.value.count == 1)
    }

    @Test
    func test_context_unavailableThenLoaded_dimsTheListThenReplacesIt() async {
        let first = watchCatalog("Morning")
        let second = watchCatalog("Evening")
        let store = makeWatchStore(stateShowing(first, digest: "A"))
        store.exhaustivity = .off

        await store.send(.internal(.event(.context(phoneState(sequence: 2, catalog: .unavailable(.loadFailed), digest: "U", at: later)))))
        #expect(store.state.catalog == .init(lastLoaded: first, unavailable: .loadFailed, updatedAt: later))
        #expect(store.state.screen == .list(first, dimmed: .loadFailed, status: nil))

        await store.send(.internal(.event(.context(phoneState(sequence: 3, catalog: .loaded(second), digest: "B", at: later)))))
        #expect(store.state.catalog == .init(lastLoaded: second, updatedAt: later))
    }

    @Test
    func test_undecodable_thenAnAcceptedState_setsThenClearsTheProblem() async {
        let store = makeWatchStore(stateShowing(watchCatalog("Morning"), digest: "A"))
        store.exhaustivity = .off

        await store.send(.internal(.event(.undecodable(peerSchemaVersion: 2))))
        #expect(store.state.problem == .incompatible(.watch))
        await store.send(.internal(.event(.context(phoneState(sequence: 2, catalog: .loaded(watchCatalog("Evening")), digest: "B")))))

        #expect(store.state.problem == nil)
    }

    @Test
    func test_active_withoutALinkChange_resetsFailuresAndAMissingCompanion() async {
        let sent = SentRequests()
        var state = WatchRemoteFeature.State()
        state.link = reachable
        state.refresh.failures = 2
        state.problem = .companionMissing
        let store = Self.heldStore(state, sent: sent)

        await store.send(.view(.scenePhaseChanged(.active))) {
            $0.isSceneActive = true
            $0.refresh.failures = 0
            $0.problem = nil
        }
        await store.receive(\.internal.statusRead) {
            $0.refresh.inFlight = UUID(0)
            $0.refresh.retryGeneration = 1
        }

        #expect(sent.requests.value.count == 1)
        store.exhaustivity = .off
        await store.skipInFlightEffects()
    }
}
