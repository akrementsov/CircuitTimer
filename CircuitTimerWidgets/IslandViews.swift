import DesignSystem
import SwiftUI
import WidgetKit
import WorkoutActivity

/// Compact: the stage and its clock in the stage's colour. Minimal: the clock alone. Expanded: the stage with a large
/// clock, then the stage that comes next.
enum IslandViews {
    @MainActor
    static func dynamicIsland(_ display: WorkoutActivityDisplay, activityID: String, generation: Int) -> DynamicIsland {
        DynamicIsland {
            // One full-width region: the leading and trailing ones beside the camera are too narrow for a stage name.
            DynamicIslandExpandedRegion(.bottom) {
                VStack(spacing: .token(spacing: .xs)) {
                    HStack(alignment: .bottom, spacing: .token(spacing: .m)) {
                        VStack(alignment: .leading, spacing: .token(spacing: .xxs)) {
                            Text("activity.now")
                                .font(.token(.label))
                                .foregroundStyle(.text(.secondary))
                            Text(display.headline)
                                .font(.token(.expandedStageName))
                                .textCase(.uppercase)
                                .foregroundStyle(display.tone.accent)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        ActivityClockText(display.islandClock, style: .expandedClock, glyphSide: .token(size: .activityGlyph))
                            .foregroundStyle(display.tone.accent)
                            .layoutPriority(1)
                        if let command = display.control {
                            ActivityControlButton(command: command, activityID: activityID, generation: generation)
                                .foregroundStyle(display.tone.accent)
                        }
                    }
                    if let next = display.next {
                        nextRow(next)
                    }
                }
                // The bottom corners of the island are round; the content stays inside them.
                .padding(.horizontal, .token(spacing: .xs))
            }
        } compactLeading: {
            Text(display.headline)
                .font(.token(.compactStageName))
                .textCase(.uppercase)
                .foregroundStyle(display.tone.accent)
                .lineLimit(1)
        } compactTrailing: {
            ActivityClockText(display.islandClock, style: .compactClock, glyphSide: .token(size: .activitySmallGlyph))
                .foregroundStyle(display.tone.accent)
                .frame(width: .token(size: .activityCompactClock), alignment: .trailing)
        } minimal: {
            ActivityClockText(display.islandClock, style: .minimalClock, glyphSide: .token(size: .activitySmallGlyph))
                .foregroundStyle(display.tone.accent)
                .frame(width: .token(size: .activityMinimalClock))
        }
        .keylineTint(display.tone.accent)
    }

    @MainActor
    private static func nextRow(_ next: WorkoutActivityDisplay.Next) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: .token(spacing: .xs)) {
            Text("activity.next")
                .font(.token(.label))
                .foregroundStyle(.text(.secondary))
            Text(next.label)
                .font(.token(.nextName))
                .textCase(.uppercase)
                .foregroundStyle(next.tone.accent)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            ActivityClockText(next.clock, style: .nextClock, glyphSide: .token(size: .activitySmallGlyph))
                .foregroundStyle(.text(.secondary))
                .layoutPriority(1)
        }
    }
}
