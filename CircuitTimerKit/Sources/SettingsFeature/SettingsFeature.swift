import BackgroundNotifications
import ComposableArchitecture
import Foundation
import os
import SwiftUI
import TimerPreferences

/// The Settings tab: its own navigation stack with About and the legal pages.
@Reducer
public struct SettingsFeature: Sendable {
    /// Pushed screens without logic of their own carry their data and need no reducer.
    @Reducer
    public enum Path {
        @ReducerCaseIgnored
        case about(version: String?)
        @ReducerCaseIgnored
        case legalDocument(LegalDocument)
    }

    @ObservableState
    public struct State: Equatable, Sendable {
        @Shared(.keepScreenOn) public var isKeepScreenOn = true
        @Shared(.soundSignals) public var isSoundOn = true
        @Shared(.vibrationSignals) public var isVibrationOn = true
        @Shared(.spokenStageNames) public var isSpeechOn = true
        @Shared(.backgroundNotifications) public var isBackgroundNotificationsOn = true
        var notificationAccess: NotificationAccess?
        var notificationAccessGeneration = 0
        var openSettingsFailed = false
        public internal(set) var path = StackState<Path.State>()

        public init() {}

        /// Runs in the caller's reducer, outside this feature's `forEach`: pushed screens must own no effects.
        public mutating func popToRoot() {
            path.removeAll()
        }
    }

    public enum Action: ViewAction, Equatable, Sendable {
        case view(View)
        case `internal`(Internal)
        case path(StackActionOf<Path>)

        @CasePathable
        public enum View: Equatable, Sendable {
            case task
            case appeared
            case scenePhaseChanged(ScenePhase)
            case backgroundNotificationsToggled(Bool)
            case openNotificationSettingsTapped
            case keepScreenOnToggled(Bool)
            case soundToggled(Bool)
            case vibrationToggled(Bool)
            case speechToggled(Bool)
            case aboutTapped
            case legalDocumentTapped(LegalDocument)
        }

        @CasePathable
        public enum Internal: Equatable, Sendable {
            case notificationAccessLoaded(generation: Int, NotificationAccess?)
            case notificationSettingsOpened(Bool)
        }
    }

    enum CancelID: Hashable, Sendable {
        case notificationAccess
        case openSettings
    }

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "Settings")

    @Dependency(\.backgroundNotifications) var backgroundNotifications
    @Dependency(\.appVersion) private var appVersion

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
                case let .view(action):
                    return reduce(into: &state, action)
                case let .internal(.notificationAccessLoaded(generation, access)):
                    guard generation == state.notificationAccessGeneration, state.isBackgroundNotificationsOn else { return .none }
                    state.notificationAccess = access
                    return .none
                case let .internal(.notificationSettingsOpened(succeeded)):
                    state.openSettingsFailed = !succeeded
                    return .none
                case .path:
                    return .none
            }
        }
        .forEach(\.path, action: \.path)
    }

    private func reduce(into state: inout State, _ action: Action.View) -> Effect<Action> {
        switch action {
            case .task, .appeared, .scenePhaseChanged(.active):
                return readNotificationAccess(&state)
            case .scenePhaseChanged:
                return .none
            case let .backgroundNotificationsToggled(value):
                state.$isBackgroundNotificationsOn.withLock { $0 = value }
                state.notificationAccess = nil
                if value { return readNotificationAccess(&state) }

                state.notificationAccessGeneration += 1
                return .cancel(id: CancelID.notificationAccess)
            case .openNotificationSettingsTapped:
                return .run { [backgroundNotifications] send in
                    let succeeded = await backgroundNotifications.openSystemSettings()
                    if !succeeded { Self.logger.error("Opening notification settings failed") }
                    await send(.internal(.notificationSettingsOpened(succeeded)))
                }
                .cancellable(id: CancelID.openSettings, cancelInFlight: true)
            case let .keepScreenOnToggled(value):
                state.$isKeepScreenOn.withLock { $0 = value }
                return .none
            case let .soundToggled(value):
                state.$isSoundOn.withLock { $0 = value }
                return .none
            case let .vibrationToggled(value):
                state.$isVibrationOn.withLock { $0 = value }
                return .none
            case let .speechToggled(value):
                state.$isSpeechOn.withLock { $0 = value }
                return .none
            case .aboutTapped:
                state.path.append(.about(version: appVersion.shortVersion()))
                return .none
            case let .legalDocumentTapped(document):
                state.path.append(.legalDocument(document))
                return .none
        }
    }
}

extension SettingsFeature.Path.State: Equatable, Sendable {}
extension SettingsFeature.Path.Action: Equatable, Sendable {}
