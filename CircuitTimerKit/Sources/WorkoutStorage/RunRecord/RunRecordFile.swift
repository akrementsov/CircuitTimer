import Foundation
import os
import WorkoutDomain

/// Applies run record writes in revision order.
///
/// Each write is one synchronous actor turn, from the revision check to the last file
/// operation, so no other write can interleave with it. The file is a few hundred bytes, so
/// doing the I/O inside that turn is cheaper than the ordering a suspension would cost.
actor RunRecordFile {
    private let directory: URL
    private var lastAppliedRevision = 0
    private var isExclusionApplied = false

    init(directory: URL) {
        self.directory = directory
    }

    func write(_ record: WorkoutRunRecord?, revision: Int) throws {
        guard revision > lastAppliedRevision else { return }

        // Advanced before the file operations, so an older write that arrives after a failed
        // newer one is still ignored; the caller retries with a new revision.
        lastAppliedRevision = revision
        let url = RunRecordLayout.fileURL(in: directory)
        if let record {
            try prepareDirectory()
            let data = try JSONEncoder().encode(record)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else {
            try remove(url)
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !isExclusionApplied else { return }

        // A run belongs to this device; restoring it from a backup on another one is meaningless.
        // Best effort: the record matters more than the flag, which the next write tries again.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        do {
            try url.setResourceValues(values)
            isExclusionApplied = true
        } catch {
            Logger.runRecord.error("Excluding run records from backup failed: \(String(reflecting: error), privacy: .public)")
        }
    }

    private func remove(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch where RunRecordLayout.isMissingFile(error) {
            return
        }
    }
}
