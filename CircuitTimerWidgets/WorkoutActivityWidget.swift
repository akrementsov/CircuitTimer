import ActivityKit
import DesignSystem
import Foundation
import SwiftUI
import WidgetKit
import WorkoutActivity

/// Always the app's dark palette, whatever the system theme.
struct WorkoutActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            LockScreenView(
                display: WorkoutActivityDisplay(context), activityID: context.activityID, generation: context.state.controlGeneration
            )
                .activityBackgroundTint(.surface(.screen))
                .activitySystemActionForegroundColor(.text(.primary))
                .environment(\.colorScheme, .dark)
        } dynamicIsland: { context in
            IslandViews.dynamicIsland(
                WorkoutActivityDisplay(context), activityID: context.activityID, generation: context.state.controlGeneration
            )
        }
    }
}

private extension WorkoutActivityDisplay {
    init(_ context: ActivityViewContext<WorkoutActivityAttributes>) {
        self.init(attributes: context.attributes, content: context.state, isStale: context.isStale)
    }
}

// MARK: - Previews

private extension WorkoutActivityAttributes {
    static let preview = Self(workoutName: "Morning")
}

private extension WorkoutActivityAttributes.ContentState {
    static var running: Self {
        // Previews receive no injected clock, and a counting clock needs dates around the present.
        // swiftlint:disable:next no_direct_date
        let now = Date()
        return Self(phase: .running(WorkoutActivityAttributes.Running(
            stage: WorkoutActivityAttributes.Stage(kind: .work, name: "Squats"),
            stageStart: now.addingTimeInterval(-7),
            stageEnd: now.addingTimeInterval(23),
            next: .stage(WorkoutActivityAttributes.Stage(kind: .rest, name: nil), end: now.addingTimeInterval(53))
        )))
    }

    static let paused = Self(phase: .paused(WorkoutActivityAttributes.HeldStage(
        stage: WorkoutActivityAttributes.Stage(kind: .work, name: "Squats"),
        remainingMilliseconds: 23_000
    )))

    static let finished = Self(phase: .finished)
}

#Preview("Lock Screen", as: .content, using: WorkoutActivityAttributes.preview) {
    WorkoutActivityWidget()
} contentStates: {
    WorkoutActivityAttributes.ContentState.running
    WorkoutActivityAttributes.ContentState.paused
    WorkoutActivityAttributes.ContentState.finished
}

#Preview("Compact", as: .dynamicIsland(.compact), using: WorkoutActivityAttributes.preview) {
    WorkoutActivityWidget()
} contentStates: {
    WorkoutActivityAttributes.ContentState.running
    WorkoutActivityAttributes.ContentState.paused
}

#Preview("Expanded", as: .dynamicIsland(.expanded), using: WorkoutActivityAttributes.preview) {
    WorkoutActivityWidget()
} contentStates: {
    WorkoutActivityAttributes.ContentState.running
    WorkoutActivityAttributes.ContentState.paused
}
