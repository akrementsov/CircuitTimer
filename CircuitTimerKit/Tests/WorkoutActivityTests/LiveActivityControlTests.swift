@testable import WorkoutActivity

import Dependencies
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LiveActivityControlTests {
    private let fake = FakeTransport()
    private let clock = TestClock<Duration>()
    private static let owner = UUID(fixture: 1)
    private static let other = UUID(fixture: 2)

    private func show(_ coordinator: LiveActivityCoordinator, owner: UUID = owner) async {
        _ = await coordinator.sync(
            owner: owner, revision: 1, attributes: Attributes(workoutName: "Morning"), content: .held(1), clock: clock
        )
    }

    private func deliver(
        _ coordinator: LiveActivityCoordinator, activityID: String = "activity-1", command: LiveActivityCommand = .resume
    ) async -> LiveActivityControlResult {
        await coordinator.deliver(activityID: activityID, command: command, generation: 7, clock: clock)
    }

    @Test
    func test_deliver_orphan_endsOnlyTheTappedActivity() async {
        let coordinator = LiveActivityCoordinator(transport: fake.transport)
        fake.presence.setValue(["orphan": .alive, "other": .alive])

        #expect(await deliver(coordinator, activityID: "orphan") == .orphanEnded)
        #expect(fake.calls.value == [.end("orphan", nil, .immediate)])
    }

    @Test
    func test_deliver_extensionProcess_neverEndsTheAppsActivity() async {
        let coordinator = LiveActivityCoordinator(transport: fake.transport, isAppProcess: false)
        fake.presence.setValue(["orphan": .alive])

        #expect(await deliver(coordinator, activityID: "orphan") == .unavailable)
        #expect(fake.calls.value.isEmpty)
    }

    @Test
    func test_deliver_unknownActivity_doesNotReachTheTransport() async {
        let coordinator = LiveActivityCoordinator(transport: fake.transport)

        #expect(await deliver(coordinator, activityID: "missing") == .unavailable)
        #expect(fake.calls.value.isEmpty)
    }

    @Test
    func test_deliver_cancelledBeforeAdmission_doesNotRemoveTheOrphan() async {
        let coordinator = LiveActivityCoordinator(transport: fake.transport)
        fake.presence.setValue(["orphan": .alive])
        let gate = Gate()
        let delivery = Task {
            await gate.pass()
            return await deliver(coordinator, activityID: "orphan")
        }
        await gate.entered.next()
        delivery.cancel()
        gate.open()

        #expect(await delivery.value == .cancelled)
        #expect(fake.calls.value.isEmpty)
    }

    @Test
    func test_deliver_liveOwnerWithoutSubscription_doesNotEndItsCard() async {
        let coordinator = LiveActivityCoordinator(transport: fake.transport)
        await show(coordinator)

        #expect(await deliver(coordinator) == .unavailable)
        #expect(fake.calls.value == [.request(.held(1))])
    }

    @Test(arguments: [LiveActivityCommand.pause, .resume])
    func test_deliver_routesOneCommand_andOnlyItsOwnersAckReleasesIt(command: LiveActivityCommand) async throws {
        let coordinator = LiveActivityCoordinator(transport: fake.transport)
        let stream = await coordinator.requests(owner: Self.owner)
        var iterator = stream.makeAsyncIterator()
        await show(coordinator)
        let delivery = Task { await deliver(coordinator, command: command) }
        let request = try #require(await iterator.next())
        #expect(request.command == command)
        #expect(request.generation == 7)
        #expect(await deliver(coordinator) == .busy)

        await coordinator.requestHandled(owner: Self.other, requestID: request.id, result: .applied)
        await coordinator.requestHandled(owner: Self.owner, requestID: request.id + 1, result: .applied)
        #expect(await deliver(coordinator) == .busy)
        await coordinator.requestHandled(owner: Self.owner, requestID: request.id, result: .stale)

        #expect(await delivery.value == .stale)
        let next = Task { await deliver(coordinator) }
        let nextRequest = try #require(await iterator.next())
        #expect(nextRequest.id != request.id)
        await coordinator.requestHandled(owner: Self.owner, requestID: request.id, result: .applied)
        #expect(await deliver(coordinator) == .busy)
        await coordinator.requestHandled(owner: Self.owner, requestID: nextRequest.id, result: .applied)
        #expect(await next.value == .applied)
    }

    @Test(arguments: [false, true])
    func test_deliver_waitEndsButAdmissionStaysUntilAck(isCancelled: Bool) async throws {
        let coordinator = LiveActivityCoordinator(transport: fake.transport)
        let stream = await coordinator.requests(owner: Self.owner)
        var iterator = stream.makeAsyncIterator()
        await show(coordinator)
        let delivery = Task { await deliver(coordinator) }
        let request = try #require(await iterator.next())

        if isCancelled {
            delivery.cancel()
        } else {
            await clock.advance(by: LiveActivityCoordinator.controlTimeout)
        }
        #expect(await delivery.value == (isCancelled ? .cancelled : .timedOut))
        #expect(await deliver(coordinator) == .busy)
        await coordinator.requestHandled(owner: Self.owner, requestID: request.id, result: .applied)
        let next = Task { await deliver(coordinator) }
        let nextRequest = try #require(await iterator.next())
        await coordinator.requestHandled(owner: Self.owner, requestID: nextRequest.id, result: .applied)
        #expect(await next.value == .applied)
    }

    @Test
    func test_deliver_twoOwners_admitAndCompleteIndependently() async throws {
        let coordinator = LiveActivityCoordinator(transport: fake.transport)
        let first = await coordinator.requests(owner: Self.owner)
        let second = await coordinator.requests(owner: Self.other)
        var firstIterator = first.makeAsyncIterator()
        var secondIterator = second.makeAsyncIterator()
        await show(coordinator)
        await show(coordinator, owner: Self.other)

        let firstDelivery = Task { await deliver(coordinator) }
        let firstRequest = try #require(await firstIterator.next())
        let secondDelivery = Task { await deliver(coordinator, activityID: "activity-2", command: .pause) }
        let secondRequest = try #require(await secondIterator.next())
        #expect(secondRequest.command == .pause)
        #expect(await deliver(coordinator) == .busy)
        #expect(await deliver(coordinator, activityID: "activity-2") == .busy)

        await coordinator.requestHandled(owner: Self.other, requestID: secondRequest.id, result: .applied)
        #expect(await secondDelivery.value == .applied)
        #expect(await deliver(coordinator) == .busy)
        await coordinator.requestHandled(owner: Self.owner, requestID: firstRequest.id, result: .stale)
        #expect(await firstDelivery.value == .stale)
    }

    @Test
    func test_deliver_parallelOrphanTaps_coalesceThePhysicalRemoval() async {
        let gate = Gate()
        fake.presence.setValue(["orphan": .alive])
        fake.endGate.setValue(gate)
        let lookups = AsyncStream<Void>.makeStream()
        var transport = fake.transport
        let allIDs = transport.allIDs
        transport.allIDs = {
            lookups.continuation.yield()
            return allIDs()
        }
        let coordinator = LiveActivityCoordinator(transport: transport)
        let first = Task { await deliver(coordinator, activityID: "orphan") }
        await lookups.stream.next()
        await gate.entered.next()
        let second = Task { await deliver(coordinator, activityID: "orphan") }
        await lookups.stream.next()
        gate.open()
        #expect(await first.value == .orphanEnded)
        #expect(await second.value == .orphanEnded)
        #expect(fake.calls.value == [.end("orphan", nil, .immediate)])
    }

    @Test
    func test_requests_replacementClosesOldStream_andKeepsNewSubscription() async throws {
        let coordinator = LiveActivityCoordinator(transport: fake.transport)
        let first = await coordinator.requests(owner: Self.owner)
        var oldIterator = first.makeAsyncIterator()
        await show(coordinator)
        let delivery = Task { await deliver(coordinator) }
        _ = try #require(await oldIterator.next())

        let second = await coordinator.requests(owner: Self.owner)
        var newIterator = second.makeAsyncIterator()
        #expect(await delivery.value == .unavailable)
        #expect(await oldIterator.next() == nil)
        let next = Task { await deliver(coordinator) }
        let request = try #require(await newIterator.next())
        await coordinator.requestHandled(owner: Self.owner, requestID: request.id, result: .applied)
        #expect(await next.value == .applied)
    }

    @Test
    func test_requests_cancelledConsumer_releasesItsPendingRequestWithoutEndingTheCard() async {
        let coordinator = LiveActivityCoordinator(transport: fake.transport)
        let stream = await coordinator.requests(owner: Self.owner)
        let arrivals = AsyncStream<Void>.makeStream()
        let consumer = Task {
            for await _ in stream { arrivals.continuation.yield() }
        }
        await show(coordinator)
        let delivery = Task { await deliver(coordinator) }
        await arrivals.stream.next()

        consumer.cancel()
        await consumer.value
        #expect(await delivery.value == .unavailable)
        #expect(await deliver(coordinator) == .unavailable)
        #expect(fake.calls.value == [.request(.held(1))])
    }

    @Test
    func test_end_releasesPendingCommand_andClosesCurrentAndFutureStreams() async throws {
        let coordinator = LiveActivityCoordinator(transport: fake.transport)
        let stream = await coordinator.requests(owner: Self.owner)
        var iterator = stream.makeAsyncIterator()
        await show(coordinator)
        let delivery = Task { await deliver(coordinator) }
        _ = try #require(await iterator.next())

        await coordinator.end(owner: Self.owner, clock: clock)
        #expect(await delivery.value == .unavailable)
        #expect(await iterator.next() == nil)
        let later = await coordinator.requests(owner: Self.owner)
        var laterIterator = later.makeAsyncIterator()
        #expect(await laterIterator.next() == nil)
        #expect(await deliver(coordinator) == .unavailable)
        #expect(fake.calls.value == [.request(.held(1)), .end("activity-1", nil, .immediate)])
    }

    @Test
    func test_deliver_endingOwner_isNotAnOrphanDuringOrAfterRemoval() async {
        let coordinator = LiveActivityCoordinator(transport: fake.transport)
        await show(coordinator)
        let gate = Gate()
        fake.endGate.setValue(gate)
        let ending = Task { await coordinator.end(owner: Self.owner, clock: clock) }
        await gate.entered.next()

        #expect(await deliver(coordinator) == .unavailable)
        gate.open()
        await ending.value
        #expect(await deliver(coordinator) == .unavailable)
        #expect(fake.calls.value == [.request(.held(1)), .end("activity-1", nil, .immediate)])
    }

    @Test(arguments: [false, true])
    func test_deliver_orphanRemovalOutlivesTheBoundAndCancellation(isCancelled: Bool) async {
        let gate = Gate()
        let completed = AsyncStream<Void>.makeStream()
        fake.endGate.setValue(gate)
        fake.presence.setValue(["orphan": .alive])
        var transport = fake.transport
        let end = transport.end
        transport.end = { id, content, dismissal in
            await end(id, content, dismissal)
            completed.continuation.yield()
        }
        let coordinator = LiveActivityCoordinator(transport: transport)
        let delivery = Task { await deliver(coordinator, activityID: "orphan") }
        await gate.entered.next()

        if isCancelled {
            delivery.cancel()
        } else {
            await clock.advance(by: LiveActivityCoordinator.endTimeout)
        }
        #expect(await delivery.value == (isCancelled ? .cancelled : .orphanEnded))
        #expect(fake.calls.value.isEmpty)
        gate.open()
        await completed.stream.next()
        #expect(fake.calls.value == [.end("orphan", nil, .immediate)])
    }
}
