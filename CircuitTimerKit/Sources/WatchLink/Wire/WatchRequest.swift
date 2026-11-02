import Foundation
import WorkoutActivity

/// What the watch asks the iPhone. CT-9-5 adds the start.
public enum WatchRequest: Codable, Equatable, Sendable {
    /// Send the current state; include the catalog only if its digest differs from this one.
    case refresh(knownCatalogDigest: String?)
    /// Pause or resume the owner's timer by the card's rules, fenced by the `controlGeneration` the watch showed; the
    /// reply carries the state as a refresh would.
    case control(owner: UUID, command: LiveActivityCommand, generation: Int, knownCatalogDigest: String?)
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
    case control(WatchControlResult, PhoneState)
}

/// What became of a command from the watch. `timedOut` means the iPhone does not know: the command may have applied.
public enum WatchControlResult: String, Codable, CaseIterable, Equatable, Sendable {
    case applied
    case stale
    case busy
    case unavailable
    case timedOut

    public init(_ result: LiveActivityControlResult) {
        switch result {
            case .applied:
                self = .applied
            case .stale:
                self = .stale
            case .busy:
                self = .busy
            case .timedOut:
                self = .timedOut
            case .unavailable, .failed, .cancelled, .orphanEnded:
                self = .unavailable
        }
    }
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
