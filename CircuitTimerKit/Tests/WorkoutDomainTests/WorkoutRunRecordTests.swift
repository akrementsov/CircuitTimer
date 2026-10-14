@testable import WorkoutDomain

import Foundation
import Testing

@Suite
struct WorkoutRunRecordTests {
    @Test
    func test_encodeDecode_running_keepsV1KeysAndMilliseconds() throws {
        let workout = makePausedWorkout()
        var run = makeRun(workout)
        run.start(at: origin)
        run.tick(at: moment(1.234))
        let record = try #require(WorkoutRunRecord(workoutID: workout.id, run: run))
        let data = try JSONEncoder().encode(record)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(json.keys) == ["schemaVersion", "workoutID", "scheduleFingerprint", "phase", "positionMs", "cursor", "sinceEpochMs"])
        #expect(record.positionMs == 1_234)
        #expect(record.since == moment(1.234))
        #expect(try JSONDecoder().decode(WorkoutRunRecord.self, from: data) == record)
    }

    @Test(arguments: [-1, 0, 2])
    func test_decode_unsupportedSchema_reportsVersionBeforeOtherFields(version: Int) {
        let data = Data("{\"schemaVersion\":\(version)}".utf8)
        #expect(throws: WorkoutRunRecord.SchemaError.unsupportedSchema(version)) {
            try JSONDecoder().decode(WorkoutRunRecord.self, from: data)
        }
    }

    @Test(arguments: WorkoutRunRecord.Phase.allCases)
    func test_encode_phase_pinsV1JSONContract(phase: WorkoutRunRecord.Phase) throws {
        let anchor: Int64? = phase == .running ? 1_700_000_000_123 : nil
        let record = WorkoutRunRecord(
            workoutID: UUID(fixture: 1),
            scheduleFingerprint: "known-fingerprint",
            phase: phase,
            positionMs: 1_234,
            cursor: 2,
            sinceEpochMs: anchor,
        )
        let phaseToken: String
        switch phase {
            case .running: phaseToken = "running"
            case .paused: phaseToken = "paused"
            case .awaitingUser: phaseToken = "awaitingUser"
        }
        let anchorField = anchor == nil ? "" : ",\"sinceEpochMs\":1700000000123"
        let expected = "{\"cursor\":2,\"phase\":\"\(phaseToken)\",\"positionMs\":1234,"
            + "\"scheduleFingerprint\":\"known-fingerprint\",\"schemaVersion\":1\(anchorField),"
            + "\"workoutID\":\"00000000-0000-0000-0000-000000000001\"}"
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        #expect(try encoder.encode(record) == Data(expected.utf8))
        #expect(try JSONDecoder().decode(WorkoutRunRecord.self, from: Data(expected.utf8)) == record)
    }

    @Test
    func test_record_idleOrFinished_hasNothingToRestore() {
        let workout = makePausedWorkout()
        var run = makeRun(workout)
        #expect(WorkoutRunRecord(workoutID: workout.id, run: run) == nil)
        run.start(at: origin)
        run.tick(at: moment(15))
        run.resume(at: moment(15))
        run.tick(at: moment(30))
        #expect(WorkoutRunRecord(workoutID: workout.id, run: run) == nil)
    }
}
