import ComposableArchitecture
import Foundation
import os
import SwiftUI
import WatchLink
import WorkoutDomain

/// The watch app: the iPhone's workout list, its running workout and the state of the link to it. The iPhone runs
/// every workout; the watch only shows what the iPhone published.
@Reducer
public struct WatchRemoteFeature: Sendable {
    @Reducer
    public enum Path {
        @ReducerCaseIgnored
        case selected(id: UUID, fingerprint: String)
    }

    @ObservableState
    public struct State: Equatable, Sendable {
        /// `nil` until the session reports itself.
        var link: LinkStatus?
        var catalog: ShownCatalog?
        var order = PhoneOrder()
        var refresh = RefreshLoop()
        var problem: LinkProblem?
        /// The watch app is in front: active, or inactive with the wrist lowered, which is not leaving.
        var isSceneActive = false
        var run: ShownRun?
        /// A workout runs on the iPhone that does not fit in a transfer.
        var isRunTooLarge = false
        var lease: Lease?
        /// Always On with the wrist lowered: no digits and no renewal.
        var isLuminanceReduced = false
        /// Ties a scheduled stage end to the content that scheduled it.
        var runGeneration = 0
        /// The Pause or Resume waiting for its reply.
        var command: CommandRequest?
        /// What became of the last command, while the run it is about shows.
        var commandNote: ShownCommandNote?

        public internal(set) var path = StackState<Path.State>()
        /// Sending and waiting belong to the root, so Back cannot cancel a delivered Start.
        var start: StartRequest?
        var startNote: StartNote?

        public init() {}
    }

    /// The list the watch shows. A list the iPhone could not load keeps the last loaded one, dimmed; a locked watch app
    /// keeps none.
    struct ShownCatalog: Equatable, Sendable {
        var lastLoaded: WatchCatalog?
        var unavailable: UnavailableReason?
        /// When the iPhone last published or confirmed this list.
        var updatedAt: Date
    }

    struct RefreshLoop: Equatable, Sendable {
        /// The one request in flight; only an answer, failure or timeout carrying its ID ends it.
        var inFlight: RefreshRequest?
        /// Numbers the requests; a lease and a renewal name the request they belong to.
        var lastSerial = 0
        /// A reason about the list came while a request was in flight: ask again when it ends.
        var needsRefresh = false
        /// The run's renewal came due while its request was in flight: a confirming reply asks again at once.
        var isRenewalDue = false
        /// A retry is scheduled; until it runs, no new reason asks.
        var isRetryScheduled = false
        /// Ties a scheduled run retry to the reply that scheduled it.
        var runRetryGeneration = 0
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
        case path(StackActionOf<Path>)

        @CasePathable public enum View: Equatable, Sendable {
            case task
            case scenePhaseChanged(ScenePhase)
            case luminanceChanged(isReduced: Bool)
            /// The system clock was set; the reducer moves a lease's wall-clock end as every action does.
            case systemClockChanged
            case controlButtonTapped
            case workoutTapped(UUID)
            case startButtonTapped
        }

        @CasePathable public enum Internal: Equatable, Sendable {
            case event(PhoneLinkEvent)
            case statusRead(LinkStatus)
            case refreshAnswered(sentID: UUID, WatchReplyEnvelope)
            case refreshFailed(sentID: UUID, PhoneLinkError)
            case refreshTimedOut(sentID: UUID)
            case retryDue(Int)
            case renewalDue(serial: Int)
            case leaseExpired(serial: Int)
            case runRetryDue(generation: Int)
            case stageEnded(generation: Int)
            case commandAnswered(sentID: UUID, WatchReplyEnvelope)
            case commandFailed(sentID: UUID, PhoneLinkError)
            case commandTimedOut(sentID: UUID)
            case startAnswered(sentID: UUID, WatchReplyEnvelope)
            case startFailed(sentID: UUID, PhoneLinkError)
            case startTimedOut(sentID: UUID, generation: Int)
            case startPollDue(sentID: UUID, generation: Int)
        }
    }

    enum CancelID {
        case events
        case refresh
        case refreshTimeout
        case retry
        case renewal
        case lease
        case runRetry
        case stageEnd
        case command
        case commandTimeout
        case start
        case startTimeout
        case startPoll
    }

