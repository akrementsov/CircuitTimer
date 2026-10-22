#if DEBUG
import CloudSync
import CoreData
import Dependencies
import Foundation
import os
import SwiftData

/// Creates every record type and field of the workouts schema in the container's Development environment, which
/// Production is then deployed from. Mirroring would create them only for the data it happens to upload, and the call
/// also checks that the model suits CloudKit. Debug only: a developer runs it once per schema change.
public enum WorkoutCloudKitSchema {
    public enum Failure: Error {
        case noContainer
        case modelUnavailable
    }

    public static func initialize() throws {
        guard let container = CloudKitContainerID.inMainBundle() else { throw Failure.noContainer }
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: WorkoutSchemaV2.models) else {
            throw Failure.modelUnavailable
        }

        // A store of its own, so the app's store is never touched; it is removed again before the process ends.
        let directory = FileManager.default.temporaryDirectory.appending(path: "CloudKitSchema", directoryHint: .isDirectory)
        removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeItem(at: directory) }

        let description = NSPersistentStoreDescription(url: directory.appending(path: "Workouts.store"))
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: container)
        description.shouldAddStoreAsynchronously = false
        let persistentContainer = NSPersistentCloudKitContainer(name: "Workouts", managedObjectModel: model)
        persistentContainer.persistentStoreDescriptions = [description]

        let loadError = LockIsolated<(any Error)?>(nil)
        persistentContainer.loadPersistentStores { _, error in loadError.setValue(error) }
        if let error = loadError.value {
            throw error
        }
        defer {
            // Unloaded before its files go, so its mirroring stops working on the container.
            let coordinator = persistentContainer.persistentStoreCoordinator
            for store in coordinator.persistentStores {
                do {
                    try coordinator.remove(store)
                } catch {
                    Logger.workoutStore.error("Failed to unload the schema store: \(String(reflecting: error), privacy: .public)")
                }
            }
        }
        try persistentContainer.initializeCloudKitSchema(options: [])
    }

    private static func removeItem(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            Logger.workoutStore.error("Failed to remove the schema store: \(String(reflecting: error), privacy: .public)")
        }
    }
}
#endif
