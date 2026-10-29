@testable import WorkoutActivity
@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import Testing

@MainActor
@Suite
struct TimerActivityTeardownTests {
    @Test
    func test_close_pendingIntent_endsItsOwnerAndReleasesTheActualDelivery() async throws {
        let ended = LockIsolated<[String]>([])
        let transport = ActivityTransport(
            isEnabled: { true },
            request: { _, _ in "rendered" },
            update: { _, _ in Issue.record("Closing must not update a card.") },
            end: { id, _, _ in ended.withValue { $0.append(id) } },
            endEvery: { _ in Issue.record("Closing must not end every activity.") },
            forget: { _ in },
            presence: { _ in .alive },
            allIDs: { ["rendered"] }
        )
        let coordinator = LiveActivityCoordinator(transport: transport)
        let clock = TestClock<Duration>()
        let requests = await coordinator.requests(owner: timerID)
        var iterator = requests.makeAsyncIterator()
        _ = await coordinator.sync(
            owner: timerID,
            revision: 1,
            attributes: WorkoutActivityAttributes(workoutName: "Workout"),
            content: WorkoutActivityAttributes.ContentState(run: WorkoutTimerFeature.State.fixture(.paused).run, at: origin),
            clock: clock
        )
        let delivery = Task { await coordinator.deliver(activityID: "rendered", command: .resume, generation: 7, clock: clock) }
        let request = try #require(await iterator.next())
        var state = WorkoutTimerFeature.State.fixture(.finished)
        state.activityControls = WorkoutTimerFeature.ActivityControlState(isReady: true, generation: 8)
        state.activityControls?.pending = WorkoutTimerFeature.PendingActivityControl(id: request.id, result: .applied, activityRevision: 2)
        let timer = TimerHarness(state)
        let activity = timer.recordActivity()
        let end = timer.store.dependencies.liveActivity.end
        timer.store.dependencies.liveActivity.end = { owner in
            await coordinator.end(owner: owner, clock: clock)
            await end(owner)
        }
        timer.store.dependencies.liveActivity.requestHandled = { owner, id, result in
            await coordinator.requestHandled(owner: owner, requestID: id, result: result)
        }
        await timer.send(.view(.closeButtonTapped), saving: true) {
            $0.clockGeneration = 2
            $0.isClosing = true
            $0.activityControls?.isEnding = true
        }
        await timer.store.finish()
        #expect(await delivery.value == .unavailable)
        #expect(await iterator.next() == nil)
        #expect(ended.value == ["rendered"])
        #expect(activity.syncs.value.isEmpty)
        #expect(timer.calls.value == [.end(owner: timerID), .endLiveActivity(owner: timerID), .dismiss])
    }
}
