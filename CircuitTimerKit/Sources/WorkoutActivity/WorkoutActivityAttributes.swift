import ActivityKit
import Foundation

/// The Live Activity of one workout run: the workout's name, fixed for the activity's life, and a
/// compact state of the run that the Lock Screen and the Dynamic Island draw without the app.
public struct WorkoutActivityAttributes: ActivityAttributes, Hashable, Sendable {
    /// iOS rejects an activity whose attributes and state together encode to more than this.
    public static let encodedSizeLimit = 4_096

    /// The workout's name as stored; the display decides how a blank one reads.
    public let workoutName: String

    public init(workoutName: String) {
        self.workoutName = workoutName
    }

    /// How many bytes the attributes and `state` take together, as JSON.
    public func encodedSize(with state: ContentState) throws -> Int {
        let encoder = JSONEncoder()
        return try encoder.encode(self).count + encoder.encode(state).count
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public let phase: Phase
        /// Invalidates controls rendered before a change of the run's control state.
        public let controlGeneration: Int

        public init(phase: Phase, controlGeneration: Int = 0) {
            self.phase = phase
            self.controlGeneration = controlGeneration
        }

        /// When the running stage ends: from then on the system marks the content stale, and the
        /// display moves on to the stage the content already carries. Not encoded.
        public var staleDate: Date? {
            guard case let .running(running) = phase else { return nil }

            return running.stageEnd
        }
    }

    public enum Phase: Codable, Hashable, Sendable {
        /// Before the start, including the start countdown; `first` is the stage that opens the workout.
        case getReady(first: HeldStage)
        case running(Running)
        /// Stopped by the user, including the countdown that resumes it.
        case paused(HeldStage)
        /// A manual pause of the schedule; `next` is `nil` when the workout ends after it.
        case awaitingUser(next: HeldStage?)
        case finished
    }

    public struct Running: Codable, Hashable, Sendable {
        public let stage: Stage
        public let stageStart: Date
        public let stageEnd: Date
        public let next: Next

        public init(stage: Stage, stageStart: Date, stageEnd: Date, next: Next) {
            self.stage = stage
            self.stageStart = stageStart
            self.stageEnd = stageEnd
            self.next = next
        }
    }

    public enum Next: Codable, Hashable, Sendable {
        case stage(Stage, end: Date)
        case manualPause
        case finish
    }

    /// A stage that is not counting: what remains of it, in whole milliseconds.
    public struct HeldStage: Codable, Hashable, Sendable {
        public let stage: Stage
        public let remainingMilliseconds: Int64

        public init(stage: Stage, remainingMilliseconds: Int64) {
            self.stage = stage
            self.remainingMilliseconds = remainingMilliseconds
        }
    }

    public struct Stage: Codable, Hashable, Sendable {
        public enum Kind: Codable, Hashable, Sendable {
            case work
            case rest
            case pause
        }

        public let kind: Kind
        /// The stage's name as stored; `nil` for a manual pause.
        public let name: String?

        public init(kind: Kind, name: String?) {
            self.kind = kind
            self.name = name
        }
    }
}
