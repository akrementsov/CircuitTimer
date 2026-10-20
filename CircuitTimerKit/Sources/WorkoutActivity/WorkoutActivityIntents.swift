import AppIntents
import Dependencies
import Foundation

public struct WorkoutActivityIntents: AppIntentsPackage {}

public struct PauseWorkoutIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource {
        LocalizedStringResource("activity.intent.pause.title", defaultValue: "Pause workout", bundle: Bundle.module)
    }
    public static var description: IntentDescription {
        IntentDescription(
            LocalizedStringResource(
                "activity.intent.description",
                defaultValue: "Control the current workout from its Live Activity.",
                bundle: Bundle.module
            )
        )
    }
    public static var isDiscoverable: Bool { false }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    @available(iOS 26, *)
    public static var supportedModes: IntentModes { .background }
    @available(iOS 27, *)
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: LocalizedStringResource("activity.intent.parameter.activity", defaultValue: "Activity", bundle: Bundle.module))
    public var activityID: String
    @Parameter(
        title: LocalizedStringResource("activity.intent.parameter.generation", defaultValue: "Control generation", bundle: Bundle.module)
    )
    public var generation: Int

    public init() {}

    public init(activityID: String, generation: Int) {
        self.activityID = activityID
        self.generation = generation
    }

    public func perform() async throws -> some IntentResult {
        @Dependencies.Dependency(\.liveActivity) var liveActivity
        try await controlResult(liveActivity.deliver(activityID, .pause, generation))
        return .result()
    }
}

public struct ResumeWorkoutIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource {
        LocalizedStringResource("activity.intent.resume.title", defaultValue: "Resume workout", bundle: Bundle.module)
    }
    public static var description: IntentDescription {
        IntentDescription(
            LocalizedStringResource(
                "activity.intent.description",
                defaultValue: "Control the current workout from its Live Activity.",
                bundle: Bundle.module
            )
        )
    }
    public static var isDiscoverable: Bool { false }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    @available(iOS 26, *)
    public static var supportedModes: IntentModes { .background }
    @available(iOS 27, *)
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: LocalizedStringResource("activity.intent.parameter.activity", defaultValue: "Activity", bundle: Bundle.module))
    public var activityID: String
    @Parameter(
        title: LocalizedStringResource("activity.intent.parameter.generation", defaultValue: "Control generation", bundle: Bundle.module)
    )
    public var generation: Int

    public init() {}

    public init(activityID: String, generation: Int) {
        self.activityID = activityID
        self.generation = generation
    }

    public func perform() async throws -> some IntentResult {
        @Dependencies.Dependency(\.liveActivity) var liveActivity
        try await controlResult(liveActivity.deliver(activityID, .resume, generation))
        return .result()
    }
}

private func controlResult(_ result: LiveActivityControlResult) throws {
    switch result {
        case .applied, .orphanEnded:
            return
        case .stale:
            throw ControlError.stale
        case .busy:
            throw ControlError.busy
        case .timedOut:
            throw ControlError.timedOut
        case .cancelled:
            throw CancellationError()
        case .unavailable, .failed:
            throw ControlError.unavailable
    }
}

private enum ControlError: LocalizedError {
    case stale
    case busy
    case timedOut
    case unavailable

    var errorDescription: String? {
        switch self {
            case .stale:
                String(localized: "activity.intent.error.stale", bundle: .module)
            case .busy:
                String(localized: "activity.intent.error.busy", bundle: .module)
            case .timedOut:
                String(localized: "activity.intent.error.timedOut", bundle: .module)
            case .unavailable:
                String(localized: "activity.intent.error.unavailable", bundle: .module)
        }
    }
}
