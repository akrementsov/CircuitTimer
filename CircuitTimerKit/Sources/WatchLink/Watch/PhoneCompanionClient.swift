import Dependencies
import DependenciesMacros
import Foundation
import os

/// The watch hears the iPhone's states and asks it for the current one.
@DependencyClient
public struct PhoneCompanionClient: Sendable {
    /// Starts the session once per process, in the watch app's `init`.
    public var activate: @Sendable () -> Void
    public var status: @Sendable () -> LinkStatus = { .inactive }
    /// A new stream that replaces the previous one; it starts with the current status and the last context received.
    public var events: @Sendable () async -> AsyncStream<PhoneLinkEvent> = { AsyncStream { $0.finish() } }
    /// Throws `PhoneLinkError`.
    public var send: @Sendable (_ requestID: UUID, _ request: WatchRequest) async throws -> WatchReplyEnvelope
}

extension PhoneCompanionClient: DependencyKey {
    public static let liveValue: Self = {
        #if os(watchOS)
        let transport = LockIsolated<LinkTransport?>(nil)
        return Self(
            activate: {
                transport.withValue { transport in
                    guard transport == nil else { return }
                    let started = WCSessionBridge().transport
                    started.activate()
                    transport = started
                }
            },
            status: { transport.value?.status().linkStatus ?? .inactive },
            events: {
                guard let transport = transport.value else { return AsyncStream { $0.finish() } }
                return PhoneCompanionClient.phoneEvents(from: transport)
            },
            send: { requestID, request in
                guard let transport = transport.value else { throw PhoneLinkError.inactive }
                let envelope = WatchRequestEnvelope(requestID: requestID, request: request)
                return try await PhoneCompanionClient.send(envelope, through: transport)
            }
        )
        #else
        return Self(
            activate: { Logger.watchLink.error("The watch's link client was activated on the iPhone") },
            status: { .inactive },
            events: { AsyncStream { $0.finish() } },
            send: { _, _ in throw PhoneLinkError.failed }
        )
        #endif
    }()

    /// Hears no iPhone.
    public static let previewValue = Self(
        activate: {},
        status: { .inactive },
        events: { AsyncStream { $0.finish() } },
        send: { _, _ in throw PhoneLinkError.unreachable }
    )
    /// Declared explicitly so each endpoint a test forgets to override reports itself as unimplemented.
    public static let testValue = Self()

    static func phoneEvents(from transport: LinkTransport) -> AsyncStream<PhoneLinkEvent> {
        let source = transport.events()
        return AsyncStream { continuation in
            // Maps the session's events for as long as the reducer reads them; a newer subscription finishes `source`.
            // swiftlint:disable:next no_unstructured_task
            let task = Task {
                for await event in source {
                    switch event {
                        case .activated, .statusChanged, .watchChanged:
                            continuation.yield(.status(transport.status().linkStatus))
                        case let .context(data):
                            continuation.yield(decodeState(data).map(PhoneLinkEvent.context) ?? undecodable(data))
                        case let .message(data):
                            continuation.yield(decodeState(data).map(PhoneLinkEvent.message) ?? undecodable(data))
                        case let .request(_, ticket):
                            Logger.watchLink.error("The watch received a request from the iPhone")
                            ticket.reply(Data())
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func send(_ envelope: WatchRequestEnvelope, through transport: LinkTransport) async throws -> WatchReplyEnvelope {
        let request: Data
        do {
            request = try WireCoding.encode(envelope)
        } catch {
            Logger.watchLink.error("A request did not encode: \(String(reflecting: error), privacy: .public)")
            throw PhoneLinkError.failed
        }
        let data: Data
        do {
            data = try await transport.sendRequest(request)
        } catch {
            throw PhoneLinkError(error)
        }
        let version = WireCoding.schemaVersion(of: data)
        guard version == WatchLinkSchema.version else { throw PhoneLinkError.incompatible(peerSchemaVersion: version) }
        do {
            return try WireCoding.decode(WatchReplyEnvelope.self, from: data)
        } catch {
            Logger.watchLink.error("A reply of our version did not decode: \(String(reflecting: error), privacy: .public)")
            throw PhoneLinkError.incompatible(peerSchemaVersion: version)
        }
    }

    /// A state of our version, or `nil` when it cannot be read.
    private static func decodeState(_ data: Data) -> PhoneState? {
        guard WireCoding.schemaVersion(of: data) == WatchLinkSchema.version else { return nil }
        do {
            return try WireCoding.decode(PhoneState.self, from: data)
        } catch {
            Logger.watchLink.error("A state of our version did not decode: \(String(reflecting: error), privacy: .public)")
            return nil
        }
    }

    private static func undecodable(_ data: Data) -> PhoneLinkEvent {
        .undecodable(peerSchemaVersion: WireCoding.schemaVersion(of: data))
    }
}

extension DependencyValues {
    public var phoneCompanion: PhoneCompanionClient {
        get { self[PhoneCompanionClient.self] }
        set { self[PhoneCompanionClient.self] = newValue }
    }
}
