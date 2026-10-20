@testable import WorkoutActivity

import AppIntents
import Dependencies
import Foundation
import Testing

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

    @Test(arguments: [LiveActivityCommand.pause, .resume], [
        LiveActivityControlResult.stale, .busy, .timedOut, .unavailable, .failed,
    ])
    func test_perform_failedDelivery_reportsTheExpectedMessage(
        command: LiveActivityCommand, result: LiveActivityControlResult
    ) async {
        await withDependencies {
            $0.liveActivity.deliver = { _, _, _ in result }
        } operation: {
            do {
                try await perform(command)
                Issue.record("A failed Live Activity command must report an error.")
            } catch {
                #expect((error as? any LocalizedError)?.errorDescription == Self.message(for: result))
            }
        }
    }

    @Test(arguments: [LiveActivityCommand.pause, .resume], [LiveActivityControlResult.applied, .orphanEnded])
    func test_perform_successfulDelivery_doesNotThrow(command: LiveActivityCommand, result: LiveActivityControlResult) async throws {
        try await withDependencies {
            $0.liveActivity.deliver = { _, _, _ in result }
        } operation: {
            try await perform(command)
        }
    }

    @Test(arguments: [LiveActivityCommand.pause, .resume])
    func test_perform_cancelledDelivery_preservesCancellation(command: LiveActivityCommand) async {
        await withDependencies {
            $0.liveActivity.deliver = { _, _, _ in .cancelled }
        } operation: {
            await #expect(throws: CancellationError.self) { try await perform(command) }
        }
    }

    @Test(arguments: [
        ("activity.intent.error.stale", "Состояние тренировки изменилось. Повторите действие на обновлённой карточке."),
        (
            "activity.intent.error.busy",
            "Предыдущее действие ещё выполняется. Повторите чуть позже."
        ),
        (
            "activity.intent.error.timedOut",
            "Действие занимает больше времени, чем ожидалось. Проверьте таймер в приложении."
        ),
        (
            "activity.intent.error.unavailable",
            "Проверьте таймер в приложении. Карточка Live Activity может показывать прежнее состояние."
        ),
    ])
    func test_errorResources_russian_containsTheExpectedTranslation(key: String, expected: String) throws {
        let path = try #require(Bundle.module.path(forResource: "ru", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(bundle.localizedString(forKey: key, value: nil, table: nil) == expected)
    }

    private func perform(_ command: LiveActivityCommand) async throws {
        switch command {
            case .pause:
                _ = try await PauseWorkoutIntent(activityID: "rendered-activity", generation: 17).perform()
            case .resume:
                _ = try await ResumeWorkoutIntent(activityID: "rendered-activity", generation: 17).perform()
        }
    }

    private static func message(for result: LiveActivityControlResult) -> String {
        switch result {
            case .stale:
                "The workout has changed. Try again from the updated card."
            case .busy:
                "The previous workout action is still finishing. Try again shortly."
            case .timedOut:
                "The workout action is taking longer than expected. Check the timer in the app."
            case .unavailable, .failed:
                "Check the timer in the app. The Live Activity may show an earlier workout state."
            default:
                "Unexpected outcome in the failure table"
        }
    }
}
