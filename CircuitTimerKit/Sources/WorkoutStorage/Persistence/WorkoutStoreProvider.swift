import Foundation
import os
import SwiftData

/// Opens the store on first use, off the main actor, and retries after a failed open.
///
/// A failure is not cached, so «Try again» in the UI really reopens the store. The store lives in
/// this actor, which lives in the dependency value, so there is no global mutable state.
actor WorkoutStoreProvider {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "WorkoutStore")

    private let makeContainer: @Sendable () throws -> ModelContainer
    private var openedStore: WorkoutStore?

    init(isStoredInMemoryOnly: Bool) {
        makeContainer = { try .workouts(isStoredInMemoryOnly: isStoredInMemoryOnly) }
    }

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
            Self.logger.fault("Failed to open the workouts store: \(String(reflecting: error), privacy: .public)")
            throw error
        }
    }
}
