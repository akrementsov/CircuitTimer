@testable import WatchRemoteFeature

import Foundation
import Testing

@Suite
struct WatchRootViewStringsTests {
    // `WatchRootView` reads these keys; a key the catalog lost comes back from the bundle unchanged.
    @Test(arguments: ["watch.noCatalog.title", "watch.noCatalog.message"])
    func test_watchRootViewString_englishAndRussian_isTranslatedInBoth(key: String) throws {
        let english = try Self.string(key, language: "en")
        let russian = try Self.string(key, language: "ru")

        #expect(english != key)
        #expect(!english.isEmpty)
        #expect(russian != key)
        #expect(!russian.isEmpty)
        #expect(russian != english)
    }

    private static func string(_ key: String, language: String) throws -> String {
        let path = try #require(Bundle.module.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
