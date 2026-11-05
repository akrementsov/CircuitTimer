@testable import WatchRemoteFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WatchStartRegressionTests {
    @Test
    func test_queuedSendingTimeout_doesNotEndAcceptedWaitForSameUUID() async {
        let clock = TestClock<Duration>()
        var state = stateShowing(watchCatalog("Morning"), digest: "A")
        state.start = .init(
            id: UUID(0),
            beganAt: MonotonicInstant(now: clock),
            stage: .waiting(asksOnPhone: true),
            timeoutGeneration: 1
        )
        let store = makeWatchStore(state, clock: clock)

        await store.send(.internal(.startTimedOut(sentID: UUID(0), generation: 0)))
        #expect(store.state.startStatus == .asksOnPhone)
        await store.send(.internal(.startTimedOut(sentID: UUID(0), generation: 1))) {
            $0.start = nil
            $0.startNote = .checkPhone
        }
        await store.finish()
    }

    @Test(arguments: [WatchRemoteFeature.StartNote.changed, .busy])
    func test_selectingAnotherWorkout_clearsPreviousOutcome(note: WatchRemoteFeature.StartNote) async {
        let catalog = watchCatalog("Morning", "Evening")
        var state = stateShowing(catalog, digest: "A")
        state.startNote = note
        let store = makeWatchStore(state)

        await store.send(.view(.workoutTapped(UUID(watch: 2)))) {
            $0.startNote = nil
            $0.path.append(.selected(id: UUID(watch: 2), fingerprint: catalog.entries[1].scheduleFingerprint))
        }
        #expect(store.state.startStatus == nil)
        await store.finish()
    }

    @Test
    func test_selectingAnotherWorkout_whileStartPending_keepsStatusOnRoot() async {
        let clock = TestClock<Duration>()
        var state = stateShowing(watchCatalog("Morning", "Evening"), digest: "A")
        state.start = .init(id: UUID(0), beganAt: MonotonicInstant(now: clock))
        let store = makeWatchStore(state, clock: clock)

        await store.send(.view(.workoutTapped(UUID(watch: 2))))
        #expect(store.state.path.isEmpty)
        #expect(store.state.startStatus == .sending)
        await store.send(.view(.scenePhaseChanged(.background))) {
            $0.isSceneActive = false
            $0.start = nil
        }
        await store.finish()
    }
}
