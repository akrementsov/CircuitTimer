import DesignSystem
import SwiftUI
import WorkoutActivity

/// Carries the card's exact identity and generation; the timer decides whether it still applies.
struct ActivityControlButton: View {
    let command: LiveActivityCommand
    let activityID: String
    let generation: Int

    var body: some View {
        Group {
            switch command {
                case .pause:
                    Button(intent: PauseWorkoutIntent(activityID: activityID, generation: generation)) {
                        Label("activity.control.pause", systemImage: "pause.fill")
                            .controlLabel()
                    }
                case .resume:
                    Button(intent: ResumeWorkoutIntent(activityID: activityID, generation: generation)) {
                        Label("activity.control.resume", systemImage: "play.fill")
                            .controlLabel()
                    }
            }
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func controlLabel() -> some View {
        labelStyle(.iconOnly)
            .font(.token(.activityControl))
            .frame(width: .token(size: .activityControl), height: .token(size: .activityControl))
            .contentShape(Rectangle())
    }
}
