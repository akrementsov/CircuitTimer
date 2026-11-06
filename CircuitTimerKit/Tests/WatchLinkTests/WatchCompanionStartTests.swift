@testable import WatchLink

import Dependencies
import Foundation
import Testing
import TestSupport
import WorkoutDomain

struct StartHarness: Sendable {
    let link: FakeLink
    let clock: ManualClock
    let companion: WatchCompanion

    init(now: @escaping @Sendable () -> Date = { linkNow }, access: WatchAccess? = .granted) async {
        let link = FakeLink()
        let clock = ManualClock()
        let companion = await WatchCompanion.make(link: link, access: access, now: now, clock: clock)
        self.link = link
        self.clock = clock
        self.companion = companion
        let events = link.transport.events()
        Task { await companion.run(events) }
    }

    func close() {
        companion.closeGate()
        link.events.value?.finish()
    }

    struct Reply: Sendable {
        let id: UUID?
        let result: WatchStartResult
        let state: PhoneState
        let answers: LockIsolated<[Data]>
    }

    private struct NotAStartReply: Error {}

    func ask(_ number: Int = 7) async throws -> Reply {
        let answers = try await askRaw(number)
        let first = try #require(answers.value.first)
        let envelope = try WireCoding.decode(WatchReplyEnvelope.self, from: first)
        guard case let .start(result, state) = envelope.reply else { throw NotAStartReply() }
        return Reply(id: envelope.requestID, result: result, state: state, answers: answers)
    }

    func askRaw(_ number: Int = 7) async throws -> LockIsolated<[Data]> {
        let request = WatchRequest.start(workoutID: UUID(link: 1), scheduleFingerprint: "schedule", knownCatalogDigest: nil)
        let data = try WireCoding.encode(WatchRequestEnvelope(requestID: UUID(link: number), request: request))
        let answers = LockIsolated<[Data]>([])
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            link.events.value?.yield(.request(data, ReplyTicket { data in
                let first = answers.withValue { answers in
                    answers.append(data)
                    return answers.count == 1
                }
                if first { continuation.resume() }
            }))
        }
        return answers
    }
}

@Suite(.timeLimit(.minutes(1)))
struct WatchStartAdmissionTests {
    @Test(arguments: [
        WatchStartResult.accepted(asksOnPhone: false),
        .accepted(asksOnPhone: true),
        .openPhoneApp,
        .busy,
        .listUnavailable,
        .changed,
        .gone,
        .notPlayable,
    ])
    func test_start_subscriberAnswers_echoesResultAndChosenWorkout(result: WatchStartResult) async throws {
        let harness = await StartHarness()
        defer { harness.close() }
        let stream = await harness.companion.startRequests()
        let taken = Observed<WatchStartRequest?>(nil)
        let reader = Task {
            for await request in stream {
                taken.setValue(request)
                return await harness.companion.startHandled(requestID: request.id, result: result)
            }
            return false
        }
        defer { reader.cancel() }

        let reply = try await harness.ask()

        #expect(reply.id == UUID(link: 7))
        #expect(reply.result == result)
        #expect(reply.answers.value.count == 1)
        #expect(!reply.state.isRunLive)
        #expect(taken.value?.workoutID == UUID(link: 1))
        #expect(taken.value?.scheduleFingerprint == "schedule")
        reader.cancel()
        #expect(await reader.value)
        if let request = taken.value {
            #expect(await !harness.companion.startHandled(requestID: request.id, result: result))
        }
    }

    @Test
    func test_start_withoutSubscriber_returnsOpenPhoneAppWithTheCurrentCatalog() async throws {
        let harness = await StartHarness()
        defer { harness.close() }
        await harness.companion.publishCatalog(revision: 1, catalog: .loaded(makeCatalog(1)))

        let reply = try await harness.ask()

        #expect(reply.result == .openPhoneApp)
        #expect(reply.state.catalog == .loaded(makeCatalog(1)))
        #expect(reply.id == UUID(link: 7))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct WatchCompanionStartTests {
    enum End: CaseIterable, Sendable {
        case timeout
        case replacement
        case termination
    }

    @Test(arguments: End.allCases)
    func test_start_endedAdmission_repliesOpenPhoneAppAndRefusesLateAcceptance(end: End) async throws {
        let harness = await StartHarness()
        defer { harness.close() }
        let stream = await harness.companion.startRequests()
        var iterator = stream.makeAsyncIterator()
        let pending = Task { try await harness.ask() }
        let request = try #require(await iterator.next())

        switch end {
            case .timeout:
                await harness.clock.waitForStartedSleeps(1)
                harness.clock.advance(by: WatchCompanion.timerWait)
            case .replacement:
                _ = await harness.companion.startRequests()
            case .termination:
                harness.companion.closeGate()
        }
        let reply = try await pending.value

        #expect(reply.result == .openPhoneApp)
        #expect(reply.answers.value.count == 1)
        #expect(await !harness.companion.startHandled(requestID: request.id, result: .accepted(asksOnPhone: false)))
    }

    @Test
    func test_start_secondPendingRequest_returnsBusyWithoutReplacingTheFirst() async throws {
        let harness = await StartHarness()
        defer { harness.close() }
        let stream = await harness.companion.startRequests()
        var iterator = stream.makeAsyncIterator()
        let pending = Task { try await harness.ask() }
        let request = try #require(await iterator.next())

        let second = try await harness.ask(8)

        #expect(second.result == .busy)
        #expect(second.id == UUID(link: 8))
        #expect(await harness.companion.startHandled(requestID: request.id, result: .accepted(asksOnPhone: false)))
        #expect(try await pending.value.result == .accepted(asksOnPhone: false))
    }

    @Test
    func test_start_arrivalAlreadyExpired_handsNothingToTheSubscriber() async {
        let harness = await StartHarness()
        defer { harness.close() }
        let stream = await harness.companion.startRequests()
        var iterator = stream.makeAsyncIterator()
        let arrival = MonotonicInstant(now: harness.clock)
        harness.clock.advance(by: WatchCompanion.timerWait)

        let (result, _) = await harness.companion.startState(
            workoutID: UUID(link: 1), scheduleFingerprint: "schedule", knownCatalogDigest: nil, arrival: arrival
        )

        #expect(result == .openPhoneApp)
        harness.companion.closeGate()
        #expect(await iterator.next() == nil)
    }
}
