import ComposableArchitecture
import WatchLink
import WorkoutDomain

extension AppFeature.State {
    /// The list once no write or reload is under way; until then the watch keeps the list it has.
    var settledWorkouts: AppFeature.Content? {
        guard pendingMutations.isEmpty, !isReloading, !needsReload else { return nil }
        return workouts
    }
}

extension AppFeature {
    /// Publishes the settled list to the watch. A failed load leaves the watch's list dimmed; a list still loading or
    /// not settled publishes nothing.
    func publishWatchCatalog(_ workouts: Content?) -> Effect<Action> {
        let revision: Int
        switch workouts {
            case let .loaded(workouts):
                let workouts = Array(workouts)
                revision = watchCompanion.nextRevision()
                return .run { [watchCompanion] _ in
                    await watchCompanion.publishCatalog(revision, .loaded(WatchCatalog(workouts: workouts)))
                }
            case .failed:
                revision = watchCompanion.nextRevision()
                return .run { [watchCompanion] _ in
                    await watchCompanion.publishCatalog(revision, .unavailable(.loadFailed))
                }
            case .idle, .loading, nil:
                return .none
        }
    }
}
