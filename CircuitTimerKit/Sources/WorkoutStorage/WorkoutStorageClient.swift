import CloudSync
import Dependencies
import DependenciesMacros
import WorkoutDomain

/// The readable workouts in list order, and how many stored records could not be shown.
public struct StoredWorkouts: Equatable, Sendable {
    /// One visible record per workout, in list order, with unique identifiers.
    public var workouts: [Workout]
    /// Records that are not shown: those that would lose data when read, and extra copies of a shown workout.
    public var hiddenRecordCount: Int

    public init(workouts: [Workout], hiddenRecordCount: Int = 0) {
        self.workouts = workouts
        self.hiddenRecordCount = hiddenRecordCount
    }
}

/// Whether a save was written.
public enum WorkoutSaveOutcome: Equatable, Sendable {
    case saved
    /// The workout was deleted on a device, so nothing was written; the caller's copy no longer exists.
    case deletedElsewhere
}

/// Whether the store still matches the list the caller derived the write from.
public enum WorkoutWriteOutcome: Equatable, Sendable {
    case applied
    /// The store now differs from what the caller's list assumes; reload it.
    case storeDiverged
}

@DependencyClient
public struct WorkoutStorageClient: Sendable {
    /// Seeds the sample workout unless its marker exists, gives older records their copy identifiers, removes late copies of deleted
    /// workouts, then reads all workouts.
    public var fetchAll: @Sendable () async throws -> StoredWorkouts
    /// Updates the workout, or appends it when it is new; reports `.deletedElsewhere` and writes nothing for a
    /// workout deleted on a device.
    public var save: @Sendable (_ workout: Workout) async throws -> WorkoutSaveOutcome
    /// Inserts a new workout right after `after`; appends it and reports `.storeDiverged` when `after` is not shown.
    public var insert: @Sendable (_ workout: Workout, _ after: Workout.ID) async throws -> WorkoutWriteOutcome
    /// Deletes every copy of the shown workout for all devices; reports `.storeDiverged` when it is not shown.
    public var delete: @Sendable (_ id: Workout.ID) async throws -> WorkoutWriteOutcome
    /// Orders the shown workouts; reports `.storeDiverged` unless `ids` are exactly the shown workouts.
    public var reorder: @Sendable (_ ids: [Workout.ID]) async throws -> WorkoutWriteOutcome
}

extension WorkoutStorageClient {
    static func swiftData(isStoredInMemoryOnly: Bool) -> Self {
        swiftData(provider: WorkoutStoreProvider(isStoredInMemoryOnly: isStoredInMemoryOnly))
    }

    /// `prepare` runs before every operation: the live store waits there, once per process, for CloudSync to know
    /// whether this launch may mirror, so the provider opens the store once, synchronously, with the final answer.
    static func swiftData(
        provider: WorkoutStoreProvider,
        prepare: @escaping @Sendable () async -> Void = {}
    ) -> Self {
        Self(
            fetchAll: {
                await prepare()
                return try await provider.store().fetchAll()
            },
            save: {
                await prepare()
                return try await provider.store().save($0)
            },
            insert: {
                await prepare()
                return try await provider.store().insert($0, after: $1)
            },
            delete: {
                await prepare()
                return try await provider.store().delete($0)
            },
            reorder: {
                await prepare()
                return try await provider.store().reorder($0)
            }
        )
    }
}

extension WorkoutStorageClient: DependencyKey {
    public static let liveValue = Self.swiftData(provider: .live()) {
        @Dependency(\.cloudSync) var cloudSync
        await cloudSync.prepareDecision()
    }
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
