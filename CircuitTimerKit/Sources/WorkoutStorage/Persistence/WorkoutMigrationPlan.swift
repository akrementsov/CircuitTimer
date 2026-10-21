import SwiftData

enum WorkoutMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [WorkoutSchemaV1.self, WorkoutSchemaV2.self] }
    /// V2 only adds properties with defaults; the records' copy identifiers are assigned on the next read.
    static var stages: [MigrationStage] { [.lightweight(fromVersion: WorkoutSchemaV1.self, toVersion: WorkoutSchemaV2.self)] }
}
