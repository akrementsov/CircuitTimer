import SwiftData

extension ModelContainer {
    /// The workouts store, mirrored to the private database of `cloudKitContainer` when one is given. Either way it is
    /// the same file, so turning sync off or on keeps the workouts on the device.
    static func workouts(isStoredInMemoryOnly: Bool, cloudKitContainer: String? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: WorkoutSchemaV2.self)
        let configuration = ModelConfiguration(
            "Workouts",
            schema: schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            cloudKitDatabase: cloudKitContainer.map { .private($0) } ?? .none
        )
        return try ModelContainer(for: schema, migrationPlan: WorkoutMigrationPlan.self, configurations: configuration)
    }
}
