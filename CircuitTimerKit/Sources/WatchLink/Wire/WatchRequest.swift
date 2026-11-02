import Foundation

/// What the watch asks the iPhone. CT-9-4 adds the controls, CT-9-5 the start.
public enum WatchRequest: Codable, Equatable, Sendable {
    /// Send the current state; include the catalog only if its digest differs from this one.
    case refresh(knownCatalogDigest: String?)
}

public struct WatchRequestEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let request: WatchRequest

    public init(requestID: UUID, request: WatchRequest) {
        schemaVersion = WatchLinkSchema.version
        self.requestID = requestID
        self.request = request
    }
}

public enum WatchReply: Codable, Equatable, Sendable {
    case state(PhoneState)
}

/// The iPhone's answer. `requestID == nil` and `reply == nil` together mean the iPhone could not read the request: the
/// two apps speak different versions.
public struct WatchReplyEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID?
    public let reply: WatchReply?

    public init(requestID: UUID?, reply: WatchReply?) {
        schemaVersion = WatchLinkSchema.version
        self.requestID = requestID
        self.reply = reply
    }

    /// The answer to a request the iPhone could not read.
    public static let unreadable = WatchReplyEnvelope(requestID: nil, reply: nil)
}
