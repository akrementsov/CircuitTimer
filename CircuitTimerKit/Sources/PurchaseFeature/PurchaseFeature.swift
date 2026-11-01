import ComposableArchitecture
import Foundation
import os
import Purchases

/// The purchase sheet: the full version's price, buying and restoring it. It does not know who showed it and asks to
/// close through `delegate(.closeRequested)`.
@Reducer
public struct PurchaseFeature: Sendable {
    // An alert with actions needs a hand-written `Action`: with a macro-generated one the scoped binding would drop the
    // user's choice. See AGENTS.md › TCA.
    @Reducer
    public enum Destination {
        @ReducerCaseIgnored
        case alert(AlertState<Never>)
        /// The App Store said yes but the full version did not unlock; restoring reads it again.
        @ReducerCaseIgnored
        case restoreOffer(AlertState<RestoreOfferChoice>)

        @CasePathable
        public enum Action: Equatable, Sendable {
            case alert(Never)
            case restoreOffer(RestoreOfferChoice)
        }
    }

    public enum RestoreOfferChoice: Equatable, Sendable {
        case restore
    }

    /// Why a purchase failed, as far as the alert tells the user apart.
    public enum PurchaseFailure: Equatable, Sendable {
        /// Screen Time or a profile does not allow purchases on this device.
        case notAllowed
        /// StoreKit could not verify the transaction; the payment may have gone through.
        case unverified
        case other
    }

    /// Why the sheet opened when a locked feature opened it; the sheet says so above the feature list.
    public enum Reason: Equatable, Sendable {
        case workoutLimit
        case iCloudSync
    }

    public enum Entry: Equatable, Sendable {
        case browse
        /// Restores at once, as the Settings row asks.
        case restore
        case limit(Reason)
    }

    enum Offer: Equatable, Sendable {
        case loading
        case loaded(FullVersionOffer)
        case unavailable
    }

    enum Operation: Equatable, Sendable {
        case purchasing
        case restoring
    }

    /// How long a successful operation waits for the full version to be published before the sheet says so.
    static let confirmationTimeout: Duration = .seconds(3)

    @ObservableState
    public struct State: Equatable, Sendable {
        public let entry: Entry
        var offer: Offer = .loading
        var operation: Operation?
        var status: FullVersionStatus = .unknown
        /// Ask to Buy: the purchase waits for approval, which arrives as a status change.
        var isPending = false
        /// A purchase, a restore or an approved Ask to Buy of this sheet unlocked the full version.
        var didUnlockHere = false
        /// An operation of this sheet said yes before the status did; a later `.full` is this sheet's success.
        var expectsUnlock = false
        /// Keeps the buttons busy while `expectsUnlock`, for at most `confirmationTimeout`.
        var isAwaitingConfirmation = false
        var hasStarted = false
        @Presents var destination: Destination.State?

        public init(entry: Entry) {
            self.entry = entry
        }

        var reason: Reason? {
            if case let .limit(reason) = entry { reason } else { nil }
        }

        var isShowingSuccess: Bool {
            didUnlockHere && status == .full
        }

        var isBusy: Bool {
            operation != nil || isAwaitingConfirmation
        }

        var isPurchasing: Bool {
            operation == .purchasing || isAwaitingConfirmation
        }

        var isRestoring: Bool {
            operation == .restoring
        }

        /// The one-time and Family Sharing line belongs to an offer the user can buy.
        var showsFinePrint: Bool {
            guard !isShowingSuccess, !isPending, case .loaded = offer else { return false }

            return true
        }

        /// The full version came from elsewhere, such as Family Sharing or an earlier purchase StoreKit answered late,
        /// and no operation of this sheet waits for it: the sheet has nothing left to sell.
        var isUnlockedElsewhere: Bool {
            status == .full && !didUnlockHere && !expectsUnlock && !isPending && operation == nil
        }
    }

