import Foundation
import WorkoutActivity

/// What the watch asks the running timer through its owner's stream.
public struct WatchControlRequest: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Settle the run now and publish it; the reply to the watch is live only after that publication.
        case refresh
        /// Pause or resume by the card's rules; the timer answers through `controlHandled`.
        case command(LiveActivityCommand, generation: Int)
    }

    public let id: Int
    public let kind: Kind

    public init(id: Int, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

/// The timer's run with the revision its reducer took for it.
public struct WatchRunPublication: Equatable, Sendable {
    public let revision: Int
    public let run: WatchRun

    public init(revision: Int, run: WatchRun) {
        self.revision = revision
        self.run = run
    }
}
