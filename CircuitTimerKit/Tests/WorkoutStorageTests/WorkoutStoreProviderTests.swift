@testable import WorkoutStorage

import Foundation
import SwiftData
import Testing

@Suite
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

    @Test
    func test_store_failedOpen_isRetriedThenCached() async throws {
        let opener = Opener(container: try makeContainer())
        let provider = WorkoutStoreProvider(makeContainer: opener.open)

        await #expect(throws: SaveFailure.self) { try await provider.store() }
        let opened = try await provider.store()
        let reused = try await provider.store()

        #expect(opened === reused)
        #expect(opener.attemptCount == 2)
    }
}
