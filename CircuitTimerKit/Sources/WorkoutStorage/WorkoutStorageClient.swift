import Dependencies
import DependenciesMacros
import WorkoutDomain

/// Reads the user's workouts. Writing and SwiftData persistence arrive with the editor.
@DependencyClient
public struct WorkoutStorageClient: Sendable {
    public var fetchAll: @Sendable () async throws -> [Workout]
}

extension WorkoutStorageClient {
    public static func inMemory(_ seed: [Workout]) -> Self {
        Self(fetchAll: { seed })
    }
}

extension WorkoutStorageClient: DependencyKey {
    // TODO: [CT-2] Replace with SwiftData-backed live value.
    public static let liveValue = Self.inMemory([.sample])
    public static let previewValue = Self.inMemory([.sample])
    /// Declared explicitly: without it, tests would silently fall back to `liveValue`.
    public static let testValue = Self()
}

extension DependencyValues {
    public var workoutStorage: WorkoutStorageClient {
        get { self[WorkoutStorageClient.self] }
        set { self[WorkoutStorageClient.self] = newValue }
    }
}
