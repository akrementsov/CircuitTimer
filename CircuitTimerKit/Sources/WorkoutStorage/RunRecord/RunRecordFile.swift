import Dispatch
import Foundation
import os
import WorkoutDomain

/// Applies run record writes in revision order.
///
/// Each write is one synchronous actor turn on a dedicated serial queue, from the revision
/// check to the last file operation. No other write can interleave with it, and filesystem
/// I/O never blocks the cooperative pool.
actor RunRecordFile {
    nonisolated let writerQueue = DispatchSerialQueue(label: "CircuitTimer.RunRecordFile")
    private let directory: URL
    private var lastAppliedRevision = 0
    private var isExclusionApplied = false

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        writerQueue.asUnownedSerialExecutor()
    }

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
        if !FileManager.default.fileExists(atPath: directory.path) {
            isExclusionApplied = false
        }
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
