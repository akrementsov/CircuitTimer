import DesignSystem
import Foundation
import SwiftUI
import WorkoutDomain

/// One stage of the workout screen: intensity marker, name and duration.
/// Read-only it keeps its layout on the inactive field color and takes no taps, like the original cell.
struct StageRow: View {
    let stage: Stage
    let isEditable: Bool
    let onNameChange: (String) -> Void
    let focus: FocusState<EditorField?>.Binding
    let durationFocus: Binding<Stage.ID?>
    /// What VoiceOver adds to the duration; the screen shows no hints, as in the original app.
    let durationHint: Text?
    let onIntensityTap: () -> Void
    let onDurationTextChange: (String) -> Void

    var body: some View {
        HStack(spacing: .token(spacing: .xs)) {
            nameField
            duration
        }
        .foregroundStyle(.text(.primary))
        .contentTransition(.identity)
        // Parameters, not branches: the row stays the same view in both phases and only restyles; only the duration
        // swaps its text for a field, since read-only there is nothing to type. Read-only the row reads as one
        // element, like a row of the stage list.
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
            LimitedNameField(
                name: stage.name,
                prompt: intensityName.foregroundStyle(.text(.secondary)),
                label: Text("editor.stage.name", bundle: .module),
                onChange: onNameChange
            )
            .focused(focus, equals: .stageName(stage.id))
            .font(.token(.body))
            .animation(nil) { $0.disabled(!isEditable) }
        }
        .padding(.vertical, .token(spacing: .s))
        .padding(.horizontal, .token(spacing: .xs))
        .background { StageFieldPlaque(isFocused: focus.wrappedValue == .stageName(stage.id), isEditable: isEditable) }
        // The whole plaque focuses the name, and its tap comes before the screen's, which lets the keyboard go.
        .contentShape(Rectangle())
        .onTapGesture {
            if isEditable {
                focus.wrappedValue = .stageName(stage.id)
            }
        }
    }

    @ViewBuilder
    private var duration: some View {
        if isEditable {
            StageDurationField(stage: stage, focus: durationFocus, hint: durationHint, onTextChange: onDurationTextChange)
                .transition(.identity)
        } else {
            Text(stage.duration.clockText(.minutesSeconds))
                .font(.token(.body))
                .monospacedDigit()
                .fixedSize()
                .padding(.vertical, .token(spacing: .s))
                .padding(.horizontal, .token(spacing: .m))
                .background { StageFieldPlaque(isFocused: false, isEditable: false) }
                .transition(.identity)
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

/// The plaque behind a stage's name and duration. It moves and resizes with the row, and only its color switches at
/// once, like the original cell's.
struct StageFieldPlaque: View {
    let isFocused: Bool
    let isEditable: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: .token(radius: .s), style: .continuous)
            .animation(nil) { $0.foregroundStyle(color) }
    }

    private var color: Color {
        if isFocused {
            .surface(.focused)
        } else if isEditable {
            .surface(.field)
        } else {
            .surface(.fieldInactive)
        }
    }
}
