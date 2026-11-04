@testable import WatchLink

import Foundation
import Testing
import TestSupport
import WorkoutDomain

@Suite(.timeLimit(.minutes(1)))
struct WatchStartBoundaryTests {
    @Test
    func test_start_sequentialRequests_haveDistinctIDsAndRejectForeignAnswers() async throws {
        let harness = StartHarness()
        defer { harness.close() }
        let stream = await harness.companion.startRequests()
        var iterator = stream.makeAsyncIterator()
        let first = Task { try await harness.ask(70) }
        let old = try #require(await iterator.next())
        #expect(await harness.companion.startHandled(requestID: old.id, result: .busy))
        #expect(try await first.value.id == UUID(link: 70))
        let second = Task { try await harness.ask(71) }
        let current = try #require(await iterator.next())
        #expect(current.id != old.id)
        #expect(await !harness.companion.startHandled(requestID: old.id, result: .accepted(asksOnPhone: false)))
        #expect(await !harness.companion.startHandled(requestID: current.id + 1, result: .gone))
        #expect(await harness.companion.startHandled(requestID: current.id, result: .changed))
        let reply = try await second.value
        #expect(reply.id == UUID(link: 71))
        #expect(reply.result == .changed)
        #expect(reply.answers.value.count == 1)
    }

    @Test
    func test_start_timeout_freesNextAdmissionAndLateAnswerCannotFinishIt() async throws {
        let harness = StartHarness()
        defer { harness.close() }
        let stream = await harness.companion.startRequests()
        var iterator = stream.makeAsyncIterator()
        let first = Task { try await harness.ask(70) }
        let old = try #require(await iterator.next())
        await harness.clock.waitForStartedSleeps(1)
        harness.clock.advance(by: .seconds(5))
        let expired = try await first.value
        #expect(expired.result == .openPhoneApp)
        let second = Task { try await harness.ask(71) }
        let current = try #require(await iterator.next())
        #expect(await !harness.companion.startHandled(requestID: old.id, result: .accepted(asksOnPhone: false)))
        #expect(await harness.companion.startHandled(requestID: current.id, result: .accepted(asksOnPhone: true)))
        #expect(try await second.value.result == .accepted(asksOnPhone: true))
        #expect(expired.answers.value.count == 1)
    }

    @Test
    func test_start_replyCannotEncode_answersOnceWithEmptyData() async throws {
        let harness = StartHarness(now: { Date(timeIntervalSince1970: .nan) })
        defer { harness.close() }
        let stream = await harness.companion.startRequests()
        let reader = Task {
            for await request in stream {
                return await harness.companion.startHandled(requestID: request.id, result: .accepted(asksOnPhone: false))
            }
            return false
        }
        defer { reader.cancel() }
        let answers = try await harness.askRaw()
        #expect(await reader.value)
        #expect(answers.value == [Data()])
        #expect(throws: (any Error).self) {
            try WireCoding.decode(WatchReplyEnvelope.self, from: #require(answers.value.first))
        }
    }

    @Test
    func test_start_cancelledConsumer_terminatesPendingAndNextRequestHasNoSubscriber() async throws {
        let harness = StartHarness()
        defer { harness.close() }
        let stream = await harness.companion.startRequests()
        let taken = Observed<WatchStartRequest?>(nil)
        let reader = Task { for await request in stream { taken.setValue(request) } }
        let first = Task { try await harness.ask(70) }
        await taken.wait { $0 != nil }
        let request = try #require(taken.value)
        reader.cancel()
        await reader.value
        #expect(try await first.value.result == .openPhoneApp)
        #expect(await !harness.companion.startHandled(requestID: request.id, result: .accepted(asksOnPhone: false)))
        #expect(try await harness.ask(71).result == .openPhoneApp)
    }

    @Test
    func test_start_fullSubscriberBuffer_returnsOpenPhoneAppWithoutRegisteringDroppedTicket() async throws {
        let harness = StartHarness()
        defer { harness.close() }
        let stream = await harness.companion.startRequests()
        let first = Task { try await harness.ask(70) }
        // Keep the first request in the stream's one-element buffer until its ticket times out.
        await harness.clock.waitForStartedSleeps(1)
        harness.clock.advance(by: .seconds(5))
        #expect(try await first.value.result == .openPhoneApp)
        let dropped = try await harness.ask(71)
        #expect(dropped.result == .openPhoneApp)
        #expect(dropped.answers.value.count == 1)
        var iterator = stream.makeAsyncIterator()
        let old = try #require(await iterator.next())
        #expect(await !harness.companion.startHandled(requestID: old.id + 1, result: .accepted(asksOnPhone: false)))
        #expect(await !harness.companion.startHandled(requestID: old.id, result: .accepted(asksOnPhone: false)))
    }

    @Test
    func test_startHandled_elapsedBeforeSleepWakes_refusesAndWithdrawsOldTicket() async throws {
        let link = FakeLink()
        let clock = DelayedWakeClock()
        let companion = WatchCompanion(
            ledger: PublicationLedger(processID: UUID(link: 1), transport: link.transport),
            transport: link.transport,
            now: { linkNow },
            clock: clock
        )
        defer { companion.closeGate() }
        let stream = await companion.startRequests()
        var iterator = stream.makeAsyncIterator()
        let arrival = MonotonicInstant(now: clock)
        let first = Task {
            await companion.startState(
                workoutID: UUID(link: 1), scheduleFingerprint: "schedule", knownCatalogDigest: nil, arrival: arrival
            )
        }
        let request = try #require(await iterator.next())
        await clock.sleepClock.waitForSleeps()
        // The monotonic deadline passes while delivery of the sleep wake-up remains queued.
        clock.readingClock.advance(by: .seconds(5))
        let admitted = await companion.startHandled(requestID: request.id, result: .accepted(asksOnPhone: false))
        try #require(!admitted)
        let nextArrival = MonotonicInstant(now: clock)
        let next = Task {
            await companion.startState(
                workoutID: UUID(link: 2), scheduleFingerprint: "next", knownCatalogDigest: nil, arrival: nextArrival
            )
        }
        let current = try #require(await iterator.next())
        #expect(current.workoutID == UUID(link: 2))
        #expect(await companion.startHandled(requestID: current.id, result: .changed))
        #expect(await next.value.0 == .changed)
        clock.sleepClock.advance(by: .seconds(5))
        #expect(await first.value.0 == .openPhoneApp)
        #expect(await !companion.startHandled(requestID: current.id, result: .busy))
    }

}

/// Advances the reading separately from wake-up delivery, as an executor delayed past a real deadline can do.
private struct DelayedWakeClock: Clock {
    let readingClock = ManualClock()
    let sleepClock = ManualClock()

    var now: ManualClock.Instant { readingClock.now }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: ManualClock.Instant, tolerance: Duration?) async throws {
        try await sleepClock.sleep(until: deadline, tolerance: tolerance)
    }
}
