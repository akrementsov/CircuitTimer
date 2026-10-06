import os
import SwiftData

/// Opens the store on first use, off the main actor, and retries after a failed open.
///
/// A failure is not cached, so a retry really reopens the store. The store lives in this actor,
/// which lives in the dependency value, so there is no global mutable state.
actor WorkoutStoreProvider {
    private let makeContainer: @Sendable () throws -> ModelContainer
    private var openedStore: WorkoutStore?

    init(isStoredInMemoryOnly: Bool) {
        makeContainer = { try .workouts(isStoredInMemoryOnly: isStoredInMemoryOnly) }
    }

    /// Wraps an existing container, so tests can inspect the store they write through.
    init(container: ModelContainer) {
        makeContainer = { container }
    }

    func store() throws -> WorkoutStore {
        if let openedStore {
            return openedStore
        }

        do {
            let store = WorkoutStore(modelContainer: try makeContainer())
            openedStore = store
            return store
        } catch {
            Logger.workoutStore.fault("Failed to open the workouts store: \(String(reflecting: error), privacy: .public)")
            throw error
        }
    }
}
