@testable import WorkoutStorage

import Foundation
import Testing
import WorkoutDomain

@Suite
struct WorkoutRunRecordFileTests {
    @Test
    func test_loadAndClear_missingFile_returnsNilAndClearsIdempotently() async throws {
        try await withRunRecordFolder { root in
            let directory = root.appending(path: "NotCreated", directoryHint: .isDirectory)
            let client = WorkoutRunRecordClient.file(directory: directory)

            #expect(try await client.load() == nil)
            try await client.write(nil, client.nextRevision())
            try await client.write(nil, client.nextRevision())
            #expect(try await client.load() == nil)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @Test
    func test_writeAndLoad_newClient_readsRecordAndFileModificationDate() async throws {
        try await withRunRecordFolder { root in
            let client = WorkoutRunRecordClient.file(directory: root)
            let record = makeRunRecord()
            try await client.write(record, client.nextRevision())
            let file = RunRecordLayout.fileURL(in: root)
            let savedAt = Date(timeIntervalSince1970: 1_700_000_100)
            try FileManager.default.setAttributes([.modificationDate: savedAt], ofItemAtPath: file.path)

            let relaunched = WorkoutRunRecordClient.file(directory: root)
            let loaded = try #require(try await relaunched.load())

            #expect(loaded == StoredRunRecord(record: record, savedAt: savedAt))
            #expect(try JSONDecoder().decode(WorkoutRunRecord.self, from: Data(contentsOf: file)) == record)
            try await relaunched.write(makeRunRecord(2), relaunched.nextRevision())
            #expect(try await client.load()?.record == makeRunRecord(2))
        }
    }

    @Test
    func test_write_olderOrRepeatedRevision_preservesNewestRecord() async throws {
        try await withRunRecordFolder { root in
            let client = WorkoutRunRecordClient.file(directory: root)
            try await client.write(makeRunRecord(2), 2)

            try await client.write(makeRunRecord(1), 1)
            try await client.write(nil, 2)
            #expect(try await client.load()?.record == makeRunRecord(2))

            try await client.write(nil, 3)
            try await client.write(makeRunRecord(1), 2)
            #expect(try await client.load() == nil)
            try await client.write(makeRunRecord(4), 4)
            #expect(try await client.load()?.record == makeRunRecord(4))
        }
    }

    @Test(arguments: [false, true])
    func test_write_newerOperationFails_keepsFileAndRejectsOlderRevision(clearing: Bool) async throws {
        try await withRunRecordFolder { root in
            let directory = root.appending(path: "RunRecord", directoryHint: .isDirectory)
            let displaced = root.appending(path: "Displaced", directoryHint: .isDirectory)
            let client = WorkoutRunRecordClient.file(directory: directory)
            let original = makeRunRecord()
            try await client.write(original, 1)
            let originalData = try Data(contentsOf: RunRecordLayout.fileURL(in: directory))
            try FileManager.default.moveItem(at: directory, to: displaced)
            try Data("blocks directory access".utf8).write(to: directory)

            await #expect(throws: (any Error).self) {
                try await client.write(clearing ? nil : makeRunRecord(3), 3)
            }

            try FileManager.default.removeItem(at: directory)
            try FileManager.default.moveItem(at: displaced, to: directory)
            #expect(try Data(contentsOf: RunRecordLayout.fileURL(in: directory)) == originalData)
            try await client.write(makeRunRecord(2), 2)
            #expect(try await client.load()?.record == original)
            try await client.write(makeRunRecord(4), 4)
            #expect(try await client.load()?.record == makeRunRecord(4))
        }
    }

    @Test
    func test_nextRevision_concurrentCallers_getUniqueContiguousRevisions() async throws {
        try await withRunRecordFolder { root in
            let client = WorkoutRunRecordClient.file(directory: root)
            let revisions = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
                for _ in 0..<100 {
                    group.addTask { client.nextRevision() }
                }
                var revisions: [Int] = []
                for await revision in group {
                    revisions.append(revision)
                }
                return revisions
            }

            #expect(revisions.sorted() == Array(1...100))
            #expect(client.nextRevision() == 101)
        }
    }
}
