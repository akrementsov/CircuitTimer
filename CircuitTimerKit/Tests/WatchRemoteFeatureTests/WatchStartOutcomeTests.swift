@testable import WatchRemoteFeature

import ComposableArchitecture
import Foundation
import Testing
import WatchLink
import WorkoutDomain

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WatchStartOutcomeTests {
    @Test(arguments: [
        (WatchStartResult.openPhoneApp, WatchRemoteFeature.StartNote.openPhoneApp, false),
        (.busy, .busy, false),
        (.listUnavailable, .listUnavailable, true),
        (.changed, .changed, true),
        (.gone, .gone, true),
        (.notPlayable, .notPlayable, true),
    ])
    func test_refusal_keepsItsMessageAndInvalidWorkoutsRequireNewSelection(
        result: WatchStartResult, note: WatchRemoteFeature.StartNote, closes: Bool
    ) async {
        let clock = TestClock<Duration>()
        let catalog = watchCatalog("Morning")
        var state = stateShowing(catalog, digest: "A")
        state.path.append(.selected(id: UUID(watch: 1), fingerprint: catalog.entries[0].scheduleFingerprint))
        state.start = .init(id: UUID(0), beganAt: MonotonicInstant(now: clock))
        let store = makeWatchStore(state, clock: clock)
        let envelope = WatchReplyEnvelope(requestID: UUID(0), reply: .start(result, phoneState(sequence: 1, digest: "A")))

        await store.send(.internal(.startAnswered(sentID: UUID(0), envelope))) {
            $0.start = nil
            $0.startNote = note
            if closes { $0.path.removeAll() }
        }
        await store.finish()
    }

    @Test
    func test_acceptedFromForeignProcess_preservesFollowedProcessAndDoesNotOpenLease() async {
        let clock = TestClock<Duration>()
        var state = stateShowing(watchCatalog("Morning"), digest: "A")
        state.link = unreachable
        state.start = .init(id: UUID(0), beganAt: MonotonicInstant(now: clock))
        let store = makeWatchStore(state, clock: clock)
        let foreign = phoneState(process: 2, sequence: 0)
        let envelope = WatchReplyEnvelope(requestID: UUID(0), reply: .start(.accepted(asksOnPhone: false), foreign))

        await store.send(.internal(.startAnswered(sentID: UUID(0), envelope))) {
            _ = $0.order.receive(foreign, from: .message)
            $0.start?.stage = .waiting(asksOnPhone: false)
        }
        #expect(store.state.order.processID == UUID(watch: 101))
        #expect(store.state.lease == nil)
        await store.send(.view(.scenePhaseChanged(.background))) {
            $0.isSceneActive = false
            $0.start = nil
        }
        await store.finish()
    }
}
