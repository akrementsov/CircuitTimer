import ComposableArchitecture
import Purchases
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
        switch workouts {
            case let .loaded(workouts):
                let workouts = Array(workouts)
                let revision = watchCompanion.nextRevision()
                return .run { [watchCompanion] _ in
                    await watchCompanion.publishCatalog(revision, .loaded(WatchCatalog(workouts: workouts)))
                }
            case .failed:
                let revision = watchCompanion.nextRevision()
                return .run { [watchCompanion] _ in
                    await watchCompanion.publishCatalog(revision, .unavailable(.loadFailed))
                }
            case .idle, .loading, nil:
                return .none
        }
    }

    /// Lets the watch app in or locks it; the link keeps the list and the run meanwhile and publishes them with access.
    /// Nothing while StoreKit has not answered: the watch keeps what it shows.
    func publishWatchAccess(_ status: FullVersionStatus) -> Effect<Action> {
        let access: WatchAccess
        switch status {
            case .full:
                access = .granted
            case .free:
                access = .locked
            case .unknown:
                return .none
        }
        let revision = watchCompanion.nextRevision()
        return .run { [watchCompanion] _ in
            await watchCompanion.publishAccess(revision, access)
        }
    }
}
