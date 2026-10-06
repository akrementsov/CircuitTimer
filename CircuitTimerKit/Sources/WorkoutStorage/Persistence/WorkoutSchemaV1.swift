import Foundation
import SwiftData

/// The first persisted shape of workouts.
///
/// Built to sync through CloudKit later (CT-5): no unique attributes, every property has a default
/// or is optional, relationships are optional, and order is an explicit field because CloudKit
/// keeps no order for relationships. Durations are whole milliseconds.
enum WorkoutSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [WorkoutModel.self, StageModel.self, SeedMarkerModel.self] }

    @Model
    final class WorkoutModel {
        var workoutID: UUID?
        var name: String = ""
        var order: Int = 0
        var trainingRounds: Int = 1
        var pauseAfterWarmUp: Bool = false
        var pauseAfterTraining: Bool = false
        @Relationship(deleteRule: .cascade, inverse: \StageModel.workout)
        var stages: [StageModel]? = []

        init(workoutID: UUID) {
            self.workoutID = workoutID
        }
    }

    @Model
    final class StageModel {
        var stageID: UUID?
        var name: String = ""
        var durationMs: Int = 0
        var intensity: String = ""
        var section: String = ""
        var order: Int = 0
        var workout: WorkoutModel?

        init(stageID: UUID) {
            self.stageID = stageID
        }
    }

    /// Records that the sample workout was seeded, so deleting it never brings it back.
    @Model
    final class SeedMarkerModel {
        var key: String = ""

        init(key: String) {
            self.key = key
        }
    }
}

typealias WorkoutModel = WorkoutSchemaV1.WorkoutModel
typealias StageModel = WorkoutSchemaV1.StageModel
typealias SeedMarkerModel = WorkoutSchemaV1.SeedMarkerModel
