import DesignSystem
import Foundation
import SwiftUI
import WorkoutDomain

/// One stage of the workout screen: intensity marker, name, duration and, when expanded, the duration picker.
/// Read-only it keeps its layout on the inactive field color and takes no taps, like the original cell.
struct StageRow: View {
    let stage: Stage
    let isEditable: Bool
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
                    .transition(.opacity)
            }
        }
        // The picker opens inside the row's growing height instead of spilling over the rows under it.
        .clipped()
        .contentTransition(.identity)
        // Parameters, not branches: the row stays the same view in both phases and only restyles. Read-only it reads
        // as one element, like a row of the stage list.
        .accessibilityElement(children: isEditable ? .contain : .ignore)
        .accessibilityLabel(shownName)
        .accessibilityValue(Text(stage.duration.formatted(.units(allowed: [.minutes, .seconds], width: .wide))))
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
            .allowsHitTesting(isEditable)
            .accessibilityLabel(intensityName)
            .accessibilityHint(Text("editor.stage.intensity.hint", bundle: .module))

            // The same field in both phases, so turning editable changes only its color. Disabled, it takes no focus,
            // not even from the iOS 26 tap anywhere in the row.
            TextField(text: name, prompt: intensityName.foregroundStyle(.text(.secondary))) {
                Text("editor.stage.name", bundle: .module)
            }
            .focused(focus, equals: .stageName(stage.id))
            .font(.token(.body))
            .animation(nil) { $0.disabled(!isEditable) }
        }
        .padding(.vertical, .token(spacing: .s))
        .padding(.horizontal, .token(spacing: .xs))
        .background { fieldPlaque(isFocused: focus.wrappedValue == .stageName(stage.id)) }
    }

    private var durationButton: some View {
        Button(action: onDurationTap) {
            Text(stage.duration.clockText(.minutesSeconds))
                .font(.token(.body))
                .monospacedDigit()
                .fixedSize()
                .padding(.vertical, .token(spacing: .s))
                .padding(.horizontal, .token(spacing: .m))
                .background { fieldPlaque(isFocused: isExpanded) }
        }
        .buttonStyle(.borderless)
        .allowsHitTesting(isEditable)
        // A borderless button paints its label with the accent; the original field's time is white.
        .foregroundStyle(.text(.primary))
        .accessibilityLabel(Text("editor.stage.duration", bundle: .module))
        .accessibilityValue(Text(stage.duration.formatted(.units(allowed: [.minutes, .seconds], width: .wide))))
    }

    /// The plaque moves and resizes with the row, and only its color switches at once, like the original cell's.
    private func fieldPlaque(isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: .token(radius: .s), style: .continuous)
            .animation(nil) { $0.foregroundStyle(fieldColor(isFocused: isFocused)) }
    }

    private func fieldColor(isFocused: Bool) -> Color {
        if isFocused {
            .surface(.focused)
        } else if isEditable {
            .surface(.field)
        } else {
            .surface(.fieldInactive)
        }
    }

    /// What VoiceOver reads for a stage: its name, or its intensity when it has none.
    private var shownName: Text {
        if stage.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            intensityName
        } else {
            Text(verbatim: stage.name) + Text(verbatim: ", ") + intensityName
        }
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
