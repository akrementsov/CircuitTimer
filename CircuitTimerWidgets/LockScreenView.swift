import DesignSystem
import SwiftUI
import WorkoutActivity

/// The workout's name, a card in the stage's colour with its clock, and the stage that comes next.
struct LockScreenView: View {
    let display: WorkoutActivityDisplay

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
                .font(.token(.stageName))
                .textCase(.uppercase)
                .lineLimit(2)
                .layoutPriority(1)
            ActivityClockText(display.clock, style: .lockScreenClock, glyphSide: .token(size: .activityGlyph))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(display.tone.ink)
        .padding(.vertical, .token(spacing: .s))
        .padding(.horizontal, .token(spacing: .l))
        .frame(maxWidth: .infinity, minHeight: .token(size: .activityStageCard))
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
                .layoutPriority(1)
            ActivityClockText(next.clock, style: .nextClock, glyphSide: .token(size: .marker))
                .foregroundStyle(.text(.secondary))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, .token(spacing: .xxs))
    }
}
