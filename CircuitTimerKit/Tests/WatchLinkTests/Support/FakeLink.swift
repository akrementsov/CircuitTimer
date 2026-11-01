@testable import WatchLink

import Dependencies
import Foundation
import WatchConnectivity

/// A `LinkTransport` that records what the link writes and sends, and lets a test decide what WatchConnectivity
/// answers.
final class FakeLink: Sendable {
    let contexts = LockIsolated<[Data]>([])
    let messages = LockIsolated<[Data]>([])
    let snapshot = LockIsolated(
        SessionSnapshot(isActivated: true, isReachable: true, needsUnlock: false, canPublish: true)
    )
    /// Thrown by `updateContext` one per call, before any write succeeds.
    let refusals = LockIsolated<[NSError]>([])
    /// Answers `sendRequest`; by default the request is unanswered.
    let respond = LockIsolated<(@Sendable (Data) async throws -> Data)?>(nil)
    let events = LockIsolated<AsyncStream<SessionEvent>.Continuation?>(nil)
    let eventsTerminated = LockIsolated(false)

    var transport: LinkTransport {
        LinkTransport(
            activate: {},
            events: {
                let (stream, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
                continuation.onTermination = { _ in self.eventsTerminated.setValue(true) }
                self.events.setValue(continuation)
                return stream
            },
            status: { self.snapshot.value },
            updateContext: { data in
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

    static let tooLarge = NSError(domain: WCErrorDomain, code: WCError.Code.payloadTooLarge.rawValue)
    static let unreachable = NSError(domain: WCErrorDomain, code: WCError.Code.notReachable.rawValue)
}

/// A whole second, so the millisecond dates of the wire compare exactly.
let linkNow = Date(timeIntervalSince1970: 1_778_000_000)
