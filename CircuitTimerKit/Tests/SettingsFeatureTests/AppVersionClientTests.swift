@testable import SettingsFeature

import Testing

@Suite
struct AppVersionClientTests {
    @Test
    func test_marketingVersion_keyPresent_returnsString() {
        #expect(AppVersionClient.marketingVersion(in: ["CFBundleShortVersionString": "1.2"]) == "1.2")
    }

    @Test
    func test_marketingVersion_unusableValue_returnsNil() {
        #expect(AppVersionClient.marketingVersion(in: ["CFBundleVersion": "7"]) == nil)
        #expect(AppVersionClient.marketingVersion(in: ["CFBundleShortVersionString": 1.2]) == nil)
        #expect(AppVersionClient.marketingVersion(in: ["CFBundleShortVersionString": ""]) == nil)
    }
}
