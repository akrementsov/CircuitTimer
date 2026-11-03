import CryptoKit
import Foundation
import WorkoutDomain

/// The workouts the watch lists, in the iPhone's order.
public struct WatchCatalog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        /// The name as stored: the watch picks the label of a blank one in its own language.
        public let name: String
        public let totalMilliseconds: Int64
        public let isPlayable: Bool
        /// The normalized schedule's structure, excluding workout and stage names.
        public let scheduleFingerprint: String

        public init(id: UUID, name: String, totalMilliseconds: Int64, isPlayable: Bool, scheduleFingerprint: String) {
            self.id = id
            self.name = name
            self.totalMilliseconds = totalMilliseconds
            self.isPlayable = isPlayable
            self.scheduleFingerprint = scheduleFingerprint
        }
    }

    public let entries: [Entry]
    /// The iPhone left out the workouts at the end so the list fits in one context write.
    public let isTruncated: Bool

    public init(entries: [Entry], isTruncated: Bool = false) {
        self.entries = entries
        self.isTruncated = isTruncated
    }

    public init(workouts: [Workout]) {
        self.init(entries: workouts.map {
            Entry(
                id: $0.id,
                name: $0.name,
                totalMilliseconds: $0.totalDuration.inMilliseconds,
                isPlayable: $0.isPlayable,
                scheduleFingerprint: WorkoutSchedule(workout: $0).fingerprint
            )
        })
    }

    /// The first `count` entries, marked as cut.
    func prefix(_ count: Int) -> WatchCatalog {
        WatchCatalog(entries: Array(entries.prefix(count)), isTruncated: isTruncated || count < entries.count)
    }

    /// A SHA-256 of the encoded state, so the watch can tell an unchanged list without receiving it again. The watch
    /// stores the digest it was sent and never computes one.
    public static func digest(of state: CatalogState) throws -> String {
        let data = try WireCoding.encode(state)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
