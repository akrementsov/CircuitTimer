import ComposableArchitecture
import Foundation
import os
import SwiftUI
import WatchLink

/// The watch app: the iPhone's workout list and the state of the link to it. The iPhone runs every workout; the watch
/// only shows what the iPhone published.
@Reducer
public struct WatchRemoteFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        /// `nil` until the session reports itself.
        var link: LinkStatus?
        var catalog: ShownCatalog?
        var order = PhoneOrder()
        var refresh = RefreshLoop()
        var problem: LinkProblem?
        var isSceneActive = false

        public init() {}
    }

    /// The list the watch shows. A list the iPhone could not load keeps the last loaded one, dimmed.
    struct ShownCatalog: Equatable, Sendable {
        var lastLoaded: WatchCatalog?
        var unavailable: UnavailableReason?
        /// When the iPhone last published or confirmed this list.
        var updatedAt: Date
    }

    struct RefreshLoop: Equatable, Sendable {
        /// The one request in flight; only an answer, failure or timeout carrying this ID ends it.
        var inFlight: UUID?
        /// A reason to ask came while a request was in flight: ask again when it ends.
        var needsRefresh = false
        var failures = 0
        /// Ties a scheduled retry to the failure that scheduled it.
        var retryGeneration = 0
        /// The iPhone has answered at least once; until then a watch without a list shows that it is connecting.
        var hasAnswered = false
    }

    enum LinkProblem: Equatable, Sendable {
        case unreachable
        case failed
        case companionMissing
        case incompatible(UpdateSide)
    }

    /// Which app the user should update.
    enum UpdateSide: Equatable, Sendable {
        case phone
        case watch
    }

    public enum Action: ViewAction, Equatable, Sendable {
        case view(View)
        case `internal`(Internal)

        @CasePathable public enum View: Equatable, Sendable {
            case task
            case scenePhaseChanged(ScenePhase)
        }

        @CasePathable public enum Internal: Equatable, Sendable {
            case event(PhoneLinkEvent)
            case statusRead(LinkStatus)
            case refreshAnswered(sentID: UUID, WatchReplyEnvelope)
            case refreshFailed(sentID: UUID, PhoneLinkError)
            case refreshTimedOut(sentID: UUID)
            case retryDue(Int)
        }
    }

    enum CancelID {
        case events
        case refresh
        case refreshTimeout
        case retry
    }

    static let retryDelays: [Duration] = [.seconds(5), .seconds(10), .seconds(20)]
    static let refreshTimeout: Duration = .seconds(10)
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "WatchRemote")

    @Dependency(\.continuousClock) var clock
    @Dependency(\.phoneCompanion) var phoneCompanion
    @Dependency(\.uuid) var uuid

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
                case let .view(action):
                    reduce(into: &state, action)
                case let .internal(action):
                    reduce(into: &state, action)
            }
        }
    }

    private func reduce(into state: inout State, _ action: Action.View) -> Effect<Action> {
        switch action {
            case .task:
                // A repeated `.task` replaces the reader: the client gives each subscription its own stream.
                return .run { [phoneCompanion] send in
                    for await event in await phoneCompanion.events() {
                        await send(.internal(.event(event)))
                    }
                }
                .cancellable(id: CancelID.events, cancelInFlight: true)
            case let .scenePhaseChanged(phase):
                state.isSceneActive = phase == .active
                guard state.isSceneActive else { return .cancel(id: CancelID.retry) }
                state.refresh.failures = 0
                if state.problem == .companionMissing {
                    state.problem = nil
                }
                // The status has no callback for every change, such as an unlock: read it again on each return.
                return .run { [phoneCompanion] send in
                    await send(.internal(.statusRead(phoneCompanion.status())))
                }
        }
    }

    private func reduce(into state: inout State, _ action: Action.Internal) -> Effect<Action> {
        switch action {
            case let .event(.status(status)):
                return updateLink(status, &state) ? requestRefresh(&state) : .none
            case let .statusRead(status):
                // Read because the scene became active, which is a reason to ask by itself.
                _ = updateLink(status, &state)
                return requestRefresh(&state)
            case let .event(.context(phoneState)):
                return receive(phoneState, from: .context, &state)
            case let .event(.message(phoneState)):
                return receive(phoneState, from: .message, &state)
            case let .event(.undecodable(peerSchemaVersion)):
                state.problem = .incompatible(Self.side(toUpdate: peerSchemaVersion))
                return .none
            case let .refreshAnswered(sentID, envelope):
                return refreshAnswered(sentID: sentID, envelope, &state)
            case let .refreshFailed(sentID, error):
                return refreshFailed(sentID: sentID, error, &state)
            case let .refreshTimedOut(sentID):
                guard finish(sentID, &state) else { return .none }
                state.problem = .failed
                return .merge(.cancel(id: CancelID.refresh), scheduleRetry(&state))
            case let .retryDue(generation):
                guard generation == state.refresh.retryGeneration else { return .none }
                return requestRefresh(&state)
        }
    }

    /// Returns whether the iPhone became reachable, which is a reason to ask.
    private func updateLink(_ status: LinkStatus, _ state: inout State) -> Bool {
        let becameReachable = state.link?.canSend != true && status.canSend
        state.link = status
        if becameReachable {
            state.refresh.failures = 0
        }
        return becameReachable
    }

    func receive(_ phoneState: PhoneState, from source: StateSource, _ state: inout State) -> Effect<Action> {
        let outcome = state.order.receive(phoneState, from: source)
        if let change = outcome.change {
            if case .incompatible = state.problem {
                state.problem = nil
            }
            apply(change, publishedAt: phoneState.publishedAt, &state)
        }
        return outcome.asksAgain ? requestRefresh(&state) : .none
    }

    private func apply(_ change: PhoneOrder.CatalogChange, publishedAt: Date, _ state: inout State) {
        switch change {
            case let .replaced(.loaded(catalog)):
                state.catalog = ShownCatalog(lastLoaded: catalog, unavailable: nil, updatedAt: publishedAt)
            case let .replaced(.unavailable(reason)):
                state.catalog = ShownCatalog(lastLoaded: state.catalog?.lastLoaded, unavailable: reason, updatedAt: publishedAt)
            case .confirmed:
                state.catalog?.updatedAt = publishedAt
            case .unknown:
                break
        }
    }

    /// A peer of a newer version means this watch app is the old one.
    static func side(toUpdate peerSchemaVersion: Int?) -> UpdateSide {
        guard let peerSchemaVersion else { return .phone }
        return peerSchemaVersion > WatchLinkSchema.version ? .watch : .phone
    }
}
