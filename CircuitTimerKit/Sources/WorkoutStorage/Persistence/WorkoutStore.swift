import Dependencies
import Foundation
import os
import SwiftData
import WorkoutDomain

/// Serializes the store's operations. Each runs in a context of its own, so it reads what CloudKit imported
/// after the previous one instead of objects an older context still holds. Every write either saves completely
/// or rolls back.
@ModelActor
actor WorkoutStore {
    private static let sampleSeedKey = "sample-workout-v1"
    /// Marks a workout deleted on some device, so a copy that syncs in later, or a sample seeded again, stays gone.
    private static let deletionKeyPrefix = "deleted:"

    @Dependency(\.uuid) private var uuid

    private var saveContext: @Sendable (ModelContext) throws -> Void = { try $0.save() }

    /// Replaces the save point, so tests can make a write fail; the app uses the generated
    /// `init(modelContainer:)`, which saves the context.
    init(modelContainer: ModelContainer, saveContext: @escaping @Sendable (ModelContext) throws -> Void) {
        modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))
        self.modelContainer = modelContainer
        self.saveContext = saveContext
    }

    func fetchAll() throws -> StoredWorkouts {
        do {
            try assignMissingCopyIDs()
        } catch {
            // The records still read; copies without an identifier only lose ties until the next read assigns one.
            Logger.workoutStore.error("Failed to assign copy identifiers: \(String(reflecting: error), privacy: .public)")
        }

        do {
            try removeDeletedCopies()
        } catch {
            // The marked copies stay hidden on read; removing them is retried on the next read.
            Logger.workoutStore.error("Failed to remove deleted workouts: \(String(reflecting: error), privacy: .public)")
        }

        var seedingError: (any Error)?
        do {
            try seedSampleIfNeeded()
        } catch {
            seedingError = error
        }

        let context = ModelContext(modelContainer)
        let records = primaryRecords(in: try allSorted(in: context), deleted: try deletedIDs(in: context))
        if let seedingError {
            // Without a workout to show, an empty list would hide the failure: report it so the user can retry.
            // Otherwise the user's own workouts load and seeding is retried on the next read.
            guard !records.primaries.isEmpty else { throw seedingError }

            Logger.workoutStore.error("Failed to seed the sample workout: \(String(reflecting: seedingError), privacy: .public)")
        }
        return StoredWorkouts(workouts: records.primaries.map(\.workout), hiddenRecordCount: records.hiddenRecordCount)
    }

    /// Updates the visible record of `workout`, or appends a new one; writes nothing for a workout deleted on a device.
    func save(_ workout: Workout) throws -> WorkoutSaveOutcome {
        try validate(workout)
        return try write { context in
            let deleted = try deletedIDs(in: context)
            guard !deleted.contains(workout.id) else {
                Logger.workoutStore.notice("Workout \(workout.id, privacy: .public) to save was deleted on a device")
                return .deletedElsewhere
            }

            if let model = primaryRecords(in: try allSorted(in: context), deleted: deleted).model(for: workout.id) {
                model.update(from: workout, in: context)
                // Saved by the user, so a sample another device seeds later never outranks it.
                model.assign(false, to: \.isFreshSample)
            } else {
                try append(workout, in: context)
            }
            return .saved
        }
    }

    /// Inserts `workout` right after the visible record of `anchorID`, gathering the anchor's hidden copies
    /// in between so the visible order matches the caller's list. Without a visible anchor it appends the
    /// workout and reports `.storeDiverged`.
    func insert(_ workout: Workout, after anchorID: Workout.ID) throws -> WorkoutWriteOutcome {
        try validate(workout)
        return try write { context in
            let all = try allSorted(in: context)
            let records = primaryRecords(in: all, deleted: try deletedIDs(in: context))
            guard let anchor = records.model(for: anchorID) else {
                Logger.workoutStore.notice("Insert anchor \(anchorID, privacy: .public) is not visible; appending")
                try append(workout, in: context)
                return .storeDiverged
            }

            let anchorGroup = records.recordsOfWorkout(anchorID)
            let anchorGroupIDs = Set(anchorGroup.map(ObjectIdentifier.init))
            let model = makeModel(for: workout, in: context)
            var ordered: [WorkoutModel] = []
            for record in all where record === anchor || !anchorGroupIDs.contains(ObjectIdentifier(record)) {
                ordered.append(record)
                if record === anchor {
                    ordered += anchorGroup.dropFirst()
                    ordered.append(model)
                }
            }
            renumber(ordered)
            return .applied
        }
    }

    /// Deletes every copy of the visible workout `id` and marks it deleted, so no device shows it again.
    /// Reports `.storeDiverged` when `id` is not visible.
    func delete(_ id: Workout.ID) throws -> WorkoutWriteOutcome {
        try write { context in
            let all = try allSorted(in: context)
            guard primaryRecords(in: all, deleted: try deletedIDs(in: context)).model(for: id) != nil else {
                Logger.workoutStore.notice("Workout \(id, privacy: .public) to delete is not visible")
                return .storeDiverged
            }

            for model in all where model.workoutID == id {
                context.delete(model)
            }
            context.insert(SeedMarkerModel(key: Self.deletionKeyPrefix + id.uuidString))
            return .applied
        }
    }

    /// Orders the visible records as `ids`, each followed by its hidden copies; records the caller did not
    /// list keep their relative order after them. Reports `.storeDiverged` unless `ids` are exactly the
    /// visible workouts.
    func reorder(_ ids: [Workout.ID]) throws -> WorkoutWriteOutcome {
        try write { context in
            let all = try allSorted(in: context)
            let records = primaryRecords(in: all, deleted: try deletedIDs(in: context))

            var ordered: [WorkoutModel] = []
            var placedIDs: Set<ObjectIdentifier> = []
            for id in ids {
                for model in records.recordsOfWorkout(id) where placedIDs.insert(ObjectIdentifier(model)).inserted {
                    ordered.append(model)
                }
            }
            renumber(ordered + all.filter { !placedIDs.contains(ObjectIdentifier($0)) })

            guard Set(records.primaries.map(\.workout.id)) == Set(ids) else {
                Logger.workoutStore.notice("Reorder listed a different set of workouts than storage shows")
                return .storeDiverged
            }
            return .applied
        }
    }

    /// Stages are matched by identifier, so a repeated one would be written as a record that never reads back.
    private func validate(_ workout: Workout) throws(WorkoutStoreError) {
        let stageIDs = WorkoutSectionKind.allCases.flatMap { workout[$0].map(\.id) }
        guard Set(stageIDs).count == stageIDs.count else { throw .repeatedStageIDs }
    }

    private func write<Value>(_ body: (ModelContext) throws -> Value) throws -> Value {
        let context = ModelContext(modelContainer)
        do {
            let result = try body(context)
            try saveContext(context)
            return result
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Checked on every read: signing out of iCloud can remove the synced marker together with the sample, and the
    /// sample then comes back once, as on a new device.
    private func seedSampleIfNeeded() throws {
        let key = Self.sampleSeedKey
        let marker = FetchDescriptor<SeedMarkerModel>(predicate: #Predicate { $0.key == key })
        guard try ModelContext(modelContainer).fetchCount(marker) == 0 else { return }

        try write { context in
            guard try context.fetchCount(marker) == 0 else { return }

            let sample = Workout.sample
            guard try !deletedIDs(in: context).contains(sample.id) else { return }

            let sampleID: UUID? = sample.id
            let existing = try context.fetchCount(
                FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.workoutID == sampleID })
            )
            if existing == 0 {
                try append(sample, in: context).isFreshSample = true
            }
            context.insert(SeedMarkerModel(key: key))
        }
    }

    /// Workouts deleted on some device. Markers are few, so they are filtered here rather than by a predicate.
    private func deletedIDs(in context: ModelContext) throws -> Set<UUID> {
        let prefix = Self.deletionKeyPrefix
        return Set(try context.fetch(FetchDescriptor<SeedMarkerModel>()).compactMap { marker in
            marker.key.hasPrefix(prefix) ? UUID(uuidString: String(marker.key.dropFirst(prefix.count))) : nil
        })
    }

    /// Removes copies of deleted workouts that synced in after the deletion, readable or not.
    private func removeDeletedCopies() throws {
        let probe = ModelContext(modelContainer)
        let deleted = try deletedIDs(in: probe)
        guard try probe.fetch(FetchDescriptor<WorkoutModel>()).contains(where: { $0.workoutID.map(deleted.contains) == true }) else {
            return
        }

        try write { context in
            for model in try context.fetch(FetchDescriptor<WorkoutModel>()) where model.workoutID.map(deleted.contains) == true {
                context.delete(model)
            }
        }
    }

    /// Gives records from before V2, and any that arrive without one, the identifier that orders their copies.
    private func assignMissingCopyIDs() throws {
        let missing = FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.copyID == nil })
        guard try ModelContext(modelContainer).fetchCount(missing) > 0 else { return }

        try write { context in
            for model in try context.fetch(missing) {
                model.copyID = uuid()
            }
        }
    }

    @discardableResult
    private func append(_ workout: Workout, in context: ModelContext) throws -> WorkoutModel {
        // Computed before the new model is inserted, so it never counts itself.
        let order = try nextOrder(in: context)
        let model = makeModel(for: workout, in: context)
        model.order = order
        return model
    }

    private func makeModel(for workout: Workout, in context: ModelContext) -> WorkoutModel {
        let model = WorkoutModel(workoutID: workout.id)
        model.copyID = uuid()
        context.insert(model)
        model.update(from: workout, in: context)
        return model
    }

    private func nextOrder(in context: ModelContext) throws -> Int {
        let all = try allSorted(in: context)
        guard let last = all.last else { return 0 }

        let (next, overflow) = last.order.addingReportingOverflow(1)
        guard overflow else { return next }

        renumber(all)
        return all.count
    }

    private func renumber(_ ordered: [WorkoutModel]) {
        for (index, model) in ordered.enumerated() where model.order != index {
            model.order = index
        }
    }

    /// Stored order, the same on every device: equal `order` values, as two devices can write, are broken by
    /// identifiers that sync, and `persistentModelID`, which differs per device, only settles what they leave equal.
    private func allSorted(in context: ModelContext) throws -> [WorkoutModel] {
        try context.fetch(FetchDescriptor<WorkoutModel>()).sorted(by: WorkoutModel.precedesInStoredOrder)
    }

    /// Picks the visible record of every workout: of its readable copies, the one with the lowest copy rank, which every
    /// device picks alike. Reads and writes go through it, so an edit always lands in the record the user sees. The
    /// other readable copies are a workout already shown, so they stay stored and are not reported as hidden.
    private func primaryRecords(in sorted: [WorkoutModel], deleted: Set<UUID>) -> PrimaryRecords {
        var records = PrimaryRecords()
        var groupOrder: [UUID] = []
        for model in sorted {
            guard let id = model.workoutID else {
                Logger.workoutStore.error("Skipping a stored workout without an identifier")
                records.hiddenRecordCount += 1
                continue
            }
            // A deleted workout is gone for the user, so its late copies are not reported as hidden either.
            guard !deleted.contains(id) else { continue }

            if records.groups[id] == nil {
                groupOrder.append(id)
            }
            records.groups[id, default: []].append(model)
        }

        for id in groupOrder {
            let group = records.groups[id] ?? []
            let readable = group.compactMap(readable)
            guard let primary = readable.min(by: { $0.model.copyRank < $1.model.copyRank }) else {
                records.hiddenRecordCount += group.count
                continue
            }
            records.primaries.append(primary)
            records.hiddenRecordCount += group.count - readable.count
        }
        let position = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { (ObjectIdentifier($1), $0) })
        records.primaries.sort { position[ObjectIdentifier($0.model), default: 0] < position[ObjectIdentifier($1.model), default: 0] }
        return records
    }

    private func readable(_ model: WorkoutModel) -> (model: WorkoutModel, workout: Workout)? {
        do {
            return (model, try model.toDomain())
        } catch {
            Logger.workoutStore.error("Skipping an unreadable stored workout: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

private extension WorkoutModel {
    static func precedesInStoredOrder(_ lhs: WorkoutModel, _ rhs: WorkoutModel) -> Bool {
        if lhs.order != rhs.order {
            return lhs.order < rhs.order
        }
        let (lhsID, rhsID) = (lhs.workoutID?.uuidString ?? "", rhs.workoutID?.uuidString ?? "")
        if lhsID != rhsID {
            return lhsID < rhsID
        }
        if lhs.copyRank != rhs.copyRank {
            return lhs.copyRank < rhs.copyRank
        }
        return lhs.persistentModelID < rhs.persistentModelID
    }

    /// Which copy of a workout shows: one a device seeded and nobody changed loses to any other, then the lower
    /// identifier wins. A copy without one ranks last; uppercase hexadecimal sorts before "~".
    var copyRank: (Int, String) {
        (isFreshSample ? 1 : 0, copyID?.uuidString ?? "~")
    }
}

private struct PrimaryRecords {
    var primaries: [(model: WorkoutModel, workout: Workout)] = []
    /// Every record of a workout, in stored order.
    var groups: [UUID: [WorkoutModel]] = [:]
    var hiddenRecordCount = 0

    func model(for id: Workout.ID) -> WorkoutModel? {
        primaries.first { $0.workout.id == id }?.model
    }

    /// The visible record of `id` followed by its hidden copies; empty when `id` is not visible.
    func recordsOfWorkout(_ id: Workout.ID) -> [WorkoutModel] {
        guard let primary = model(for: id) else { return [] }

        return [primary] + (groups[id] ?? []).filter { $0 !== primary }
    }
}

enum WorkoutStoreError: Error, Equatable {
    /// The workout has two stages with the same identifier.
    case repeatedStageIDs
}
