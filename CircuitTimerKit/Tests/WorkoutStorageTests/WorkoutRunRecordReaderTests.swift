@testable import WorkoutStorage

import Foundation
import Testing

@Suite
struct WorkoutRunRecordReaderTests {
    @Test
    func test_load_unsupportedSchema_reportsVersionAndPreservesBytes() async throws {
        try await withRunRecordFolder { root in
            let file = RunRecordLayout.fileURL(in: root)
            let bytes = Data(#"{"schemaVersion":2,"unknown":"future format"}"#.utf8)
            try bytes.write(to: file)
            let client = WorkoutRunRecordClient.file(directory: root)

            do {
                _ = try await client.load()
                Issue.record("An unsupported schema must not load")
            } catch RunRecordError.unsupportedSchema(let version) {
                #expect(version == 2)
            }

            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test(arguments: ["not JSON", #"{"schemaVersion":1}"#, ""])
    func test_load_corruptFile_reportsCorruptionAndPreservesBytes(contents: String) async throws {
        try await withRunRecordFolder { root in
            let file = RunRecordLayout.fileURL(in: root)
            let bytes = Data(contents.utf8)
            try bytes.write(to: file)
            let client = WorkoutRunRecordClient.file(directory: root)

            do {
                _ = try await client.load()
                Issue.record("A corrupt record must not load")
            } catch RunRecordError.corrupt(let underlying) {
                #expect(underlying is DecodingError)
            }

            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test
    func test_load_directoryInsteadOfFile_reportsUnreadableAndPreservesDirectory() async throws {
        try await withRunRecordFolder { root in
            let file = RunRecordLayout.fileURL(in: root)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            let client = WorkoutRunRecordClient.file(directory: root)

            do {
                _ = try await client.load()
                Issue.record("An unreadable record must not load")
            } catch RunRecordError.unreadable(let underlying) {
                #expect((underlying as? POSIXError)?.code == .EISDIR)
            }

            var isDirectory = ObjCBool(false)
            #expect(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }
}
