@testable import WatchRemoteFeature

import Foundation
import Testing

@Suite
struct WatchRootViewStringsTests {
    // `WatchRootView` reads these keys; a key the catalog lost comes back from the bundle unchanged.
    @Test(arguments: [
        "watch.noCatalog.title", "watch.noCatalog.message",
        "watch.run.next", "watch.run.waiting", "watch.run.stage.work", "watch.run.stage.rest", "watch.run.stage.pause",
        "watch.run.getReady", "watch.run.finished", "watch.run.openPhone", "watch.run.tooLarge.title",
        "watch.run.tooLarge.message", "watch.run.control.pause", "watch.run.control.resume",
        "watch.run.command.checking", "watch.run.command.changed", "watch.run.command.failed",
    ])
    func test_watchRootViewString_englishAndRussian_isTranslatedInBoth(key: String) throws {
        let english = try Self.string(key, language: "en")
        let russian = try Self.string(key, language: "ru")

        #expect(english != key)
        #expect(!english.isEmpty)
        #expect(russian != key)
        #expect(!russian.isEmpty)
        #expect(russian != english)
    }

    /// Every key the module's catalog compiled, read from its English table: a translation missing from Russian,
    /// empty or equal to the English one fails, and a placeholder survives the translation.
    @Test
    func test_everyWatchString_russian_isTranslatedWithItsPlaceholders() throws {
        let english = try Self.table("en")
        let russian = try Self.table("ru")

        #expect(english.count > 20)
        for (key, value) in english {
            let translation = try #require(russian[key], "No Russian for \(key)")
            #expect(!translation.isEmpty, "\(key)")
            #expect(translation != value, "\(key)")
            #expect(translation.components(separatedBy: "%@").count == value.components(separatedBy: "%@").count, "\(key)")
        }
    }

    private static func table(_ language: String) throws -> [String: String] {
        let path = try #require(Bundle.module.path(forResource: language, ofType: "lproj"))
        let url = URL(fileURLWithPath: path).appending(path: "Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    private static func string(_ key: String, language: String) throws -> String {
        let path = try #require(Bundle.module.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
