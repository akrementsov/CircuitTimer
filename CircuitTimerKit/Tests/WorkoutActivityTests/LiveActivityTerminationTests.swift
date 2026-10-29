@testable import WorkoutActivity

import Dependencies
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LiveActivityTerminationTests {
    private let fake = FakeTransport()
    private let clock = TestClock<Duration>()
    private let gate = TerminationGate()
    private let coordinator: LiveActivityCoordinator
    private static let owner = UUID(fixture: 1)
    private static let other = UUID(fixture: 2)
    private static let attributes = Attributes(workoutName: "Morning")

    init() {
        coordinator = LiveActivityCoordinator(transport: fake.transport, gate: gate)
    }

    private func sync(_ content: Content, revision: Int, owner: UUID = owner) async -> LiveActivitySyncResult {
        await coordinator.syncWithResult(
            owner: owner,
            revision: revision,
            attributes: Self.attributes,
            content: content,
            clock: clock
        )
    }

    private func endAll() async {
        await coordinator.endAll(clock: clock)
    }

    @Test
    func test_endAll_tombstonesEveryOwnerAndEndsTheirActivitiesBeforeTheSecondPass() async {
        _ = await sync(.held(1), revision: 1)
        _ = await sync(.held(1), revision: 1, owner: Self.other)

        await endAll()

        let calls = fake.calls.value
        #expect(calls.contains(.endEvery))
        #expect(calls.last == .endEveryAgain)
        let beforeSecondPass = calls.dropLast()
        #expect(beforeSecondPass.contains(.end("activity-1", nil, .immediate)))
        #expect(beforeSecondPass.contains(.end("activity-2", nil, .immediate)))
        #expect(await sync(.held(2), revision: 2).outcome == .superseded)
        #expect(fake.calls.value == calls)
    }

    @Test
    func test_endAll_withoutOwners_stillEndsEveryActivityTwice() async {
        await endAll()

        #expect(fake.calls.value == [.endEvery, .endEveryAgain])
    }

    @Test
    func test_endAll_secondPassWaitsForTheDrainsUnderWay() async {
        _ = await sync(.held(1), revision: 1)
        let drain = Gate()
        fake.endGate.setValue(drain)
        let ending = Task { await endAll() }
        await drain.entered.next()
        await Task.megaYield()
        #expect(fake.calls.value.contains(.endEvery))
        #expect(!fake.calls.value.contains(.endEveryAgain))

        drain.open()
        await ending.value

        #expect(fake.calls.value.suffix(2) == [.end("activity-1", nil, .immediate), .endEveryAgain])
    }

    @Test
    func test_endAll_cancelledCaller_returnsAtOnceAndTheSecondPassStillRuns() async {
        let secondPass = Gate()
        fake.endEveryGate.setValue(secondPass)
        let ending = Task { await endAll() }
        await secondPass.entered.next()

        ending.cancel()
        await ending.value
        #expect(!fake.calls.value.contains(.endEveryAgain))

        secondPass.open()
        while !fake.calls.value.contains(.endEveryAgain) {
            await Task.megaYield()
        }
    }

    @Test
    func test_sync_requestRefusedForTermination_isSupersededAndNotBroken() async {
        fake.requestFailures.setValue([.terminating])

        #expect(await sync(.held(1), revision: 1).outcome == .superseded)
        #expect(await sync(.held(2), revision: 2).outcome == .applied)
        #expect(fake.calls.value == [.request(.held(1)), .request(.held(2))])
    }

    @Test
    func test_sync_closedGate_isSupersededWithoutTouchingTheActivity() async {
        _ = await sync(.held(1), revision: 1)

        gate.close()

        #expect(await sync(.held(2), revision: 2).outcome == .superseded)
        #expect(await sync(.held(1), revision: 1, owner: Self.other).outcome == .superseded)
        #expect(fake.calls.value == [.request(.held(1))])
    }

    @Test
    func test_completionSignal_waitReturnsOnCompletionBeforeOrAfterItAndOnCancellation() async {
        let early = CompletionSignal()
        early.complete()
        await early.wait()

        let late = CompletionSignal()
        let waiting = Task { await late.wait() }
        await Task.megaYield()
        late.complete()
        await waiting.value

        let never = CompletionSignal()
        let cancelled = Task { await never.wait() }
        cancelled.cancel()
        await cancelled.value
    }
}
