@testable import WorkoutStorage

import CloudSync
import Dependencies
import DependenciesTestSupport
import Foundation
import SwiftData
import Testing

// Stored records take their copy identifiers from the store.
@Suite(.dependency(\.uuid, .incrementing))
struct WorkoutStoreProviderTests {
    private final class Opener: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        let container: ModelContainer

        init(container: ModelContainer) {
            self.container = container
        }

        var attemptCount: Int { lock.withLock { attempts } }

        func open() throws -> ModelContainer {
            let attempt = lock.withLock {
                attempts += 1
                return attempts
            }
            guard attempt > 1 else { throw SaveFailure() }

            return container
        }
    }

    /// Records what `live(open:)` asks of the file and of `CloudSyncClient`; opening fails for the containers in `failing`.
    private final class CloudOpener: @unchecked Sendable {
        private let lock = NSLock()
        private var opened: [String?] = []
        private var reported: [Bool] = []
        let failing: Set<String?>
        let mirrored: ModelContainer
        let local: ModelContainer

        init(failing: Set<String?> = [], mirrored: ModelContainer, local: ModelContainer) {
            self.failing = failing
            self.mirrored = mirrored
            self.local = local
        }

        var openedContainers: [String?] { lock.withLock { opened } }
        var reports: [Bool] { lock.withLock { reported } }

        func open(_ cloudKitContainer: String?) throws -> ModelContainer {
            lock.withLock { opened.append(cloudKitContainer) }
            guard !failing.contains(cloudKitContainer) else { throw SaveFailure() }

            return cloudKitContainer == nil ? local : mirrored
        }

        func cloudSync(mirroring container: String?) -> CloudSyncClient {
            var client = CloudSyncClient()
            client.mirroredContainer = { container }
            client.storeOpened = { isMirroring in self.lock.withLock { self.reported.append(isMirroring) } }
            return client
        }
    }

    @Test(arguments: ["iCloud.test", nil] as [String?])
    func test_live_decidedContainer_opensItOnceAndReportsHowItOpened(container: String?) async throws {
        let opener = CloudOpener(mirrored: try await makeContainer(), local: try await makeContainer())
        let provider = WorkoutStoreProvider.live(open: opener.open)

        let (first, second) = try await withDependencies {
            $0.cloudSync = opener.cloudSync(mirroring: container)
        } operation: {
            async let first = provider.store()
            async let second = provider.store()
            return try await (first, second)
        }

        #expect(first === second)
        #expect(first.modelContainer === (container == nil ? opener.local : opener.mirrored))
        #expect(opener.openedContainers == [container])
        #expect(opener.reports == [container != nil])
    }

    @Test
    func test_live_mirroredOpenFails_opensLocalStoreAndReportsItOnly() async throws {
        let opener = CloudOpener(failing: ["iCloud.test"], mirrored: try await makeContainer(), local: try await makeContainer())
        let provider = WorkoutStoreProvider.live(open: opener.open)

        let store = try await withDependencies {
            $0.cloudSync = opener.cloudSync(mirroring: "iCloud.test")
        } operation: {
            try await provider.store()
        }

        #expect(store.modelContainer === opener.local)
        #expect(opener.openedContainers == ["iCloud.test", nil])
        #expect(opener.reports == [false])
    }

    @Test
    func test_live_bothOpensFail_throwsWithoutReporting() async throws {
        let opener = CloudOpener(failing: ["iCloud.test", nil], mirrored: try await makeContainer(), local: try await makeContainer())
        let provider = WorkoutStoreProvider.live(open: opener.open)

        await withDependencies {
            $0.cloudSync = opener.cloudSync(mirroring: "iCloud.test")
        } operation: {
            await #expect(throws: SaveFailure.self) { try await provider.store() }
        }

        #expect(opener.openedContainers == ["iCloud.test", nil])
        #expect(opener.reports.isEmpty)
    }

    @Test
    func test_store_failedOpen_isRetriedThenCached() async throws {
        let opener = Opener(container: try await makeContainer())
        let provider = WorkoutStoreProvider(makeContainer: opener.open)

        await #expect(throws: SaveFailure.self) { try await provider.store() }
        let opened = try await provider.store()
        let reused = try await provider.store()

        #expect(opened === reused)
        #expect(opener.attemptCount == 2)
    }
}