    public enum Action: ViewAction, Equatable, Sendable {
        case view(View)
        case `internal`(Internal)
        case delegate(Delegate)
        case destination(PresentationAction<Destination.Action>)

        @CasePathable
        public enum View: Equatable, Sendable {
            case task
            case buyTapped
            case restoreTapped
            case retryTapped
            case closeTapped
            case doneTapped
        }

        @CasePathable
        public enum Internal: Equatable, Sendable {
            case offerLoaded(FullVersionOffer)
            case offerFailed
            case purchaseFinished(PurchaseOutcome)
            case purchaseFailed(PurchaseFailure)
            case restoreFinished(RestoreOutcome)
            case restoreFailed
            case statusChanged(FullVersionStatus)
            case confirmationTimedOut
        }

        @CasePathable
        public enum Delegate: Equatable, Sendable {
            case closeRequested
        }
    }

    enum CancelID: Hashable, Sendable {
        case offer
        case status
        case operation
        case confirmation
    }

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "PurchaseFeature")

    @Dependency(\.purchases) var purchases
    @Dependency(\.continuousClock) var clock

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
                case let .view(action):
                    reduce(into: &state, action)
                case let .internal(action):
                    reduce(into: &state, action)
                case .destination(.presented(.restoreOffer(.restore))):
                    reduce(into: &state, Action.View.restoreTapped)
                case .delegate, .destination:
                    .none
            }
        }
        .ifLet(\.$destination, action: \.destination)
    }

    private func reduce(into state: inout State, _ action: Action.View) -> Effect<Action> {
        switch action {
            case .task:
                guard !state.hasStarted else { return .none }

                state.hasStarted = true
                var effects: [Effect<Action>] = [loadOffer(), observeStatus()]
                if state.entry == .restore {
                    state.operation = .restoring
                    effects.append(restore())
                }
                return .merge(effects)
            case .buyTapped:
                guard !state.isBusy, !state.isPending, case .loaded = state.offer else { return .none }

                state.operation = .purchasing
                return purchase()
            case .restoreTapped:
                guard !state.isBusy else { return .none }

                state.operation = .restoring
                return restore()
            case .retryTapped:
                guard state.offer == .unavailable else { return .none }

                state.offer = .loading
                return loadOffer()
            case .closeTapped, .doneTapped:
                guard !state.isBusy else { return .none }

                return .send(.delegate(.closeRequested))
        }
    }

    private func reduce(into state: inout State, _ action: Action.Internal) -> Effect<Action> {
        switch action {
            case let .offerLoaded(offer):
                state.offer = .loaded(offer)
                return .none
            case .offerFailed:
                state.offer = .unavailable
                return .none
            case let .purchaseFinished(outcome):
                state.operation = nil
                switch outcome {
                    case .purchased:
                        return operationSucceeded(&state)
                    case .pending:
                        if state.status == .full {
                            // The approval arrived before the purchase returned.
                            state.didUnlockHere = true
                        } else {
                            state.isPending = true
                        }
                        return .none
                    case .cancelled:
                        return closeIfUnlockedElsewhere(state)
                }
            case let .purchaseFailed(failure):
                state.operation = nil
                guard !state.isUnlockedElsewhere else { return closeIfUnlockedElsewhere(state) }

                switch failure {
                    case .notAllowed:
                        state.destination = .alert(.purchaseNotAllowed)
                    case .unverified:
                        state.destination = .restoreOffer(.purchaseUnverified)
                    case .other:
                        state.destination = .alert(.purchaseFailed)
                }
                return .none
            case let .restoreFinished(outcome):
                state.operation = nil
                switch outcome {
                    case .restored:
                        return operationSucceeded(&state)
                    case .nothingFound:
                        guard !state.isUnlockedElsewhere else { return closeIfUnlockedElsewhere(state) }

                        state.destination = .alert(.nothingToRestore)
                        return .none
                    case .cancelled:
                        return closeIfUnlockedElsewhere(state)
                }
            case .restoreFailed:
                state.operation = nil
                guard !state.isUnlockedElsewhere else { return closeIfUnlockedElsewhere(state) }

                state.destination = .alert(.restoreFailed)
                return .none
            case let .statusChanged(status):
                let previous = state.status
                state.status = status
                return statusChanged(from: previous, &state)
            case .confirmationTimedOut:
                guard state.isAwaitingConfirmation else { return .none }

                Self.logger.error("StoreKit reported a successful operation, but the full version was not published in time")
                state.isAwaitingConfirmation = false
                state.destination = .restoreOffer(.confirmationFailed)
                return .none
        }
    }

    /// A purchase or a restore said yes: success shows once the status says `.full` too, which a monitor publishes
    /// before returning but a refund may already have replaced.
    private func operationSucceeded(_ state: inout State) -> Effect<Action> {
        guard state.status != .full else {
            state.didUnlockHere = true
            return .none
        }

        state.expectsUnlock = true
        state.isAwaitingConfirmation = true
        return .run { [clock] send in
            try await clock.sleep(for: Self.confirmationTimeout)
            await send(.internal(.confirmationTimedOut))
        }
        .cancellable(id: CancelID.confirmation, cancelInFlight: true)
    }

    private func statusChanged(from previous: FullVersionStatus, _ state: inout State) -> Effect<Action> {
        switch state.status {
            case .full:
                if state.expectsUnlock || state.isPending {
                    // This sheet's purchase or restore, also after its confirmation timed out, or its approved Ask to Buy.
                    state.didUnlockHere = true
                    state.expectsUnlock = false
                    state.isAwaitingConfirmation = false
                    state.isPending = false
                    if state.destination?.is(\.restoreOffer) == true {
                        state.destination = nil
                    }
                    return .cancel(id: CancelID.confirmation)
                }
                return closeIfUnlockedElsewhere(state)
            case .free:
                // A refund or a revocation returns the offer; StoreKit's first answer only says what was unknown.
                guard previous == .full else { return .none }

                state.didUnlockHere = false
                state.expectsUnlock = false
                state.isAwaitingConfirmation = false
                state.isPending = false
                return .cancel(id: CancelID.confirmation)
            case .unknown:
                return .none
        }
    }

    private func closeIfUnlockedElsewhere(_ state: State) -> Effect<Action> {
        state.isUnlockedElsewhere ? .send(.delegate(.closeRequested)) : .none
    }

    private func loadOffer() -> Effect<Action> {
        .run { [purchases] send in
            do {
                await send(.internal(.offerLoaded(try await purchases.offer())))
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Failed to load the full version's price: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.offerFailed))
            }
        }
        .cancellable(id: CancelID.offer, cancelInFlight: true)
    }

    private func observeStatus() -> Effect<Action> {
        .run { [purchases] send in
            for await status in await purchases.changes() {
                await send(.internal(.statusChanged(status)))
            }
        }
        .cancellable(id: CancelID.status, cancelInFlight: true)
    }

    private func purchase() -> Effect<Action> {
        .run { [purchases] send in
            do {
                await send(.internal(.purchaseFinished(try await purchases.purchase())))
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("The purchase failed: \(String(reflecting: error), privacy: .public)")
                let failure: PurchaseFailure = switch error as? PurchaseClientError {
                    case .notAllowed: .notAllowed
                    case .unverified: .unverified
                    default: .other
                }
                await send(.internal(.purchaseFailed(failure)))
            }
        }
        .cancellable(id: CancelID.operation)
    }

    private func restore() -> Effect<Action> {
        .run { [purchases] send in
            do {
                await send(.internal(.restoreFinished(try await purchases.restore())))
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Restoring purchases failed: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.restoreFailed))
            }
        }
        .cancellable(id: CancelID.operation)
    }
}

extension PurchaseFeature.Destination.State: Equatable, Sendable {}
