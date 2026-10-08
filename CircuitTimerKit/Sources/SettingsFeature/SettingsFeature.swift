import ComposableArchitecture

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
        public internal(set) var path = StackState<Path.State>()

        public init() {}

        /// Runs in the caller's reducer, outside this feature's `forEach`: pushed screens must own no effects.
        public mutating func popToRoot() {
            path.removeAll()
        }
    }

    public enum Action: ViewAction, Equatable, Sendable {
        case view(View)
        case path(StackActionOf<Path>)

        @CasePathable
        public enum View: Equatable, Sendable {
            case aboutTapped
            case legalDocumentTapped(LegalDocument)
        }
    }

    @Dependency(\.appVersion) private var appVersion

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
                case let .view(action):
                    reduce(into: &state, action)
                case .path:
                    .none
            }
        }
        .forEach(\.path, action: \.path)
    }

    private func reduce(into state: inout State, _ action: Action.View) -> Effect<Action> {
        switch action {
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
