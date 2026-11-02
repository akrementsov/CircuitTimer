import Foundation

/// Whether the timer should warn that its activity cannot be shown. A newer state of the
/// coordinator always has a larger serial, whatever order the results reach the reducer in.
public struct LiveActivityNotice: Equatable, Sendable {
    public let serial: Int
    public let isFailing: Bool

    public init(serial: Int, isFailing: Bool) {
        self.serial = serial
        self.isFailing = isFailing
    }
}

public enum LiveActivityCommand: String, Codable, Equatable, Sendable {
    case pause
    case resume
}

/// An admitted command, bound to the card the user actually tapped.
public struct LiveActivityControlRequest: Equatable, Sendable {
    public let id: Int
    public let command: LiveActivityCommand
    public let generation: Int

    public init(id: Int, command: LiveActivityCommand, generation: Int) {
        self.id = id
        self.command = command
        self.generation = generation
    }
}

public enum LiveActivityControlResult: Equatable, Sendable {
    case applied
    case stale
    case unavailable
    case busy
    case failed
    case timedOut
    case cancelled
    case orphanEnded
}

/// The actual drain outcome, independent of whether a warning changed.
public struct LiveActivitySyncResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case applied
        case unavailable
        case deferred
        case failed
        case superseded
    }

    public let outcome: Outcome
    public let notice: LiveActivityNotice?

    public init(outcome: Outcome, notice: LiveActivityNotice? = nil) {
        self.outcome = outcome
        self.notice = notice
    }
}
