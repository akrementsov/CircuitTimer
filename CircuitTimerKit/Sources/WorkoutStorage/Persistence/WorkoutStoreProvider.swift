import CloudSync
import Dependencies
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

    /// The app's store on disk, mirrored to iCloud when this launch syncs. A store that fails to open with CloudKit
    /// opens on the device instead, so the list keeps working; only a store that fails both ways reports an error.
    static func live() -> WorkoutStoreProvider {
        WorkoutStoreProvider {
            @Dependency(\.cloudSync) var cloudSync
            if let container = cloudSync.mirroredContainer() {
                do {
                    let mirrored = try ModelContainer.workouts(isStoredInMemoryOnly: false, cloudKitContainer: container)
                    cloudSync.storeOpened(true)
                    return mirrored
                } catch {
                    Logger.workoutStore.fault(
                        "Failed to open the workouts store with iCloud sync; opening it on the device: \(String(reflecting: error), privacy: .public)"
                    )
                }
            }
            let local = try ModelContainer.workouts(isStoredInMemoryOnly: false)
            cloudSync.storeOpened(false)
            return local
        }
    }

    /// Lets tests supply the container they inspect, or make opening it fail.
    init(makeContainer: @escaping @Sendable () throws -> ModelContainer) {
        self.makeContainer = makeContainer
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
