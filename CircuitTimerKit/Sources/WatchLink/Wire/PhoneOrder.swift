import Foundation

/// Where a state came from. A reply answers the watch's request in flight; a context or a message arrives unasked.
public enum StateSource: Equatable, Sendable {
    case context
    case message
    case reply
}

/// The watch's view of which iPhone states are newer. Dates order nothing: one process numbers its states, and a new
/// process is believed only when it answers the watch's own request, because WatchConnectivity promises no order
/// between what two processes sent.
public struct PhoneOrder: Equatable, Sendable {
    public enum CatalogChange: Equatable, Sendable {
        /// Show this catalog.
        case replaced(CatalogState)
        /// The iPhone still has the catalog the watch shows.
        case confirmed
        /// The state says nothing the watch can use about the catalog; keep the one shown.
        case unknown
    }

    public struct Outcome: Equatable, Sendable {
        /// `nil` when the state was not accepted.
        public let change: CatalogChange?
        /// Ask the iPhone for its current state.
        public let asksAgain: Bool
    }

    private struct Asked: Equatable, Sendable {
        let processID: UUID
        let sequence: Int
    }

    public private(set) var processID: UUID?
    public private(set) var lastSequence: Int?
    /// The digest of the catalog the watch shows.
    public private(set) var catalogDigest: String?
    /// The process that last vouched for the catalog the watch shows; another accepted process means the list may be
    /// old.
    public private(set) var catalogConfirmedBy: UUID?
    /// The states asked about lately, so two delayed processes taking turns do not wake the iPhone again and again.
    private var askedFor: [Asked] = []
    /// A newer accepted state named a catalog the watch has not received yet.
    public private(set) var hasNewerCatalogDigest = false

    public var vouchesForCatalog: Bool {
        processID != nil && catalogConfirmedBy == processID && !hasNewerCatalogDigest
    }

    public init() {}

    public mutating func receive(_ state: PhoneState, from source: StateSource) -> Outcome {
        guard let processID, processID == state.processID else {
            if self.processID == nil || source == .reply {
                self.processID = state.processID
                lastSequence = state.sequence
                return applyCatalog(of: state)
            }
            return Outcome(change: nil, asksAgain: ask(for: state))
        }
        if let lastSequence, source == .reply ? state.sequence < lastSequence : state.sequence <= lastSequence {
            return Outcome(change: nil, asksAgain: false)
        }
        lastSequence = state.sequence
        return applyCatalog(of: state)
    }

    private mutating func applyCatalog(of state: PhoneState) -> Outcome {
        if let catalog = state.catalog {
            catalogDigest = state.catalogDigest
            catalogConfirmedBy = state.processID
            hasNewerCatalogDigest = false
            return Outcome(change: .replaced(catalog), asksAgain: false)
        }
        guard let digest = state.catalogDigest else {
            return Outcome(change: .unknown, asksAgain: false)
        }
        if digest == catalogDigest {
            catalogConfirmedBy = state.processID
            hasNewerCatalogDigest = false
            return Outcome(change: .confirmed, asksAgain: false)
        }
        hasNewerCatalogDigest = true
        return Outcome(change: .unknown, asksAgain: ask(for: state))
    }

    /// Asks once for each of the last eight states it asked about, so a message delivered twice, or two delayed
    /// processes taking turns, do not wake the iPhone again; an older one may ask once more.
    private mutating func ask(for state: PhoneState) -> Bool {
        let asked = Asked(processID: state.processID, sequence: state.sequence)
        guard !askedFor.contains(asked) else { return false }
        askedFor.append(asked)
        if askedFor.count > Self.askedLimit {
            askedFor.removeFirst()
        }
        return true
    }

    private static let askedLimit = 8
}
