import SwiftData

enum WorkoutMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [WorkoutSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
