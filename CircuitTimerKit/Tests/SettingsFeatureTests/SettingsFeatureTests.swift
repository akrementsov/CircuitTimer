@testable import SettingsFeature

import ComposableArchitecture
import Testing

@MainActor
@Suite
struct SettingsFeatureTests {
    // Separate tests rather than arguments: the arguments of one test share the stack element ID generator.
    @Test
    func test_aboutTapped_versionAvailable_pushesAboutWithVersion() async {
        let store = makeStore(version: "1.2")

        await store.send(.view(.aboutTapped)) {
            $0.path[id: 0] = .about(version: "1.2")
        }
    }

    @Test
    func test_aboutTapped_versionMissing_pushesAboutWithoutVersion() async {
        let store = makeStore(version: nil)

        await store.send(.view(.aboutTapped)) {
            $0.path[id: 0] = .about(version: nil)
        }
    }

    @Test
    func test_legalDocumentTapped_eachDocument_pushesLegalDocument() async {
        let store = makeStore()

        await store.send(.view(.aboutTapped)) {
            $0.path[id: 0] = .about(version: "1.2")
        }
        await store.send(.view(.legalDocumentTapped(.privacyPolicy))) {
            $0.path[id: 1] = .legalDocument(.privacyPolicy)
        }
        await store.send(.view(.legalDocumentTapped(.userAgreement))) {
            $0.path[id: 2] = .legalDocument(.userAgreement)
        }
    }

    @Test
    func test_pathPopFrom_pushedScreens_removesFromThatScreenUp() async {
        let store = makeStore()
        await store.send(.view(.aboutTapped)) {
            $0.path[id: 0] = .about(version: "1.2")
        }
        await store.send(.view(.legalDocumentTapped(.privacyPolicy))) {
            $0.path[id: 1] = .legalDocument(.privacyPolicy)
        }

        await store.send(.path(.popFrom(id: 1))) {
            $0.path[id: 1] = nil
        }
    }

    private func makeStore(version: String? = "1.2") -> TestStoreOf<SettingsFeature> {
        TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.appVersion.shortVersion = { version }
        }
    }
}