    static let retryDelays: [Duration] = [.seconds(5), .seconds(10), .seconds(20)]
    static let refreshTimeout: Duration = .seconds(10)
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "WatchRemote")

    @Dependency(\.continuousClock) var clock
    @Dependency(\.date) var date
    @Dependency(\.phoneCompanion) var phoneCompanion
    @Dependency(\.uuid) var uuid

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            // A lease that ran out goes before anything else, so no action shows its digits.
            dropExpiredLease(&state)
            let expired = dropExpiredStart(&state)
            let effect: Effect<Action> = switch action {
                case let .view(action):
                    reduce(into: &state, action)
                case let .internal(action):
                    reduce(into: &state, action)
                case .path:
                    .none
            }
            return .merge(expired, effect, reconcileSelectionAndStart(&state))
        }
        .forEach(\.path, action: \.path)
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
            case .scenePhaseChanged(.background):
                guard state.isSceneActive else { return .none }
                state.isSceneActive = false
                // A request still in flight when the app leaves is dropped: the return asks again. The run's digits
                // need a new confirmation then too.
                state.refresh.inFlight = nil
                state.refresh.needsRefresh = false
                state.refresh.isRenewalDue = false
                state.refresh.isRetryScheduled = false
                state.lease = nil
                // A command's outcome is not shown after a return: the next confirmation shows the run as it is.
                state.command = nil
                state.commandNote = nil
                return .merge(
                    stopStart(note: nil, &state),
                    .cancel(id: CancelID.command),
                    .cancel(id: CancelID.commandTimeout),
                    .cancel(id: CancelID.retry),
                    .cancel(id: CancelID.refresh),
                    .cancel(id: CancelID.refreshTimeout),
                    .cancel(id: CancelID.renewal),
                    .cancel(id: CancelID.lease),
                    .cancel(id: CancelID.runRetry),
                    .cancel(id: CancelID.stageEnd)
                )
            case .scenePhaseChanged(.inactive):
                // A lowered wrist keeps the app in front: its request and retries go on, and raising it is no return.
                return .none
            case .scenePhaseChanged(.active):
                // The status has no callback for every change, such as an unlock: read it again whenever the app is
                // active.
                guard !state.isSceneActive else {
                    // A raised wrist asks only if the status brings the iPhone back, as any status would: a request
                    // per raise could launch the iPhone app in the background each time.
                    return .run { [phoneCompanion] send in
                        await send(.internal(.event(.status(phoneCompanion.status()))))
                    }
                }
                state.isSceneActive = true
                state.refresh.failures = 0
                if state.problem == .companionMissing {
                    state.problem = nil
                }
                return .merge(
                    // The stage end was cancelled with the leaving; the shown run's clock needs it again.
                    state.run == nil ? .none : scheduleStageEnd(&state),
                    .run { [phoneCompanion] send in
                        await send(.internal(.statusRead(phoneCompanion.status())))
                    }
                )
            case .scenePhaseChanged:
                return .none
            case let .luminanceChanged(isReduced):
                return luminanceChanged(isReduced, &state)
            case .systemClockChanged:
                return systemClockChanged(&state)
            case .controlButtonTapped:
                return controlButtonTapped(&state)
            case let .workoutTapped(id):
                return workoutTapped(id, &state)
            case .startButtonTapped:
                return startButtonTapped(&state)
        }
    }

    private func reduce(into state: inout State, _ action: Action.Internal) -> Effect<Action> {
        switch action {
            case let .event(.status(status)):
                return updateLink(status, &state) ? requestRefresh(&state) : .none
            case let .statusRead(status):
                // Read because the scene became active, which is a reason to ask by itself; a request already in
                // flight, such as one the first status started, answers it too.
                _ = updateLink(status, &state)
                return state.refresh.inFlight == nil ? requestRefresh(&state) : .none
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
                guard finish(sentID, &state) != nil else { return .none }
                state.problem = .failed
                return .merge(.cancel(id: CancelID.refresh), dropRunRenewal(&state), scheduleRetry(&state))
            case let .retryDue(generation):
                guard generation == state.refresh.retryGeneration else { return .none }
                state.refresh.isRetryScheduled = false
                return requestRefresh(&state)
            case .renewalDue, .leaseExpired, .runRetryDue, .stageEnded:
                return reduceRun(into: &state, action)
            case let .commandAnswered(sentID, envelope):
                return commandAnswered(sentID: sentID, envelope, &state)
            case let .commandFailed(sentID, error):
                return commandFailed(sentID: sentID, error, &state)
            case let .commandTimedOut(sentID):
                return commandTimedOut(sentID: sentID, &state)
            case let .startAnswered(sentID, envelope):
                return startAnswered(sentID: sentID, envelope, &state)
            case let .startFailed(sentID, error):
                return startFailed(sentID: sentID, error, &state)
            case let .startTimedOut(sentID, generation):
                guard state.start?.id == sentID, state.start?.timeoutGeneration == generation else { return .none }
                return stopStart(note: .checkPhone, &state)
            case let .startPollDue(sentID, generation):
                return startPollDue(sentID: sentID, generation: generation, &state)
        }
    }

    /// Returns whether the iPhone became reachable, which is a reason to ask.
    private func updateLink(_ status: LinkStatus, _ state: inout State) -> Bool {
        let becameReachable = state.link?.canSend != true && status.canSend
        state.link = status
        if !status.canSend {
            // Out of reach, nothing vouches for the run's time.
            state.lease = nil
        }
        if becameReachable {
            state.refresh.failures = 0
        }
        return becameReachable
    }

    /// A context or a message. An accepted state with a run that no live lease covers, or whose stage is over, is a
    /// reason to ask about the run.
    func receive(_ phoneState: PhoneState, from source: StateSource, _ state: inout State) -> Effect<Action> {
        let outcome = state.order.receive(phoneState, from: source)
        let applied = applyAccepted(outcome, phoneState, &state)
        let listReason = outcome.asksAgain ? requestRefresh(&state) : .none
        let isUnconfirmed = state.lease == nil || state.run?.isStageOver == true
        let runReason = outcome.change != nil && isUnconfirmed ? askForRun(&state) : .none
        return .merge(applied, listReason, runReason)
    }

    func applyAccepted(_ outcome: PhoneOrder.Outcome, _ phoneState: PhoneState, _ state: inout State) -> Effect<Action> {
        guard let change = outcome.change else { return .none }
        // A state accepted from the iPhone proves its app is there, the link works and both apps read each other.
        state.problem = nil
        apply(change, publishedAt: phoneState.publishedAt, &state)
        return applyRun(phoneState, &state)
    }

    private func apply(_ change: PhoneOrder.CatalogChange, publishedAt: Date, _ state: inout State) {
        switch change {
            case let .replaced(.loaded(catalog)):
                state.catalog = ShownCatalog(lastLoaded: catalog, unavailable: nil, updatedAt: publishedAt)
            case .replaced(.unavailable(.locked)):
                state.catalog = ShownCatalog(lastLoaded: nil, unavailable: .locked, updatedAt: publishedAt)
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

extension WatchRemoteFeature.Path.State: Equatable, Sendable {}
extension WatchRemoteFeature.Path.Action: Equatable, Sendable {}
