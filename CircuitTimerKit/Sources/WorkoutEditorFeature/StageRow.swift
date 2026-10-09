import DesignSystem
import Foundation
import SwiftUI
import WorkoutDomain

/// One stage of the editor: intensity marker, name, duration and, when expanded, the duration picker.
struct StageRow: View {
    let stage: Stage
    let isExpanded: Bool
    let name: Binding<String>
    let focus: FocusState<EditorField?>.Binding
    let onIntensityTap: () -> Void
    let onDurationTap: () -> Void
    let onDurationChange: (Duration) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: .token(spacing: .xs)) {
            HStack(spacing: .token(spacing: .xs)) {
                nameField
                durationButton
            }
            .foregroundStyle(.text(.primary))

            if stage.duration == .zero {
                Text("editor.stage.skipped", bundle: .module)
                    .font(.token(.footnote))
                    .foregroundStyle(.text(.secondary))
            }

            if isExpanded {
                StageDurationPicker(duration: stage.duration, onChange: onDurationChange)
            }
        }
    }

    /// The marker sits inside the name's field, like the original app's title inset.
    private var nameField: some View {
        HStack(spacing: .token(spacing: .xs)) {
            Button(action: onIntensityTap) {
                RoundedRectangle(cornerRadius: .token(radius: .xs), style: .continuous)
                    .fill(intensityColor)
                    .frame(width: .token(size: .marker), height: .token(size: .marker))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(intensityName)
            .accessibilityHint(Text("editor.stage.intensity.hint", bundle: .module))

            TextField(text: name, prompt: intensityName.foregroundStyle(.text(.secondary))) {
                Text("editor.stage.name", bundle: .module)
            }
            .focused(focus, equals: .stageName(stage.id))
            .font(.token(.body))
        }
        .padding(.vertical, .token(spacing: .s))
        .padding(.horizontal, .token(spacing: .xs))
        .background(
            focus.wrappedValue == .stageName(stage.id) ? .surface(.focused) : .surface(.field),
            in: RoundedRectangle(cornerRadius: .token(radius: .s), style: .continuous)
        )
    }

    private var durationButton: some View {
        Button(action: onDurationTap) {
            Text(stage.duration.clockText(.minutesSeconds))
                .font(.token(.body))
                .monospacedDigit()
                .fixedSize()
                .padding(.vertical, .token(spacing: .s))
                .padding(.horizontal, .token(spacing: .m))
                .background(
                    isExpanded ? .surface(.focused) : .surface(.field),
                    in: RoundedRectangle(cornerRadius: .token(radius: .s), style: .continuous)
                )
        }
        .buttonStyle(.borderless)
        // A borderless button paints its label with the accent; the original field's time is white.
        .foregroundStyle(.text(.primary))
        .accessibilityLabel(Text("editor.stage.duration", bundle: .module))
        .accessibilityValue(Text(stage.duration.formatted(.units(allowed: [.minutes, .seconds], width: .wide))))
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
