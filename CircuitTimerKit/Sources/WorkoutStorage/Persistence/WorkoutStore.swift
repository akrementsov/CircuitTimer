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

    @Dependency(\.uuid) private var uuid

    private var isSampleSeedChecked = false
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

        var seedingError: (any Error)?
        do {
            try seedSampleIfNeeded()
        } catch {
            seedingError = error
        }

        let records = primaryRecords(in: try allSorted(in: ModelContext(modelContainer)))
        if let seedingError {
            // Without a workout to show, an empty list would hide the failure: report it so the user can retry.
            // Otherwise the user's own workouts load and seeding is retried on the next read.
            guard !records.primaries.isEmpty else { throw seedingError }

            Logger.workoutStore.error("Failed to seed the sample workout: \(String(reflecting: seedingError), privacy: .public)")
        }
        return StoredWorkouts(workouts: records.primaries.map(\.workout), hiddenRecordCount: records.hiddenRecordCount)
    }

    /// Updates the visible record of `workout`, or appends a new one.
    func save(_ workout: Workout) throws {
        try validate(workout)
        try write { context in
            if let model = primaryRecords(in: try allSorted(in: context)).model(for: workout.id) {
                model.update(from: workout, in: context)
            } else {
                try append(workout, in: context)
            }
        }
    }

    /// Inserts `workout` right after the visible record of `anchorID`, gathering the anchor's hidden copies
    /// in between so the visible order matches the caller's list. Without a visible anchor it appends the
    /// workout and reports `.storeDiverged`.
    func insert(_ workout: Workout, after anchorID: Workout.ID) throws -> WorkoutWriteOutcome {
        try validate(workout)
        return try write { context in
            let all = try allSorted(in: context)
            let records = primaryRecords(in: all)
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

    /// Deletes the visible record of `id` only: the user deletes exactly what they see.
    /// Reports `.storeDiverged` when hidden copies remain, because one of them becomes visible.
    func delete(_ id: Workout.ID) throws -> WorkoutWriteOutcome {
        try write { context in
            let all = try allSorted(in: context)
            guard let model = primaryRecords(in: all).model(for: id) else {
                Logger.workoutStore.notice("Workout \(id, privacy: .public) to delete is not visible")
                return .storeDiverged
            }

            context.delete(model)
            guard !all.contains(where: { $0.workoutID == id && $0 !== model }) else {
                Logger.workoutStore.notice("Workout \(id, privacy: .public) has hidden copies left after delete")
                return .storeDiverged
            }
            return .applied
        }
    }

    /// Orders the visible records as `ids`, each followed by its hidden copies; records the caller did not
    /// list keep their relative order after them. Reports `.storeDiverged` unless `ids` are exactly the
    /// visible workouts.
    func reorder(_ ids: [Workout.ID]) throws -> WorkoutWriteOutcome {
        try write { context in
            let all = try allSorted(in: context)
            let records = primaryRecords(in: all)

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

    private func seedSampleIfNeeded() throws {
        guard !isSampleSeedChecked else { return }

        try write { context in
            let key = Self.sampleSeedKey
            let markers = try context.fetchCount(FetchDescriptor<SeedMarkerModel>(predicate: #Predicate { $0.key == key }))
            guard markers == 0 else { return }

            let sample = Workout.sample
            let sampleID: UUID? = sample.id
            let existing = try context.fetchCount(
                FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.workoutID == sampleID })
            )
            if existing == 0 {
                try append(sample, in: context).isFreshSample = true
            }
            context.insert(SeedMarkerModel(key: key))
        }
        isSampleSeedChecked = true
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
        try context.fetch(FetchDescriptor<WorkoutModel>()).sorted { $0.storedRank < $1.storedRank }
    }

    /// Picks the visible record of every workout: the first readable one in stored order.
    /// Reads and writes go through it, so an edit always lands in the record the user sees.
    private func primaryRecords(in sorted: [WorkoutModel]) -> PrimaryRecords {
        var records = PrimaryRecords()
        var groupOrder: [UUID] = []
        for model in sorted {
            guard let id = model.workoutID else {
                Logger.workoutStore.error("Skipping a stored workout without an identifier")
                records.hiddenRecordCount += 1
                continue
            }
            if records.groups[id] == nil {
                groupOrder.append(id)
            }
            records.groups[id, default: []].append(model)
        }

        for id in groupOrder {
            let group = records.groups[id] ?? []
            guard let primary = firstReadable(in: group) else {
                records.hiddenRecordCount += group.count
                continue
            }
            records.primaries.append(primary)
            records.hiddenRecordCount += group.count - 1
        }
        let position = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { (ObjectIdentifier($1), $0) })
        records.primaries.sort { position[ObjectIdentifier($0.model), default: 0] < position[ObjectIdentifier($1.model), default: 0] }
        return records
    }

    private func firstReadable(in group: [WorkoutModel]) -> (model: WorkoutModel, workout: Workout)? {
        for model in group {
            do {
                return (model, try model.toDomain())
            } catch {
                Logger.workoutStore.error("Skipping an unreadable stored workout: \(String(describing: error), privacy: .public)")
            }
        }
        return nil
    }
}

private extension WorkoutModel {
    /// A copy without an identifier sorts after every copy with one; uppercase hexadecimal sorts before "~".
    var storedRank: (Int, String, Int, String, PersistentIdentifier) {
        (order, workoutID?.uuidString ?? "", isFreshSample ? 1 : 0, copyID?.uuidString ?? "~", persistentModelID)
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
