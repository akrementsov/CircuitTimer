import Foundation
import SwiftData

/// The persisted shape of workouts that syncs through CloudKit.
///
/// CloudKit allows no unique attributes, so every property has a default or is optional, relationships are optional,
/// and order is an explicit field because CloudKit keeps no order for relationships. Durations are whole milliseconds.
/// Once deployed to the Production CloudKit schema, later versions may only add to it.
enum WorkoutSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [WorkoutModel.self, StageModel.self, SeedMarkerModel.self] }

    @Model
    final class WorkoutModel {
        var workoutID: UUID?
        /// Tells apart copies of one workout that devices wrote independently, the same way on every device.
        /// Never changes once set; records from before V2 get one on the next read.
        var copyID: UUID?
        /// A sample this device seeded and nobody has changed yet, so any other copy of it wins.
        var isFreshSample: Bool = false
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

typealias WorkoutModel = WorkoutSchemaV2.WorkoutModel
typealias StageModel = WorkoutSchemaV2.StageModel
typealias SeedMarkerModel = WorkoutSchemaV2.SeedMarkerModel
