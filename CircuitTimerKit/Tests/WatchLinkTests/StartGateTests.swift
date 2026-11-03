@testable import WatchLink

import Foundation
import Testing
import TestSupport

@Suite
struct StartGateTests {
    private static func request(_ id: Int) -> WatchStartRequest {
        WatchStartRequest(id: id, workoutID: UUID(link: 1), scheduleFingerprint: "schedule")
    }

    private static func admitted(_ gate: StartGate, _ id: Int) throws -> OneAnswer<WatchStartResult?> {
        guard case let .admitted(answer) = gate.admit(request(id)) else { throw NotAdmitted() }
        return answer
    }

    private struct NotAdmitted: Error {}

    @Test
    func test_admit_withoutSubscriber_isNotHandedOver() {
        guard case .noSubscriber = StartGate().admit(Self.request(1)) else {
            Issue.record("Start was admitted without an app subscriber")
            return
        }
    }

    @Test
    func test_admit_pendingRequest_isBusyUntilAnswered() async throws {
        let gate = StartGate()
        let pair = AsyncStream<WatchStartRequest>.makeStream(bufferingPolicy: .bufferingOldest(1))
        _ = gate.subscribe(pair.continuation)
        defer { gate.close() }
        let first = try Self.admitted(gate, 1)
        guard case .busy = gate.admit(Self.request(2)) else {
            Issue.record("A second request replaced the waiting Start")
            return
        }
        var iterator = pair.stream.makeAsyncIterator()
        #expect(await iterator.next() == Self.request(1))
        #expect(gate.answer(requestID: 1, .accepted(asksOnPhone: true)))
        #expect(!gate.answer(requestID: 1, .busy))
        #expect(await first.wait(timeout: .zero, clock: ManualClock(), otherwise: nil) == .accepted(asksOnPhone: true))
        _ = try Self.admitted(gate, 3)
    }

    @Test
    func test_subscribe_replacedStreamsLateTermination_keepsTheNewRequest() async throws {
        let gate = StartGate()
        let old = AsyncStream<WatchStartRequest>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let oldID = gate.subscribe(old.continuation)
        let oldAnswer = try Self.admitted(gate, 1)
        let current = AsyncStream<WatchStartRequest>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let currentID = gate.subscribe(current.continuation)
        defer { gate.close() }
        #expect(currentID != oldID)
        #expect(await oldAnswer.wait(timeout: .zero, clock: ManualClock(), otherwise: .busy) == nil)
        #expect(!gate.answer(requestID: 1, .accepted(asksOnPhone: false)))
        let answer = try Self.admitted(gate, 2)

        gate.endSubscription(oldID)

        var iterator = current.stream.makeAsyncIterator()
        #expect(await iterator.next() == Self.request(2))
        #expect(gate.answer(requestID: 2, .changed))
        #expect(await answer.wait(timeout: .zero, clock: ManualClock(), otherwise: nil) == .changed)
    }

    @Test
    func test_close_pendingRequestAndFutureSubscriptions_stayClosed() async throws {
        let gate = StartGate()
        let pair = AsyncStream<WatchStartRequest>.makeStream(bufferingPolicy: .bufferingOldest(1))
        _ = gate.subscribe(pair.continuation)
        let answer = try Self.admitted(gate, 1)

        gate.close()

        #expect(await answer.wait(timeout: .zero, clock: ManualClock(), otherwise: .busy) == nil)
        #expect(!gate.answer(requestID: 1, .accepted(asksOnPhone: false)))
        guard case .closed = gate.admit(Self.request(2)) else {
            Issue.record("Start passed a closed gate")
            return
        }
        let late = AsyncStream<WatchStartRequest>.makeStream()
        _ = gate.subscribe(late.continuation)
        var iterator = late.stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test
    func test_admit_fullBuffer_refusesTheUndeliveredRequest() throws {
        let gate = StartGate()
        let pair = AsyncStream<WatchStartRequest>.makeStream(bufferingPolicy: .bufferingOldest(1))
        _ = gate.subscribe(pair.continuation)
        defer { gate.close() }
        _ = try Self.admitted(gate, 1)
        gate.withdraw(requestID: 1)

        guard case .dropped = gate.admit(Self.request(2)) else {
            Issue.record("Start was admitted although its request did not fit the app stream")
            return
        }
        #expect(!gate.answer(requestID: 2, .accepted(asksOnPhone: false)))
    }
}
