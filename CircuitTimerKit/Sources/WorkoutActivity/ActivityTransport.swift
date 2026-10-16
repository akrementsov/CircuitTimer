import ActivityKit
import Foundation

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
/// leaves a closure, and each call looks the activity up again.
struct ActivityTransport: Sendable {
    var isEnabled: @Sendable () -> Bool
    var request: @Sendable (WorkoutActivityAttributes, WorkoutActivityAttributes.ContentState) throws(ActivityRequestFailure) -> String
    var update: @Sendable (String, WorkoutActivityAttributes.ContentState) async -> Void
    var end: @Sendable (String, WorkoutActivityAttributes.ContentState?, ActivityDismissal) async -> Void
    /// `nil` while iOS does not list the activity.
    var presence: @Sendable (String) -> ActivityPresence?
    var allIDs: @Sendable () -> [String]

    static let live = Self(
        isEnabled: { ActivityAuthorizationInfo().areActivitiesEnabled },
        request: { attributes, state throws(ActivityRequestFailure) in
            do {
                return try Activity.request(attributes: attributes, content: content(state), pushType: nil).id
            } catch let error as ActivityAuthorizationError {
                throw ActivityRequestFailure(error)
            } catch {
                throw .transient(String(reflecting: error))
            }
        },
        update: { id, state in
            guard let activity = activity(id) else { return }

            await activity.update(content(state))
        },
        end: { id, state, dismissal in
            guard let activity = activity(id) else { return }

            await activity.end(state.map(content), dismissalPolicy: dismissal == .immediate ? .immediate : .default)
        },
        presence: { id in
            activity(id).map { ActivityPresence($0.activityState) }
        },
        allIDs: {
            Activity<WorkoutActivityAttributes>.activities.map(\.id)
        }
    )

    private static func activity(_ id: String) -> Activity<WorkoutActivityAttributes>? {
        Activity<WorkoutActivityAttributes>.activities.first { $0.id == id }
    }

    private static func content(
        _ state: WorkoutActivityAttributes.ContentState
    ) -> ActivityContent<WorkoutActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: state.staleDate)
    }
}

private extension ActivityRequestFailure {
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

private extension ActivityPresence {
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
