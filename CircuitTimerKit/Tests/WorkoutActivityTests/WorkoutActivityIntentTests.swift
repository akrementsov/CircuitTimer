import AppIntents
import Dependencies
import Foundation
import Testing
import WorkoutActivity

@Suite
struct WorkoutActivityIntentTests {
    @Test(arguments: [LiveActivityCommand.pause, .resume])
    func test_perform_deliversTheRenderedActivityAndGeneration(command: LiveActivityCommand) async throws {
        let deliveries = LockIsolated<[LiveActivityControlRequest]>([])
        try await withDependencies {
            $0.liveActivity.deliver = { activityID, command, generation in
                #expect(activityID == "rendered-activity")
                deliveries.withValue { $0.append(LiveActivityControlRequest(id: 0, command: command, generation: generation)) }
                return .applied
            }
        } operation: {
            switch command {
                case .pause:
                    _ = try await PauseWorkoutIntent(activityID: "rendered-activity", generation: 17).perform()
                case .resume:
                    _ = try await ResumeWorkoutIntent(activityID: "rendered-activity", generation: 17).perform()
            }
        }
        #expect(deliveries.value == [LiveActivityControlRequest(id: 0, command: command, generation: 17)])
    }

    @Test(arguments: [LiveActivityCommand.pause, .resume])
    func test_perform_staleDelivery_reportsALocalizedError(command: LiveActivityCommand) async {
        await withDependencies {
            $0.liveActivity.deliver = { _, _, _ in .stale }
        } operation: {
            do {
                switch command {
                    case .pause:
                        _ = try await PauseWorkoutIntent(activityID: "rendered-activity", generation: 17).perform()
                    case .resume:
                        _ = try await ResumeWorkoutIntent(activityID: "rendered-activity", generation: 17).perform()
                }
                Issue.record("A stale Live Activity command must report an error.")
            } catch {
                #expect((error as? any LocalizedError)?.errorDescription?.isEmpty == false)
            }
        }
    }

    @Test(arguments: [LiveActivityControlResult.busy, .failed, .timedOut, .unavailable])
    func test_perform_failedDelivery_doesNotReportSuccess(result: LiveActivityControlResult) async {
        await withDependencies {
            $0.liveActivity.deliver = { _, _, _ in result }
        } operation: {
            await #expect(throws: (any Error).self) {
                _ = try await PauseWorkoutIntent(activityID: "rendered-activity", generation: 17).perform()
            }
        }
    }
}
