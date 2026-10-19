import Foundation

public enum LiveActivityCommand: Equatable, Sendable {
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
