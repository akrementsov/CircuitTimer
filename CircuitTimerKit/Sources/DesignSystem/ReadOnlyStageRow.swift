import Foundation
import SwiftUI

/// A stage that cannot be changed: its intensity marker and name in one field and its duration in another,
/// laid out like the editor's stage row.
public struct ReadOnlyStageRow: View {
    private let name: Text?
    private let intensityName: Text
    private let tone: DesignSystem.Token.StageColor
    private let duration: Duration

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// A stage without a name (`nil`) shows its intensity name instead, like an empty field's placeholder.
    public init(name: Text?, intensityName: Text, tone: DesignSystem.Token.StageColor, duration: Duration) {
        self.name = name
        self.intensityName = intensityName
        self.tone = tone
        self.duration = duration
    }

    public var body: some View {
        Group {
            // Beside the time an accessibility size leaves the name a few letters, so the time goes under it, closer
            // than the next stage's name (the list puts twice `xxs` between stages).
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: .token(spacing: .xxs)) {
                    nameField
                    timeField
                }
            } else {
                HStack(spacing: .token(spacing: .xs)) {
                    nameField
                    timeField
                }
            }
        }
        .font(.token(.body))
        .foregroundStyle(.text(.primary))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name.map { $0 + Text(verbatim: ", ") + intensityName } ?? intensityName)
        // VoiceOver reads units in the user's language instead of the clock digits.
        .accessibilityValue(Text(duration.formatted(.units(allowed: [.minutes, .seconds], width: .wide))))
    }

    /// The name wraps instead of truncating; the marker stays centered on its first line.
    private var nameField: some View {
        HStack(alignment: .firstTextBaseline, spacing: .token(spacing: .xs)) {
            // A zero-width space is one line of the name's font tall and shares its baseline.
            Text(verbatim: "\u{200B}")
                .frame(width: .token(size: .marker))
                .frame(minHeight: .token(size: .marker))
                .overlay {
                    RoundedRectangle(cornerRadius: .token(radius: .xs), style: .continuous)
                        .fill(.stage(tone))
                        .frame(width: .token(size: .marker), height: .token(size: .marker))
                }
            (name ?? intensityName)
                .foregroundStyle(name == nil ? .text(.secondary) : .text(.primary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, .token(spacing: .s))
        .padding(.horizontal, .token(spacing: .xs))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.surface(.fieldInactive), in: RoundedRectangle(cornerRadius: .token(radius: .s), style: .continuous))
    }

    private var timeField: some View {
        Text(duration.clockText(.minutesSeconds))
            .monospacedDigit()
            .fixedSize()
            .padding(.vertical, .token(spacing: .s))
            .padding(.horizontal, .token(spacing: .m))
            .background(.surface(.fieldInactive), in: RoundedRectangle(cornerRadius: .token(radius: .s), style: .continuous))
    }
}
