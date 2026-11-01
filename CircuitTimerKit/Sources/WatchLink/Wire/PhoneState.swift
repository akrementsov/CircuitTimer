import Foundation
import WorkoutActivity

/// Everything the iPhone tells the watch, in one value: the context, a push and a reply all carry it.
public struct PhoneState: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    /// The iPhone process that published it; a new process starts its `sequence` again.
    public let processID: UUID
    /// Increases with every state one process publishes, in the order of the context writes.
    public let sequence: Int
    /// When the iPhone published it; it orders nothing and only says how old the list is.
    public let publishedAt: Date
    /// `nil`: the state says nothing about the catalog, the watch keeps its own.
    public let catalog: CatalogState?
    /// The digest of the iPhone's current catalog; `nil` when that process knows no catalog yet.
    public let catalogDigest: String?
    /// The running workout; always `nil` until CT-9-3.
    public let run: WatchRun?
    /// Whether `run` is running now; always `false` until CT-9-3.
    public let isRunLive: Bool

    public init(
        processID: UUID,
        sequence: Int,
        publishedAt: Date,
        catalog: CatalogState?,
        catalogDigest: String?,
        run: WatchRun? = nil,
        isRunLive: Bool = false
    ) {
        schemaVersion = WatchLinkSchema.version
        self.processID = processID
        self.sequence = sequence
        self.publishedAt = publishedAt
        self.catalog = catalog
        self.catalogDigest = catalogDigest
        self.run = run
        self.isRunLive = isRunLive
    }
}

/// The iPhone's workout list as the watch shows it.
public enum CatalogState: Codable, Equatable, Sendable {
    case loaded(WatchCatalog)
    /// The iPhone has no list to send; the watch keeps the last one it had, dimmed.
    case unavailable(UnavailableReason)
}

public enum UnavailableReason: String, Codable, Equatable, Sendable {
    /// The iPhone could not read its workouts.
    case loadFailed
    /// Even half the list does not fit in a context write.
    case tooLarge

    /// A reason a newer iPhone adds reads as a failed load, so a new reason never needs a new schema version.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .loadFailed
    }
}

/// A workout running on the iPhone, as its Live Activity shows it. CT-9-3 fills it.
public struct WatchRun: Codable, Equatable, Sendable {
    public let owner: UUID
    public let attributes: WorkoutActivityAttributes
    public let content: WorkoutActivityAttributes.ContentState

    public init(owner: UUID, attributes: WorkoutActivityAttributes, content: WorkoutActivityAttributes.ContentState) {
        self.owner = owner
        self.attributes = attributes
        self.content = content
    }
}
