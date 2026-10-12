import DesignSystem
import Foundation
import SwiftUI
import WorkoutDomain

/// A stage's duration typed on the number pad as MM:SS. The typed text lives here, in the view; the reducer gets
/// each accepted edit as it is typed, so totals follow the typing and Back or Save never miss the last digit.
struct StageDurationField: View {
    let stage: Stage
    let focus: FocusState<EditorField?>.Binding
    let hint: Text?
    let onTextChange: (String) -> Void

    /// What the field shows; a rejected edit stays here only until `.onChange` puts `lastAccepted` back.
    @State private var text: String
    /// The last text the mask accepted, always masked; the base of every check, never a rejected edit.
    @State private var lastAccepted: String
    /// Whether this focus accepted an edit: without one, the field keeps showing the stored duration.
    @State private var didEdit = false

    init(stage: Stage, focus: FocusState<EditorField?>.Binding, hint: Text?, onTextChange: @escaping (String) -> Void) {
        self.stage = stage
        self.focus = focus
        self.hint = hint
        self.onTextChange = onTextChange
        let text = StageDurationText.text(for: stage.duration)
        _text = State(initialValue: text)
        _lastAccepted = State(initialValue: text)
    }

    var body: some View {
        // The hidden text sizes the field to the read-only time, so the row keeps its layout in both phases.
        Text(verbatim: "00:00")
            .hidden()
            .overlay {
                TextField(text: typedText, prompt: Text(verbatim: "00:00").foregroundStyle(.text(.secondary))) {
                    Text("editor.stage.duration", bundle: .module)
                }
                .focused(focus, equals: .stageDuration(stage.id))
                .keyboardType(.asciiCapableNumberPad)
                .autocorrectionDisabled()
                .multilineTextAlignment(.center)
                .tint(.text(.primary))
                // Unconditional, so the field keeps its identity and its focus: VoiceOver edits the typed text and
                // otherwise hears the stored duration in words.
                .accessibilityValue(isFocused ? Text(verbatim: text) : Text(spokenDuration))
                .accessibilityHint(hint ?? Text(verbatim: ""))
            }
            .font(.token(.body))
            .monospacedDigit()
            .padding(.vertical, .token(spacing: .s))
            .padding(.horizontal, .token(spacing: .m))
            .background { StageFieldPlaque(isFocused: isFocused, isEditable: true) }
            // The whole plaque focuses the field; on iOS 26 this beats the row's tap, which focuses the name.
            .contentShape(Rectangle())
            .onTapGesture { focus.wrappedValue = .stageDuration(stage.id) }
            .onChange(of: text) {
                if text != lastAccepted {
                    text = lastAccepted
                }
            }
            .onChange(of: isFocused) { _, isFocused in
                if isFocused {
                    didEdit = false
                } else {
                    show(didEdit ? StageDurationText.duration(from: lastAccepted) : stage.duration)
                }
            }
            .onChange(of: stage.duration) {
                if !isFocused {
                    show(stage.duration)
                }
            }
    }

    private var isFocused: Bool {
        focus.wrappedValue == .stageDuration(stage.id)
    }

    /// Sends each accepted edit at once, from the setter: a send from `.onChange` could come after the focus loss
    /// that Back or Save waits for. The edit shows as typed until `.onChange` puts the masked text in: assigning
    /// a text the field already has would not reach it, and a rejected edit would stay on screen.
    private var typedText: Binding<String> {
        Binding(
            get: { text },
            set: { newText in
                text = newText
                guard let accepted = StageDurationText.masked(newText) else { return }

                // Zeros typed over a stored fraction of a second read «00:00» as before, yet they set the stage to
                // zero; so does any accepted edit whose duration differs from what the stage has.
                let current = didEdit ? StageDurationText.duration(from: lastAccepted) : stage.duration
                let changesDuration = StageDurationText.duration(from: accepted) != current
                let changesText = accepted != lastAccepted
                lastAccepted = accepted
                guard changesText || changesDuration else { return }

                didEdit = true
                onTextChange(accepted)
            }
        )
    }

    private func show(_ duration: Duration) {
        let shown = StageDurationText.text(for: duration)
        lastAccepted = shown
        text = shown
        didEdit = false
    }

    /// Minutes and seconds in words; a stored fraction of a second adds milliseconds, so it never reads as nothing.
    private var spokenDuration: String {
        let duration = min(max(stage.duration, .zero), WorkoutLimits.maxStageDuration)
        let units: Set<Duration.UnitsFormatStyle.Unit> = duration.components.attoseconds == 0
            ? [.minutes, .seconds]
            : [.minutes, .seconds, .milliseconds]
        return duration.formatted(.units(allowed: units, width: .wide))
    }
}
