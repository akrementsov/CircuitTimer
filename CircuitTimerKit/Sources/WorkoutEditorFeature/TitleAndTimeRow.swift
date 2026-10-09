import DesignSystem
import Foundation
import SwiftUI

/// A title with a duration at the trailing edge: the workout's total time and each section's header.
struct TitleAndTimeRow: View {
    let title: Text
    let duration: Duration
    let style: Duration.ClockTextStyle
    let font: DesignSystem.Token.Typography

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var minimumTitleWidth: CGFloat = .token(size: .rowTitleMinWidth)

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stacked
            } else {
                ViewThatFits(in: .horizontal) {
                    inline
                    stacked
                }
            }
        }
        .font(.token(font))
        .foregroundStyle(.text(.primary))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        // VoiceOver reads units in the user's language instead of the clock digits.
        .accessibilityValue(
            Text(duration, format: .units(allowed: [.hours, .minutes, .seconds], width: .wide, fractionalPart: .hide(rounded: .down)))
        )
    }

    private var inline: some View {
        HStack(spacing: .token(spacing: .l)) {
            // The ideal width is capped so a long title truncates instead of pushing the time under it.
            title
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: minimumTitleWidth, idealWidth: minimumTitleWidth, maxWidth: .infinity, alignment: .leading)
            time
                .fixedSize()
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: .token(spacing: .xs)) {
            title
                .lineLimit(2)
            time
                .lineLimit(1)
                // Four-digit hours at the largest text sizes.
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var time: some View {
        Text(duration.clockText(style))
            .monospacedDigit()
    }
}
