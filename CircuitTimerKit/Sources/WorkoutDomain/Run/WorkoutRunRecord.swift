import Foundation

/// A started, unfinished `WorkoutRun` saved so that it survives the process.
///
/// The key set is fixed by AGENTS «Persistence»; `WorkoutRun.init(schedule:restoring:at:)`
/// validates a record against the rebuilt schedule. Idle and finished runs have no record.
public struct WorkoutRunRecord: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public enum Phase: CaseIterable, Codable, Hashable, Sendable {
        case running
        case paused
        case awaitingUser

        public init(from decoder: any Decoder) throws {
            let token = try decoder.singleValueContainer().decode(String.self)
            guard let phase = Self.allCases.first(where: { $0.storageToken == token }) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown run phase «\(token)»")
                )
            }

            self = phase
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(storageToken)
        }

        // Stored tokens are part of the format: renaming a case must not change what is written.
        private var storageToken: String {
            switch self {
                case .running: "running"
                case .paused: "paused"
                case .awaitingUser: "awaitingUser"
            }
        }
    }

    public enum SchemaError: Error, Equatable, Sendable {
        /// Written by another app version; kept on disk rather than treated as corrupt.
        case unsupportedSchema(Int)
    }

    public let schemaVersion: Int
    public let workoutID: Workout.ID
    public let scheduleFingerprint: String
    public let phase: Phase
    public let positionMs: Int64
    public let cursor: Int
    /// The running anchor; `nil` in every other phase.
    public let sinceEpochMs: Int64?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case workoutID
        case scheduleFingerprint
        case phase
        case positionMs
        case cursor
        case sinceEpochMs
    }

    /// Takes any field values, valid or not; restoring validates them.
    public init(
        schemaVersion: Int = currentSchemaVersion,
        workoutID: Workout.ID,
        scheduleFingerprint: String,
        phase: Phase,
        positionMs: Int64,
        cursor: Int,
        sinceEpochMs: Int64?
    ) {
        self.schemaVersion = schemaVersion
        self.workoutID = workoutID
        self.scheduleFingerprint = scheduleFingerprint
        self.phase = phase
        self.positionMs = positionMs
        self.cursor = cursor
        self.sinceEpochMs = sinceEpochMs
    }

    /// The record of `run`, or `nil` when it is idle or finished.
    public init?(workoutID: Workout.ID, run: WorkoutRun) {
        let phase: Phase
        let since: Date?
        switch run.phase {
            case let .running(anchor):
                phase = .running
                since = anchor
            case .paused:
                phase = .paused
                since = nil
            case .awaitingUser:
                phase = .awaitingUser
                since = nil
            case .idle, .finished:
                return nil
        }
        self.init(
            workoutID: workoutID,
            scheduleFingerprint: run.schedule.fingerprint,
            phase: phase,
            positionMs: run.position.inMilliseconds,
            cursor: run.cursor,
            sinceEpochMs: since?.millisecondsSince1970
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SchemaError.unsupportedSchema(schemaVersion)
        }

        self.schemaVersion = schemaVersion
        workoutID = try container.decode(Workout.ID.self, forKey: .workoutID)
        scheduleFingerprint = try container.decode(String.self, forKey: .scheduleFingerprint)
        phase = try container.decode(Phase.self, forKey: .phase)
        positionMs = try container.decode(Int64.self, forKey: .positionMs)
        cursor = try container.decode(Int.self, forKey: .cursor)
        sinceEpochMs = try container.decodeIfPresent(Int64.self, forKey: .sinceEpochMs)
    }

    /// The running anchor as a date, for logs and checks outside the domain.
    public var since: Date? {
        sinceEpochMs.map { Date(millisecondsSince1970: $0) }
    }
}
