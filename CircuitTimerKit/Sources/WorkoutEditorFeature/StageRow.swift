import DesignSystem
import SwiftUI
import WorkoutDomain

/// One stage of the editor: intensity marker, name, duration and, when expanded, the duration picker.
struct StageRow: View {
    let stage: Stage
    let isExpanded: Bool
    let name: Binding<String>
    let onIntensityTap: () -> Void
    let onDurationTap: () -> Void
    let onDurationChange: (Duration) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: .token(spacing: .xs)) {
            HStack(spacing: .token(spacing: .m)) {
                Button(action: onIntensityTap) {
                    RoundedRectangle(cornerRadius: .token(radius: .s))
                        .fill(intensityColor)
                        .frame(width: .token(spacing: .xxl), height: .token(spacing: .xxl))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(intensityName)
                .accessibilityHint(Text("editor.stage.intensity.hint", bundle: .module))

                TextField(text: name, prompt: intensityName) {
                    Text("editor.stage.name", bundle: .module)
                }

                Button(action: onDurationTap) {
                    Text(stage.duration.formatted(.time(pattern: .minuteSecond)))
                        .font(.token(.body))
                        .monospacedDigit()
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("editor.stage.duration", bundle: .module))
                .accessibilityValue(Text(stage.duration.formatted(.units(allowed: [.minutes, .seconds], width: .wide))))
            }

            if stage.duration == .zero {
                Text("editor.stage.skipped", bundle: .module)
                    .font(.token(.footnote))
                    .foregroundStyle(.text(.secondary))
            }

            if isExpanded {
                StageDurationPicker(duration: stage.duration, onChange: onDurationChange)
            }
        }
        // The separator would otherwise start at the first text, which here is the duration button.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }

    private var intensityColor: Color {
        switch stage.intensity {
            case .work: .stage(.work)
            case .rest: .stage(.rest)
        }
    }

    private var intensityName: Text {
        switch stage.intensity {
            case .work: Text("editor.intensity.work", bundle: .module)
            case .rest: Text("editor.intensity.rest", bundle: .module)
        }
    }
}
