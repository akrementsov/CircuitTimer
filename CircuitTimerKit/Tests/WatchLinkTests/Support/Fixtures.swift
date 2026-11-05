@testable import WatchLink

import Foundation
import WorkoutDomain

extension UUID {
    /// Deterministic identifiers for the link's tests.
    init(link number: Int) {
        self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 0, UInt8(truncatingIfNeeded: number)))
    }
}

func makeEntry(_ number: Int, name: String? = nil, milliseconds: Int64 = 60_000) -> WatchCatalog.Entry {
    WatchCatalog.Entry(
        id: UUID(link: number),
        name: name ?? "Workout \(number)",
        totalMilliseconds: milliseconds,
        isPlayable: true,
        scheduleFingerprint: String(repeating: "0", count: 64)
    )
}

func makeCatalog(_ count: Int, name: (Int) -> String = { "Workout \($0)" }) -> WatchCatalog {
    WatchCatalog(entries: (0..<count).map { makeEntry($0, name: name($0)) })
}

func makeState(
    process: Int = 1,
    sequence: Int,
    catalog: CatalogState? = nil,
    digest: String? = nil,
    publishedAt: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)
) -> PhoneState {
    PhoneState(processID: UUID(link: process), sequence: sequence, publishedAt: publishedAt, catalog: catalog, catalogDigest: digest)
}
