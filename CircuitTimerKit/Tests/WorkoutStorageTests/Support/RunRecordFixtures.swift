@testable import WorkoutStorage

import Foundation
import WorkoutDomain

func makeRunRecord(_ number: Int = 1) -> WorkoutRunRecord {
    WorkoutRunRecord(
        workoutID: UUID(fixture: number),
        scheduleFingerprint: "fingerprint-\(number)",
        phase: .running,
        positionMs: Int64(number) * 1_000,
        cursor: 0,
        sinceEpochMs: 1_700_000_000_000
    )
}

/// Each test owns a folder, and cleanup failures fail the test instead of being discarded.
func withRunRecordFolder(_ operation: (URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "RunRecordTests-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let result: Result<Void, any Error>
    do {
        try await operation(root)
        result = .success(())
    } catch {
        result = .failure(error)
    }
    try FileManager.default.removeItem(at: root)
    try result.get()
}
