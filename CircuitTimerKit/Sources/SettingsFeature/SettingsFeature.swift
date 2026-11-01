import CloudSync
import ComposableArchitecture
import Purchases
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
        /// Read when the app launches; a change shows a footnote until the next launch applies it.
        @Shared(.iCloudSync) public var isICloudSyncOn = true
        var cloudSyncStatus: CloudSyncStatus?
        /// iCloud sync is part of the full version; the rows under it buy or restore it. The app keeps it current from
        /// its one subscription.
        public var fullVersion: FullVersionStatus = .unknown
        public internal(set) var path = StackState<Path.State>()

        public init() {}

        /// Runs in the caller's reducer, outside this feature's `forEach`: pushed screens must own no effects.
        public mutating func popToRoot() {
            path.removeAll()
        }
    }

    /// What the user asked of the full version; the app shows the purchase sheet for it.
    public enum FullVersionRequest: Equatable, Sendable {
        case buy
        /// Restores at once.
        case restore
        /// The locked iCloud switch: the sheet says why.
        case iCloudSync
    }

    public enum Action: ViewAction, Equatable, Sendable {
        case view(View)
        case `internal`(Internal)
        case delegate(Delegate)
        case path(StackActionOf<Path>)

        @CasePathable
        public enum View: Equatable, Sendable {
            case task
            case backgroundNotificationsToggled(Bool)
            case keepScreenOnToggled(Bool)
            case soundToggled(Bool)
            case vibrationToggled(Bool)
            case speechToggled(Bool)
            case iCloudSyncToggled(Bool)
            case lockedICloudSyncTapped
            case buyTapped
            case restoreTapped
            case aboutTapped
            case legalDocumentTapped(LegalDocument)
        }

        @CasePathable
        public enum Internal: Equatable, Sendable {
            case cloudSyncStatusChanged(CloudSyncStatus)
        }

        @CasePathable
        public enum Delegate: Equatable, Sendable {
            case fullVersionRequested(FullVersionRequest)
        }
    }

    enum CancelID: Hashable, Sendable {
        case cloudSyncStatus
    }

    @Dependency(\.cloudSync) var cloudSync
    @Dependency(\.appVersion) private var appVersion

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
                case let .view(action):
                    return reduce(into: &state, action)
                case let .internal(.cloudSyncStatusChanged(status)):
                    state.cloudSyncStatus = status
                    return .none
                case .delegate, .path:
                    return .none
            }
        }
        .forEach(\.path, action: \.path)
    }

    private func reduce(into state: inout State, _ action: Action.View) -> Effect<Action> {
        switch action {
            case .task:
                return observeCloudSyncStatus()
            case let .backgroundNotificationsToggled(value):
                state.$isBackgroundNotificationsOn.withLock { $0 = value }
                return .none
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
            case let .iCloudSyncToggled(value):
                state.$isICloudSyncOn.withLock { $0 = value }
                return .none
            case .lockedICloudSyncTapped:
                // The switch keeps its stored value: bought later, sync is on as the user left it.
                return .send(.delegate(.fullVersionRequested(.iCloudSync)))
            case .buyTapped:
                return .send(.delegate(.fullVersionRequested(.buy)))
            case .restoreTapped:
                return .send(.delegate(.fullVersionRequested(.restore)))
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
