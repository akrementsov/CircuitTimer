import ActivityKit
import Foundation
import os

/// Why iOS refused to start an activity, sorted by what the coordinator does about it.
enum ActivityRequestFailure: Error, Equatable {
    /// The user turned Live Activities off for the app.
    case denied
    /// iOS starts an activity only while the app is in the foreground.
    case visibility
    /// Retrying cannot help: the activity is too large or the build cannot show one.
    case permanent(String)
    /// The next sync may succeed, for example once the user ends another activity.
    case transient(String)
    /// iOS is terminating the process; nothing is requested any more.
    case terminating
}

enum ActivityPresence: Equatable {
    case alive
    /// Ended, or dismissed by the user; it never comes back.
    case gone
}

enum ActivityDismissal: Equatable {
    case immediate
    /// iOS keeps the final content on the Lock Screen for a while.
    case standard
}

/// ActivityKit behind Sendable closures. `Activity` is not `Sendable`, so only its identifier
/// leaves a closure, and each call looks the activity up again: first among the activities this
/// transport requested, because iOS may list a new one a moment after `request` returns.
/// `endEvery` alone keeps the references it found, within the one closure that ends them.
struct ActivityTransport: Sendable {
    /// Activities requested and not ended at once yet. `Activity` is not `Sendable`; the lock only
    /// stores and hands out references, and ActivityKit synchronizes the activities themselves.
    private typealias Registry = OSAllocatedUnfairLock<[String: Activity<WorkoutActivityAttributes>]>

    var isEnabled: @Sendable () -> Bool
    var request: @Sendable (WorkoutActivityAttributes, WorkoutActivityAttributes.ContentState) throws(ActivityRequestFailure) -> String
    var update: @Sendable (String, WorkoutActivityAttributes.ContentState) async -> Void
    var end: @Sendable (String, WorkoutActivityAttributes.ContentState?, ActivityDismissal) async -> Void
    /// Ends every activity at once, waits for `between`, then ends the same activities again with any that appeared
    /// meanwhile, so an end that was still under way with the standard dismissal is overridden.
    var endEvery: @Sendable (_ between: @Sendable () async -> Void) async -> Void
    /// Drops an activity that went while it showed, removed by the user or ended by iOS; no later call reaches it.
    var forget: @Sendable (String) -> Void
    /// `nil` while iOS does not list the activity.
    var presence: @Sendable (String) -> ActivityPresence?
    var allIDs: @Sendable () -> [String]

    static func live(gate: TerminationGate) -> Self {
        let requested = Registry(uncheckedState: [:])
        return Self(
            isEnabled: { ActivityAuthorizationInfo().areActivitiesEnabled },
            request: { attributes, state throws(ActivityRequestFailure) in
                guard !gate.isClosed else { throw .terminating }

                do {
                    let activity = try Activity.request(attributes: attributes, content: content(state), pushType: nil)
                    requested.withLockUnchecked { $0[activity.id] = activity }
                    return activity.id
                } catch let error as ActivityAuthorizationError {
                    throw ActivityRequestFailure(error)
                } catch {
                    throw .transient(String(reflecting: error))
                }
            },
            update: { id, state in
                guard !gate.isClosed else { return }

                guard let activity = activity(id, in: requested) else {
                    Logger.liveActivity.debug("No live activity \(id, privacy: .public) to update")
                    return
                }

                await activity.update(content(state))
            },
            end: { id, state, dismissal in
                guard let activity = activity(id, in: requested) else {
                    Logger.liveActivity.debug("No live activity \(id, privacy: .public) to end")
                    return
                }

                await activity.end(state.map(content), dismissalPolicy: dismissal == .immediate ? .immediate : .default)
                // A standard end leaves the final content on the Lock Screen; a later immediate end still removes it.
                if dismissal == .immediate {
                    requested.withLockUnchecked { _ = $0.removeValue(forKey: id) }
                }
            },
            endEvery: { between in
                let first = every(in: requested)
                await endImmediately(first)
                await between()
                let second = every(in: requested)
                let secondIDs = Set(second.map(\.id))
                await endImmediately(second + first.filter { !secondIDs.contains($0.id) })
            },
            forget: { id in
                requested.withLockUnchecked { _ = $0.removeValue(forKey: id) }
            },
            presence: { id in
                listed(id).map { ActivityPresence($0.activityState) }
            },
            allIDs: {
                Activity<WorkoutActivityAttributes>.activities.map(\.id)
            }
        )
    }

    private static func activity(_ id: String, in requested: Registry) -> Activity<WorkoutActivityAttributes>? {
        requested.withLockUnchecked { $0[id] } ?? listed(id)
    }

    /// The requested activities and those iOS lists, each once.
    private static func every(in requested: Registry) -> [Activity<WorkoutActivityAttributes>] {
        let held = requested.withLockUnchecked { Array($0.values) }
        let heldIDs = Set(held.map(\.id))
        return held + Activity<WorkoutActivityAttributes>.activities.filter { !heldIDs.contains($0.id) }
    }

    /// One after another: `Activity` is not `Sendable`, so the ends cannot run in child tasks, and there is
    /// rarely more than one.
    private static func endImmediately(_ activities: [Activity<WorkoutActivityAttributes>]) async {
        for activity in activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func listed(_ id: String) -> Activity<WorkoutActivityAttributes>? {
        Activity<WorkoutActivityAttributes>.activities.first { $0.id == id }
    }

    private static func content(
        _ state: WorkoutActivityAttributes.ContentState
    ) -> ActivityContent<WorkoutActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: state.staleDate)
    }
}

extension ActivityRequestFailure {
    init(_ error: ActivityAuthorizationError) {
        switch error {
            case .denied:
                self = .denied
            case .visibility:
                self = .visibility
            case .attributesTooLarge, .unentitled, .unsupported, .unsupportedTarget:
                self = .permanent(String(reflecting: error))
            default:
                self = .transient(String(reflecting: error))
        }
    }
}

extension ActivityPresence {
    init(_ state: ActivityState) {
        switch state {
            case .ended, .dismissed:
                self = .gone
            default:
                // Active, stale, pending (iOS 26) and any state added later still show.
                self = .alive
        }
    }
}
