import Dependencies
import DependenciesMacros
import Foundation
import WorkoutDomain

/// A saved run and when its file was last written.
public struct StoredRunRecord: Equatable, Sendable {
    public var record: WorkoutRunRecord
    public var savedAt: Date

    public init(record: WorkoutRunRecord, savedAt: Date) {
        self.record = record
        self.savedAt = savedAt
    }
}

public enum RunRecordError: Error {
    /// The file exists but could not be read.
    case unreadable(any Error)
    /// The file was read but is not a valid record.
    case corrupt(any Error)
    /// Another app version wrote the file; it stays on disk.
    case unsupportedSchema(Int)
}

/// The saved run of each scene session: one file per session, named after its identifier.
///
/// A run is restored only from the file of the scene session connected now, so a session the
/// user closed in the App Switcher leaves nothing to restore.
@DependencyClient
public struct WorkoutRunRecordClient: Sendable {
    /// An increasing revision for the next `write`. Take it in the reducer: effects can start out
    /// of order, and the file applies a write only when its revision is newer than any applied.
    /// The default is what the unimplemented `testValue` returns after reporting the call; the
    /// file ignores it.
    public var nextRevision: @Sendable () -> Int = { 0 }
    /// The record of `sessionID`, or `nil` when that session has none. Never changes the disk.
    public var load: @Sendable (_ sessionID: String) async throws -> StoredRunRecord?
    /// Replaces the record of `sessionID`, or removes it for `nil`. A failed write leaves the file
    /// as it was; the caller warns and writes again later.
    /// The first applied writes also remove the files left by earlier sessions, until one pass
    /// succeeds. Ignored when `revision` is not newer than any write applied before.
    public var write: @Sendable (_ record: WorkoutRunRecord?, _ sessionID: String, _ revision: Int) async throws -> Void
}

extension WorkoutRunRecordClient {
    static func file(directory: URL) -> Self {
        let file = RunRecordFile(directory: directory)
        let reader = RunRecordReader(directory: directory)
        let revision = LockIsolated(0)
        return Self(
            nextRevision: {
                revision.withValue {
                    $0 += 1
                    return $0
                }
            },
            load: { try await reader.load(sessionID: $0) },
            write: { try await file.write($0, sessionID: $1, revision: $2) }
        )
    }
}

extension WorkoutRunRecordClient: DependencyKey {
    public static let liveValue = Self.file(
        directory: URL.applicationSupportDirectory.appending(path: "RunRecord", directoryHint: .isDirectory)
    )
    /// Keeps nothing: a preview never relaunches, so there is no run to restore.
    public static let previewValue = Self(
        nextRevision: { 1 },
        load: { _ in nil },
        write: { _, _, _ in }
    )
    /// Declared explicitly so each endpoint a test forgets to override reports itself as unimplemented.
    public static let testValue = Self()
}

extension DependencyValues {
    public var workoutRunRecord: WorkoutRunRecordClient {
        get { self[WorkoutRunRecordClient.self] }
        set { self[WorkoutRunRecordClient.self] = newValue }
    }
}
