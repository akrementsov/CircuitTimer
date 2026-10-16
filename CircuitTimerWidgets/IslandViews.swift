import DesignSystem
import SwiftUI
import WidgetKit
import WorkoutActivity

/// Compact: the stage and its clock in the stage's colour. Minimal: the clock alone. Expanded: the stage with a large
/// clock, then the stage that comes next.
enum IslandViews {
    @MainActor
    static func dynamicIsland(_ display: WorkoutActivityDisplay) -> DynamicIsland {
        DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
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
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            DynamicIslandExpandedRegion(.trailing) {
                ActivityClockText(display.islandClock, style: .expandedClock, glyphSide: .token(size: .activityGlyph))
                    .foregroundStyle(display.tone.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            DynamicIslandExpandedRegion(.bottom) {
                if let next = display.next {
                    HStack(alignment: .firstTextBaseline, spacing: .token(spacing: .xs)) {
                        Text("activity.next")
                            .font(.token(.label))
                            .foregroundStyle(.text(.secondary))
                        Text(next.label)
                            .font(.token(.nextName))
                            .textCase(.uppercase)
                            .foregroundStyle(next.tone.accent)
                            .lineLimit(1)
                            .layoutPriority(1)
                        ActivityClockText(next.clock, style: .nextClock, glyphSide: .token(size: .marker))
                            .foregroundStyle(.text(.secondary))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        } compactLeading: {
            Text(display.headline)
                .font(.token(.compactStageName))
                .textCase(.uppercase)
                .foregroundStyle(display.tone.accent)
                .lineLimit(1)
        } compactTrailing: {
            ActivityClockText(display.islandClock, style: .compactClock, glyphSide: .token(size: .marker))
                .foregroundStyle(display.tone.accent)
                .frame(width: .token(size: .activityCompactClock), alignment: .trailing)
        } minimal: {
            ActivityClockText(display.islandClock, style: .minimalClock, glyphSide: .token(size: .marker))
                .foregroundStyle(display.tone.accent)
                .frame(width: .token(size: .activityMinimalClock))
        }
        .keylineTint(display.tone.accent)
    }
}
