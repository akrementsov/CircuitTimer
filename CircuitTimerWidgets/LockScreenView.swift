import DesignSystem
import SwiftUI
import WorkoutActivity

/// The workout's name, a card in the stage's colour with its clock, and the stage that comes next.
struct LockScreenView: View {
    let display: WorkoutActivityDisplay
    let activityID: String
    let generation: Int

    var body: some View {
        VStack(alignment: .leading, spacing: .token(spacing: .s)) {
            Text(display.title)
                .font(.token(.title))
                .foregroundStyle(.text(.secondary))
                .lineLimit(1)
                .padding(.horizontal, .token(spacing: .xxs))
            card
            if let next = display.next {
                nextRow(next)
            }
        }
        .padding(.token(spacing: .m))
    }

    private var card: some View {
        HStack(spacing: .token(spacing: .m)) {
            Text(display.headline)
                .font(.token(.lockScreenStageName))
                .textCase(.uppercase)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            // The clock never gives way: a long name wraps or truncates instead.
            ActivityClockText(display.clock, style: .lockScreenClock, glyphSide: .token(size: .activityGlyph))
                .layoutPriority(1)
            if let command = display.control {
                ActivityControlButton(command: command, activityID: activityID, generation: generation)
            }
        }
        .foregroundStyle(display.tone.ink)
        .padding(.vertical, .token(spacing: .s))
        .padding(.horizontal, .token(spacing: .l))
        .frame(maxWidth: .infinity, minHeight: .token(size: .activityStageCard), alignment: .leading)
        .background(display.tone.fill, in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
    }

    private func nextRow(_ next: WorkoutActivityDisplay.Next) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: .token(spacing: .xs)) {
            Text("activity.next")
                .font(.token(.label))
                .foregroundStyle(.text(.secondary))
            Text(next.label)
                .font(.token(.nextName))
                .textCase(.uppercase)
                .foregroundStyle(.text(.primary))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            ActivityClockText(next.clock, style: .nextClock, glyphSide: .token(size: .activitySmallGlyph))
                .foregroundStyle(.text(.secondary))
                .layoutPriority(1)
        }
        .padding(.horizontal, .token(spacing: .xxs))
    }
}
