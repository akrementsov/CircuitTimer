@testable import WatchLink

import Dependencies
import Foundation
import TestSupport
import WatchConnectivity

/// A `LinkTransport` that records what the link writes and sends, and lets a test decide what WatchConnectivity
/// answers.
final class FakeLink: Sendable {
    /// The contexts written, in order; a test waits on them because the ledger writes on its own queue.
    let contexts = Observed<[Data]>([])
    let messages = Observed<[Data]>([])
    /// Every `updateContext` call, refused ones too, as the decoded state it offered.
    let offered = Observed<[PhoneState]>([])
    let snapshot = LockIsolated(
        SessionSnapshot(isActivated: true, isReachable: true, needsUnlock: false, canPublish: true)
    )
    /// Thrown by `updateContext` one per call, before any write succeeds.
    let refusals = LockIsolated<[NSError]>([])
    /// Answers `sendRequest`; by default the request is unanswered.
    let respond = LockIsolated<(@Sendable (Data) async throws -> Data)?>(nil)
    let events = LockIsolated<AsyncStream<SessionEvent>.Continuation?>(nil)
    /// Set when the stream of the link's events ends, so a test waits for it without yielding.
    let eventsEnded = Observed(false)
    /// Holds the next `updateContext` call inside the ledger's queue until the test opens it.
    let gate = LockIsolated<WriteGate?>(nil)

    var transport: LinkTransport {
        LinkTransport(
            activate: {},
            events: {
                let (stream, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
                continuation.onTermination = { _ in self.eventsEnded.setValue(true) }
                self.events.setValue(continuation)
                return stream
            },
            status: { self.snapshot.value },
            updateContext: { data in
                if let state = try? WireCoding.decode(PhoneState.self, from: data) {
                    self.offered.withValue { $0.append(state) }
                }
                if let gate = self.gate.withValue({ gate in defer { gate = nil }; return gate }) {
                    gate.hold()
                }
                if let refusal = self.refusals.withValue({ $0.isEmpty ? nil : $0.removeFirst() }) {
                    throw refusal
                }
                self.contexts.withValue { $0.append(data) }
            },
            sendMessage: { data in self.messages.withValue { $0.append(data) } },
            sendRequest: { data in
                guard let respond = self.respond.value else { throw Self.unreachable }
                return try await respond(data)
            }
        )
    }

    func writtenStates() throws -> [PhoneState] {
        try contexts.value.map { try WireCoding.decode(PhoneState.self, from: $0) }
    }

    func sentStates() throws -> [PhoneState] {
        try messages.value.map { try WireCoding.decode(PhoneState.self, from: $0) }
    }

    func offeredStates() -> [PhoneState] {
        offered.value
    }

    static let tooLarge = NSError(domain: WCErrorDomain, code: WCError.Code.payloadTooLarge.rawValue)
    static let unreachable = NSError(domain: WCErrorDomain, code: WCError.Code.notReachable.rawValue)
}

/// A whole second, so the millisecond dates of the wire compare exactly.
let linkNow = Date(timeIntervalSince1970: 1_778_000_000)

/// Stops one write inside the ledger's serial queue, which is synchronous, so the test can act while the queue is
/// busy: the write reports that it started through `started`, then blocks on a semaphore until `open()`.
final class WriteGate: Sendable {
    let started = Observed(false)
    private let semaphore = DispatchSemaphore(value: 0)

    func hold() {
        started.setValue(true)
        semaphore.wait()
    }

    func open() {
        semaphore.signal()
    }
}
