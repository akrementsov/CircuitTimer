import Foundation
import os
import WorkoutDomain

/// Reads one session's record without touching anything else on disk.
///
/// The blocking read runs on its own queue, apart from the writer, so a stalled read can hold
/// neither a write nor a thread of the cooperative pool.
final class RunRecordReader: Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "CircuitTimer.RunRecordReader")

    init(directory: URL) {
        self.directory = directory
    }

    func load(sessionID: String) async throws -> StoredRunRecord? {
        let url = RunRecordLayout.fileURL(in: directory, sessionID: sessionID)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try Self.read(url) })
            }
        }
    }

    private static func read(_ url: URL) throws -> StoredRunRecord? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch where RunRecordLayout.isMissingFile(error) {
            return nil
        } catch {
            throw RunRecordError.unreadable(error)
        }
        defer {
            do {
                try handle.close()
            } catch {
                Logger.runRecord.error("Closing the run record failed: \(String(reflecting: error), privacy: .public)")
            }
        }

        // The bytes and the date come from one descriptor, so an atomic replacement in between
        // cannot pair one record with another file's date.
        let data: Data
        let savedAt: Date
        do {
            data = try handle.readToEnd() ?? Data()
            savedAt = try modificationDate(of: handle)
        } catch {
            throw RunRecordError.unreadable(error)
        }

        do {
            return StoredRunRecord(record: try JSONDecoder().decode(WorkoutRunRecord.self, from: data), savedAt: savedAt)
        } catch WorkoutRunRecord.DecodingFailure.unsupportedSchema(let version) {
            throw RunRecordError.unsupportedSchema(version)
        } catch {
            throw RunRecordError.corrupt(error)
        }
    }

    private static func modificationDate(of handle: FileHandle) throws -> Date {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let modified = info.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(modified.tv_sec) + TimeInterval(modified.tv_nsec) / 1_000_000_000)
    }
}
