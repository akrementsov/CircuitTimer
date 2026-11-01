@testable import AppFeature

import ComposableArchitecture
import Foundation
import Testing
import WatchLink
import WorkoutDomain
import WorkoutEditorFeature
import WorkoutStorage

/// The list the iPhone publishes to the watch: only a settled one, once its write or read has finished, under a
/// revision the reducer takes in the order of the actions.
@MainActor
@Suite
struct AppFeatureWatchTests {
    private struct Failure: Error {}

    private let first = makeWorkout(1)
    private let second = makeWorkout(2)

    @Test
    func test_load_publishesTheListInItsOrderOnceItLands() async {
        let watch = WatchPublications()
        let reading = Gate()
        let store = makeStore(AppFeature.State(), watch: watch) {
            $0.workoutStorage.fetchAll = {
                await reading.wait()
                return StoredWorkouts(workouts: [self.second, self.first])
            }
        }

        await store.send(.view(.task)) {
            $0.workouts = .loading
            $0.runRestore = .reading
        }
        await Task.megaYield()
        #expect(watch.revisions.value == 0)
        reading.open()
        await store.receive(.internal(.runRecordLoaded(nil))) { $0.runRestore = .resolved }
        await store.receive(\.internal.workoutsLoaded) { $0.workouts = .loaded([self.second, self.first]) }
        await store.finish()

        #expect(watch.published.value == [
            WatchPublication(revision: 1, catalog: .loaded(WatchCatalog(workouts: [second, first]))),
        ])
    }

    @Test
    func test_mutations_eachPublishesTheListAfterItsWrite() async throws {
        let watch = WatchPublications()
        let deleting = Gate()
        var renamed = first
        renamed.name = "Renamed"
        var state = loaded([first, second])
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: first)))
        let id = try #require(state.path.ids.first)
        let store = makeStore(state, watch: watch) {
            $0.workoutStorage.delete = { _ in
                await deleting.wait()
                return .applied
            }
            $0.workoutStorage.insert = { _, _ in .applied }
            $0.workoutStorage.reorder = { _ in .applied }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: id, action: .editor(.delegate(.saved(renamed))))))
        await store.send(.view(.deleteButtonTapped(second.id)))
        await Task.megaYield()
        #expect(watch.revisions.value == 1)
        deleting.open()
        await store.receive(\.internal.mutationFinished)
        await store.send(.view(.duplicateButtonTapped(first.id)))
        await store.receive(\.internal.mutationFinished)
        await store.send(.view(.workoutsMoved(IndexSet(integer: 1), 0)))
        await store.receive(\.internal.mutationFinished)
        await store.finish()

        let copy = UUID(0)
        #expect(watch.published.value.map(\.revision) == [1, 2, 3, 4])
        #expect(watch.published.value.map { Self.ids($0.catalog) } == [
            [first.id, second.id],
            [first.id],
            [first.id, copy],
            [copy, first.id],
        ])
        guard case let .loaded(workouts) = store.state.workouts else {
            Issue.record("The list is not loaded")
            return
        }
        #expect(watch.published.value.last?.catalog == .loaded(WatchCatalog(workouts: Array(workouts))))
    }

    @Test
    func test_queuedWrites_publishOnceWithTheFinalList() async {
        let watch = WatchPublications()
        let clock = TestClock()
        let third = makeWorkout(3)
        let store = makeStore(loaded([first, second, third]), watch: watch) {
            $0.workoutStorage.delete = { _ in
                try await clock.sleep(for: .seconds(1))
                return .applied
            }
            $0.workoutStorage.reorder = { _ in
                try await clock.sleep(for: .seconds(1))
                return .applied
            }
        }
        store.exhaustivity = .off

        await store.send(.view(.deleteButtonTapped(first.id)))
        await store.send(.view(.workoutsMoved(IndexSet(integer: 1), 0)))
        await clock.advance(by: .seconds(1))
        await store.receive(\.internal.mutationFinished)
        #expect(watch.revisions.value == 0)
        await clock.advance(by: .seconds(1))
        await store.receive(\.internal.mutationFinished)
        await store.finish()

        #expect(watch.published.value == [
            WatchPublication(revision: 1, catalog: .loaded(WatchCatalog(workouts: [third, second]))),
        ])
    }

    /// A publication that finishes after a later one keeps its own action's revision, so the watch link can drop it.
    /// A test store starts effects in the order of their actions, so it cannot tell a revision taken in the reducer
    /// from one taken first thing in the effect.
    @Test
    func test_publications_finishOutOfOrder_keepTheRevisionsOfTheirActions() async throws {
        let watch = WatchPublications()
        let held = Gate()
        let calls = LockIsolated(0)
        var renamed = first
        renamed.name = "Renamed"
        var renamedAgain = first
        renamedAgain.name = "Renamed again"
        var state = loaded([first])
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: first)))
        let id = try #require(state.path.ids.first)
        let store = makeStore(state, watch: watch) {
            $0.watchCompanion.publishCatalog = { revision, catalog in
                let call = calls.withValue {
                    $0 += 1
                    return $0
                }
                if call == 1 {
                    await held.wait()
                }
                watch.published.withValue { $0.append(WatchPublication(revision: revision, catalog: catalog)) }
            }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: id, action: .editor(.delegate(.saved(renamed))))))
        await store.send(.path(.element(id: id, action: .editor(.delegate(.saved(renamedAgain))))))
        await Task.megaYield()
        held.open()
        await store.finish()

        #expect(watch.published.value == [
            WatchPublication(revision: 2, catalog: .loaded(WatchCatalog(workouts: [renamedAgain]))),
            WatchPublication(revision: 1, catalog: .loaded(WatchCatalog(workouts: [renamed]))),
        ])
    }

    @Test
    func test_firstLoadFails_publishesLoadFailed() async {
        let watch = WatchPublications()
        let store = makeStore(AppFeature.State(), watch: watch) {
            $0.workoutStorage.fetchAll = { throw Failure() }
        }
        store.exhaustivity = .off

        await store.send(.view(.task))
        await store.receive(\.internal.workoutsLoadingFailed)
        await store.finish()

        #expect(watch.published.value == [WatchPublication(revision: 1, catalog: .unavailable(.loadFailed))])
    }

    @Test
    func test_reloadFails_shownList_publishesLoadFailed() async {
        let watch = WatchPublications()
        var state = loaded([first, second])
        state.pendingMutations = [.reorder([second.id, first.id])]
        let store = makeStore(state, watch: watch) {
            $0.workoutStorage.fetchAll = { throw Failure() }
        }

        await store.send(.internal(.mutationFinished(.storeDiverged))) {
            $0.pendingMutations = []
            $0.isReloading = true
        }
        await store.receive(\.internal.workoutsLoadingFailed) {
            $0.isReloading = false
            $0.workouts = .failed
        }
        await store.finish()

        #expect(watch.published.value == [WatchPublication(revision: 1, catalog: .unavailable(.loadFailed))])
    }

    @Test(arguments: ["write", "reload", "readAgain", "settled"])
    func test_settledWorkouts_writeOrReadUnderWay_isNil(situation: String) {
        var state = loaded([first])
        switch situation {
            case "write": state.pendingMutations = [.delete(first.id)]
            case "reload": state.isReloading = true
            case "readAgain": state.needsReload = true
            default: break
        }

        #expect(state.settledWorkouts == (situation == "settled" ? state.workouts : nil))
    }

    @Test
    func test_tabsScreensAndTimer_publishNothing() async throws {
        let watch = WatchPublications()
        let store = makeStore(loaded([first]), watch: watch) {
            $0.appVersion.shortVersion = { "1.2" }
            $0.timerSession.end = { _ in }
        }
        store.exhaustivity = .off

        await store.send(.view(.tabSelected(.settings)))
        await store.send(.view(.tabSelected(.workouts)))
        await store.send(.view(.workoutTapped(first.id)))
        let id = try #require(store.state.path.ids.first)
        await store.send(.path(.element(id: id, action: .editor(.delegate(.startRequested(first))))))
        #expect(store.state.destination != nil)

        #expect(watch.revisions.value == 0)
        await store.skipInFlightEffects()
    }

    /// A read that a write overtook is read again; only the list read after the write reaches the watch.
    @Test
    func test_readOvertakenByAWrite_publishesOnlyTheListReadAfterIt() async {
        let watch = WatchPublications()
        let renamed = makeWorkout(2, name: "Reloaded")
        var state = loaded([first, second])
        state.isReloading = true
        state.needsReload = true
        let store = makeStore(state, watch: watch) {
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: [renamed]) }
        }

        await store.send(.internal(.workoutsLoaded(StoredWorkouts(workouts: [first])))) { $0.needsReload = false }
        await store.receive(\.internal.workoutsLoaded) {
            $0.isReloading = false
            $0.workouts = .loaded([renamed])
        }
        await store.finish()

        #expect(watch.revisions.value == 1)
        #expect(watch.published.value == [WatchPublication(revision: 1, catalog: .loaded(WatchCatalog(workouts: [renamed])))])
    }

    /// The watch link drops a list it already has by its digest, so the app publishes it again rather than compare.
    @Test
    func test_reload_sameList_publishesItAgainUnderANewRevision() async {
        let watch = WatchPublications()
        var state = loaded([first, second])
        state.pendingMutations = [.reorder([first.id, second.id])]
        let store = makeStore(state, watch: watch) {
            $0.workoutStorage.fetchAll = { StoredWorkouts(workouts: [self.first, self.second]) }
        }

        await store.send(.internal(.mutationFinished(.storeDiverged))) {
            $0.pendingMutations = []
            $0.isReloading = true
        }
        await store.receive(\.internal.workoutsLoaded) { $0.isReloading = false }
        await store.finish()

        #expect(watch.published.value == [
            WatchPublication(revision: 1, catalog: .loaded(WatchCatalog(workouts: [first, second]))),
        ])
    }

    private static func ids(_ catalog: CatalogState) -> [UUID]? {
        guard case let .loaded(catalog) = catalog else { return nil }
        return catalog.entries.map(\.id)
    }
}
