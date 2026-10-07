import SwiftData

extension ModelContainer {
    /// The workouts store. CloudKit stays off until sync arrives in CT-5.
    static func workouts(isStoredInMemoryOnly: Bool) throws -> ModelContainer {
        let schema = Schema(versionedSchema: WorkoutSchemaV1.self)
        let configuration = ModelConfiguration(
            "Workouts",
            schema: schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, migrationPlan: WorkoutMigrationPlan.self, configurations: configuration)
    }
}
