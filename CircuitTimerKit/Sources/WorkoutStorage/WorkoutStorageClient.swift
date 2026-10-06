import Dependencies
import DependenciesMacros
import WorkoutDomain

/// The readable workouts in list order, and how many stored records could not be shown.
public struct StoredWorkouts: Equatable, Sendable {
    /// One visible record per workout, in list order, with unique identifiers.
    public var workouts: [Workout]
    /// Workouts without any record that reads back without losing data.
    public var unreadableCount: Int
    /// Extra records of a workout that is already shown.
    public var hiddenDuplicateCount: Int

    public init(workouts: [Workout], unreadableCount: Int = 0, hiddenDuplicateCount: Int = 0) {
        self.workouts = workouts
        self.unreadableCount = unreadableCount
        self.hiddenDuplicateCount = hiddenDuplicateCount
    }
}

/// Whether the store still matches the list the caller derived the write from.
public enum WorkoutWriteOutcome: Equatable, Sendable {
    case applied
    /// The store now differs from what the caller's list assumes; reload it.
    case storeDiverged
}

@DependencyClient
public struct WorkoutStorageClient: Sendable {
    /// Seeds the sample workout once, then reads all workouts.
    public var fetchAll: @Sendable () async throws -> StoredWorkouts
    /// Updates the workout, or appends it when it is new.
    public var save: @Sendable (_ workout: Workout) async throws -> Void
    public var insert: @Sendable (_ workout: Workout, _ after: Workout.ID) async throws -> WorkoutWriteOutcome
    public var delete: @Sendable (_ id: Workout.ID) async throws -> WorkoutWriteOutcome
    public var reorder: @Sendable (_ ids: [Workout.ID]) async throws -> WorkoutWriteOutcome
}

extension WorkoutStorageClient {
    static func swiftData(isStoredInMemoryOnly: Bool) -> Self {
        swiftData(provider: WorkoutStoreProvider(isStoredInMemoryOnly: isStoredInMemoryOnly))
    }

    static func swiftData(provider: WorkoutStoreProvider) -> Self {
        Self(
            fetchAll: { try await provider.store().fetchAll() },
            save: { try await provider.store().save($0) },
            insert: { try await provider.store().insert($0, after: $1) },
            delete: { try await provider.store().delete($0) },
            reorder: { try await provider.store().reorder($0) }
        )
    }
}

extension WorkoutStorageClient: DependencyKey {
    public static let liveValue = Self.swiftData(isStoredInMemoryOnly: false)
    /// In memory, seeded with the sample workout on first read.
    public static let previewValue = Self.swiftData(isStoredInMemoryOnly: true)
    /// Declared explicitly so each endpoint a test forgets to override reports itself as unimplemented,
    /// instead of any access failing the test while preview data is returned.
    public static let testValue = Self()
}

extension DependencyValues {
    public var workoutStorage: WorkoutStorageClient {
        get { self[WorkoutStorageClient.self] }
        set { self[WorkoutStorageClient.self] = newValue }
    }
}
