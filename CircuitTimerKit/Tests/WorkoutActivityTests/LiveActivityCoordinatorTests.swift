@testable import WorkoutActivity

import Dependencies
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LiveActivityCoordinatorTests {
    private let fake = FakeTransport()
    private let clock = TestClock<Duration>()
    private let coordinator: LiveActivityCoordinator
    private static let owner = UUID(fixture: 1)
    private static let other = UUID(fixture: 2)
    private static let attributes = Attributes(workoutName: "Morning")

    init() {
        coordinator = LiveActivityCoordinator(transport: fake.transport)
    }

    private func sync(
        _ content: Content,
        revision: Int,
        owner: UUID = owner,
        attributes: Attributes = attributes
    ) async -> LiveActivityNotice? {
        await coordinator.sync(owner: owner, revision: revision, attributes: attributes, content: content, clock: clock)
    }

    private func end(_ owner: UUID = owner) async {
        await coordinator.end(owner: owner, clock: clock)
    }

    // MARK: - The main path

    @Test
    func test_sync_first_requestsOnceAndShowsWithoutNotice() async {
        let notice = await sync(.held(1), revision: 1)

        #expect(notice == nil)
        #expect(fake.calls.value == [.request(.held(1))])
    }

    @Test
    func test_sync_changedContent_updatesAndSameContentSendsNothing() async {
        _ = await sync(.held(1), revision: 1)
        _ = await sync(.held(2), revision: 2)
        _ = await sync(.held(2), revision: 3)

        #expect(fake.calls.value == [.request(.held(1)), .update("activity-1", .held(2))])
    }

    @Test
    func test_sync_finished_endsWithTheFinalCardAndLaterSyncsLeaveIt() async {
        _ = await sync(.held(1), revision: 1)
        _ = await sync(.finished, revision: 2)
        fake.presence.withValue { $0["activity-1"] = .gone }
        _ = await sync(.finished, revision: 3)
        _ = await sync(.held(5), revision: 4)

        #expect(fake.calls.value == [.request(.held(1)), .end("activity-1", .finished, .standard)])
    }

    @Test(arguments: [false, true])
    func test_end_shownActivity_removesItAtOnce(isFinished: Bool) async {
        _ = await sync(.held(1), revision: 1)
        if isFinished {
            _ = await sync(.finished, revision: 2)
        }

        await end()

        #expect(fake.calls.value.last == .end("activity-1", nil, .immediate))
    }

    @Test
    func test_endOrphans_endsOnlyActivitiesNoOwnerHolds() async {
        await coordinator.endOrphans()
        #expect(fake.calls.value.isEmpty)

        fake.presence.withValue { $0["old"] = .alive }
        _ = await sync(.held(1), revision: 1)
        await coordinator.endOrphans()

        #expect(fake.calls.value == [.request(.held(1)), .end("old", nil, .immediate)])
    }

    // MARK: - Edge cases

    @Test
    func test_sync_notNewerRevision_isIgnored() async {
        _ = await sync(.held(1), revision: 2)

        #expect(await sync(.held(2), revision: 2) == nil)
        #expect(await sync(.held(3), revision: 1) == nil)
        #expect(fake.calls.value == [.request(.held(1))])
    }

    @Test
    func test_sync_afterEnd_isRefused() async {
        await end()

        #expect(await sync(.held(1), revision: 1) == nil)
        #expect(fake.calls.value.isEmpty)
    }

    @Test
    func test_sync_activitiesOff_startsNothingUntilTurnedOn() async {
        fake.isEnabled.setValue(false)
        #expect(await sync(.held(1), revision: 1) == nil)
        #expect(fake.calls.value.isEmpty)

        fake.isEnabled.setValue(true)
        _ = await sync(.held(2), revision: 2)

        #expect(fake.calls.value == [.request(.held(2))])
    }

    @Test
    func test_sync_finishedBeforeAnyActivity_startsNone() async {
        #expect(await sync(.finished, revision: 1) == nil)
        #expect(fake.calls.value.isEmpty)
    }

    @Test
    func test_end_withoutActivity_returnsAtOnceWithoutTransport() async {
        // The test clock never advances, so a wait for the timeout would never return.
        await end()

        #expect(fake.calls.value.isEmpty)
    }

    @Test
    func test_endOrphans_afterTheOwnerLostItsActivity_mayEndTheFormerID() async {
        _ = await sync(.held(1), revision: 1)
        fake.presence.withValue { $0["activity-1"] = .gone }
        _ = await sync(.held(2), revision: 2)

        await coordinator.endOrphans()

        #expect(fake.calls.value == [.request(.held(1)), .forget("activity-1"), .end("activity-1", nil, .immediate)])
    }

    // MARK: - Failures and the footnote

    @Test
    func test_sync_denied_showsNothingWithoutNotice() async {
        fake.requestFailures.setValue([.denied])

        #expect(await sync(.held(1), revision: 1) == nil)
    }

    @Test
    func test_sync_visibility_defersAndTriesAgain() async {
        fake.requestFailures.setValue([.visibility])

        #expect(await sync(.held(1), revision: 1) == nil)
        #expect(await sync(.held(2), revision: 2) == nil)
        #expect(fake.calls.value == [.request(.held(1)), .request(.held(2))])
    }

    @Test
    func test_sync_permanentFailure_warnsAndStopsTrying() async {
        fake.requestFailures.setValue([.permanent("unentitled")])

        #expect(await sync(.held(1), revision: 1) == LiveActivityNotice(serial: 1, isFailing: true))
        #expect(await sync(.held(2), revision: 2) == nil)
        #expect(fake.calls.value == [.request(.held(1))])
    }

    @Test
    func test_sync_transientFailure_warnsAndTriesAgain() async {
        fake.requestFailures.setValue([.transient("global maximum")])

        #expect(await sync(.held(1), revision: 1) == LiveActivityNotice(serial: 1, isFailing: true))
        #expect(await sync(.held(2), revision: 2) == LiveActivityNotice(serial: 2, isFailing: false))
        #expect(fake.calls.value == [.request(.held(1)), .request(.held(2))])
    }

    @Test
    func test_sync_sizeLimit_allowsExactly4096BytesAndRefusesMore() async throws {
        let base = try Attributes(workoutName: "").encodedSize(with: .held(1))
        let exact = Attributes(workoutName: String(repeating: "a", count: Attributes.encodedSizeLimit - base))
        let over = Attributes(workoutName: String(repeating: "a", count: Attributes.encodedSizeLimit - base + 1))

        #expect(await sync(.held(1), revision: 1, owner: Self.other, attributes: exact) == nil)
        #expect(await sync(.held(1), revision: 1, attributes: over) == LiveActivityNotice(serial: 1, isFailing: true))
        #expect(await sync(.held(1), revision: 2) == nil)
        #expect(fake.calls.value == [.request(.held(1))])
    }

    @Test
    func test_sync_overLimitUpdate_endsTheActivityForGood() async {
        let over = Attributes(workoutName: String(repeating: "a", count: Attributes.encodedSizeLimit))
        _ = await sync(.held(1), revision: 1)

        #expect(await sync(.held(2), revision: 2, attributes: over) == LiveActivityNotice(serial: 1, isFailing: true))
        #expect(await sync(.held(3), revision: 3) == nil)
        #expect(fake.calls.value == [.request(.held(1)), .end("activity-1", nil, .immediate)])
    }

    @Test(arguments: [ActivityPresence?.some(.gone), nil])
    func test_sync_shownActivityWent_forgetsItAndNeverAsksAgain(presence: ActivityPresence?) async {
        _ = await sync(.held(1), revision: 1)
        fake.presence.withValue { $0["activity-1"] = presence }

        #expect(await sync(.held(2), revision: 2) == nil)
        fake.isEnabled.setValue(false)
        _ = await sync(.held(3), revision: 3)
        fake.isEnabled.setValue(true)
        _ = await sync(.held(4), revision: 4)

        #expect(fake.calls.value == [.request(.held(1)), .forget("activity-1")])
    }

    @Test
    func test_sync_activityNeverListed_endsItLazilyAfterTenSecondsAndAsksAgain() async {
        fake.listsOnRequest.setValue(false)
        #expect(await sync(.held(1), revision: 1) == nil)

        await clock.advance(by: .milliseconds(9_900))
        #expect(await sync(.held(2), revision: 2) == nil)
        #expect(await sync(.held(2), revision: 3) == nil)
        await clock.advance(by: .milliseconds(100))
        #expect(fake.calls.value == [.request(.held(1)), .update("activity-1", .held(2))])

        #expect(await sync(.held(3), revision: 4) == LiveActivityNotice(serial: 1, isFailing: true))
        fake.listsOnRequest.setValue(true)
        #expect(await sync(.held(4), revision: 5) == LiveActivityNotice(serial: 2, isFailing: false))

        #expect(fake.calls.value == [
            .request(.held(1)),
            .update("activity-1", .held(2)),
            .end("activity-1", nil, .immediate),
            .request(.held(4)),
        ])
    }

    @Test
    func test_sync_activityListedBeforeTheDeadline_staysShown() async {
        fake.listsOnRequest.setValue(false)
        _ = await sync(.held(1), revision: 1)
        fake.presence.withValue { $0["activity-1"] = .alive }
        _ = await sync(.held(2), revision: 2)

        await clock.advance(by: .seconds(10))
        #expect(await sync(.held(3), revision: 3) == nil)

        #expect(fake.calls.value == [.request(.held(1)), .update("activity-1", .held(2)), .update("activity-1", .held(3))])
    }

    @Test(arguments: [ClearingCause.activitiesOff, .denied])
    func test_sync_afterATransientFailure_unavailableClearsTheWarning(cause: ClearingCause) async {
        fake.requestFailures.setValue(cause == .denied ? [.transient("busy"), .denied, .denied] : [.transient("busy")])
        #expect(await sync(.held(1), revision: 1) == LiveActivityNotice(serial: 1, isFailing: true))
        if cause == .activitiesOff {
            fake.isEnabled.setValue(false)
        }

        #expect(await sync(.held(2), revision: 2) == LiveActivityNotice(serial: 2, isFailing: false))
        #expect(await sync(.held(3), revision: 3) == nil)
    }

    @Test
    func test_sync_deferredAfterAFailure_keepsTheWarning() async {
        fake.requestFailures.setValue([.transient("busy"), .visibility])
        #expect(await sync(.held(1), revision: 1) == LiveActivityNotice(serial: 1, isFailing: true))

        #expect(await sync(.held(2), revision: 2) == nil)
        #expect(await sync(.held(3), revision: 3) == LiveActivityNotice(serial: 2, isFailing: false))
    }

    // MARK: - Concurrency

    @Test
    func test_sync_burst_appliesTheNewestAfterTheOneInFlight() async {
        _ = await sync(.held(1), revision: 1)
        let gate = Gate()
        fake.updateGate.setValue(gate)
        let first = Task { await sync(.held(2), revision: 2) }
        await gate.entered.next()
        let second = Task { await sync(.held(3), revision: 3) }
        let third = Task { await sync(.held(4), revision: 4) }
        await Task.megaYield()

        gate.open()

        #expect(await first.value == nil)
        #expect(await second.value == nil)
        #expect(await third.value == nil)
        #expect(fake.calls.value == [.request(.held(1)), .update("activity-1", .held(2)), .update("activity-1", .held(4))])
    }

    @Test
    func test_end_withAQueuedSync_dropsItAndEnds() async {
        _ = await sync(.held(1), revision: 1)
        let gate = Gate()
        fake.updateGate.setValue(gate)
        let inFlight = Task { await sync(.held(2), revision: 2) }
        await gate.entered.next()
        let queued = Task { await sync(.held(3), revision: 3) }
        await Task.megaYield()
        let ending = Task { await end() }
        await Task.megaYield()

        gate.open()
        await ending.value

        #expect(await inFlight.value == nil)
        #expect(await queued.value == nil)
        #expect(fake.calls.value == [.request(.held(1)), .update("activity-1", .held(2)), .end("activity-1", nil, .immediate)])
    }

    @Test
    func test_end_twiceAtOnce_endsTheActivityOnce() async {
        _ = await sync(.held(1), revision: 1)

        async let first: Void = end()
        async let second: Void = end()
        _ = await (first, second)

        #expect(fake.calls.value == [.request(.held(1)), .end("activity-1", nil, .immediate)])
    }

    @Test
    func test_end_slowerThanTheBound_returnsAndFinishesInTheBackground() async {
        _ = await sync(.held(1), revision: 1)
        let gate = Gate()
        fake.endGate.setValue(gate)
        let ending = Task { await end() }
        await gate.entered.next()

        await clock.advance(by: LiveActivityCoordinator.endTimeout)
        await ending.value
        #expect(fake.calls.value == [.request(.held(1))])

        gate.open()
        await end()
        #expect(fake.calls.value == [.request(.held(1)), .end("activity-1", nil, .immediate)])
    }

    @Test
    func test_end_cancelledCaller_stopsWaitingButTheActivityStillEnds() async {
        _ = await sync(.held(1), revision: 1)
        let gate = Gate()
        fake.endGate.setValue(gate)
        let ending = Task { await end() }
        await gate.entered.next()

        ending.cancel()
        await ending.value
        gate.open()
        await end()

        #expect(fake.calls.value == [.request(.held(1)), .end("activity-1", nil, .immediate)])
    }

    @Test
    func test_sync_cancelledCaller_stillRequests() async {
        let syncing = Task { await sync(.held(1), revision: 1) }
        syncing.cancel()
        _ = await syncing.value

        #expect(fake.calls.value == [.request(.held(1))])
    }

    @Test
    func test_owners_areIndependent() async {
        _ = await sync(.held(1), revision: 1)
        _ = await sync(.held(1), revision: 1, owner: Self.other)

        await end()
        _ = await sync(.held(2), revision: 2, owner: Self.other)

        #expect(fake.calls.value == [
            .request(.held(1)),
            .request(.held(1)),
            .end("activity-1", nil, .immediate),
            .update("activity-2", .held(2)),
        ])
    }

    @Test
    func test_endOrphans_racingANewOwner_neverEndsItsActivity() async {
        async let syncing = sync(.held(1), revision: 1)
        async let cleaning: Void = coordinator.endOrphans()
        _ = await (syncing, cleaning)

        #expect(fake.calls.value == [.request(.held(1))])
    }
}

enum ClearingCause: Sendable {
    case activitiesOff
    case denied
}
