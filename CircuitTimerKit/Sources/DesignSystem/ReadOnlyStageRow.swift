import SwiftUI

/// A stage that cannot be changed: its intensity marker and name in one field and its duration in another,
/// laid out like the editor's stage row.
public struct ReadOnlyStageRow: View {
    private let name: Text?
    private let intensityName: Text
    private let tone: DesignSystem.Token.StageColor
    private let duration: Duration

    /// A stage without a name (`nil`) shows its intensity name instead, like an empty field's placeholder.
    public init(name: Text?, intensityName: Text, tone: DesignSystem.Token.StageColor, duration: Duration) {
        self.name = name
        self.intensityName = intensityName
        self.tone = tone
        self.duration = duration
    }

    public var body: some View {
        HStack(spacing: .token(spacing: .xs)) {
            HStack(spacing: .token(spacing: .xs)) {
                RoundedRectangle(cornerRadius: .token(radius: .xs), style: .continuous)
                    .fill(.stage(tone))
                    .frame(width: .token(size: .marker), height: .token(size: .marker))
                (name ?? intensityName)
                    .foregroundStyle(name == nil ? .text(.secondary) : .text(.primary))
                    .lineLimit(1)
            }
            .padding(.vertical, .token(spacing: .s))
            .padding(.horizontal, .token(spacing: .xs))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.surface(.field), in: RoundedRectangle(cornerRadius: .token(radius: .s), style: .continuous))

            Text(duration.clockText(.minutesSeconds))
                .monospacedDigit()
                .fixedSize()
                .padding(.vertical, .token(spacing: .s))
                .padding(.horizontal, .token(spacing: .m))
                .background(.surface(.field), in: RoundedRectangle(cornerRadius: .token(radius: .s), style: .continuous))
        }
        .font(.token(.body))
        .foregroundStyle(.text(.primary))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name.map { $0 + Text(verbatim: ", ") + intensityName } ?? intensityName)
        // VoiceOver reads units in the user's language instead of the clock digits.
        .accessibilityValue(Text(duration.formatted(.units(allowed: [.minutes, .seconds], width: .wide))))
    }
}
