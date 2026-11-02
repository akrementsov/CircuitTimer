@testable import WatchLink

import Foundation
import Testing
import WorkoutDomain

@Suite
struct WireTests {
    @Test
    func test_catalogInit_workouts_keepsOrderRawNamesAndMilliseconds() {
        let blank = Workout(
            id: UUID(link: 1),
            name: "  ",
            training: [Stage(id: UUID(link: 10), name: "", duration: .seconds(90), intensity: .work)],
            trainingRounds: 2
        )
        let empty = Workout(id: UUID(link: 2), name: "Rest day")

        let catalog = WatchCatalog(workouts: [blank, empty])

        #expect(catalog.entries == [
            WatchCatalog.Entry(id: UUID(link: 1), name: "  ", totalMilliseconds: 180_000, isPlayable: true),
            WatchCatalog.Entry(id: UUID(link: 2), name: "Rest day", totalMilliseconds: 0, isPlayable: false),
        ])
        #expect(!catalog.isTruncated)
    }

    @Test
    func test_digest_equalAndChangedCatalogs_matchesOnlyEqualOnes() throws {
        let base = makeCatalog(3)
        let digest = try WatchCatalog.digest(of: .loaded(base))

        #expect(try WatchCatalog.digest(of: .loaded(makeCatalog(3))) == digest)
        var renamed = base.entries
        renamed[1] = makeEntry(1, name: "Renamed")
        var longer = base.entries
        longer[1] = makeEntry(1, milliseconds: 61_000)
        let changes: [CatalogState] = [
            .loaded(WatchCatalog(entries: renamed)),
            .loaded(WatchCatalog(entries: longer)),
            .loaded(WatchCatalog(entries: base.entries.reversed())),
            .loaded(WatchCatalog(entries: base.entries, isTruncated: true)),
            .unavailable(.loadFailed),
        ]
        for change in changes {
            #expect(try WatchCatalog.digest(of: change) != digest)
        }
        #expect(try WatchCatalog.digest(of: .unavailable(.loadFailed)) != WatchCatalog.digest(of: .unavailable(.tooLarge)))
    }

    @Test
    func test_unavailableReason_unknownValue_decodesAsLoadFailed() throws {
        let decode = { (raw: String) in try WireCoding.decode(UnavailableReason.self, from: Data("\"\(raw)\"".utf8)) }

        #expect(try decode("tooLarge") == .tooLarge)
        #expect(try decode("loadFailed") == .loadFailed)
        #expect(try decode("watchUnplugged") == .loadFailed)
    }

    @Test(arguments: [
        (#"{"schemaVersion":3,"other":1}"#, 3 as Int?),
        (#"{"other":1}"#, nil),
        ("not json", nil),
        ("", nil),
    ])
    func test_schemaVersion_data_readsOnlyTheVersionField(json: String, expected: Int?) {
        #expect(WireCoding.schemaVersion(of: Data(json.utf8)) == expected)
    }
}
