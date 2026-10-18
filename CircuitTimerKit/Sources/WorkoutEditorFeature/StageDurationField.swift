import DesignSystem
import Foundation
import SwiftUI
import UITestContract
import WorkoutDomain

/// A stage's duration typed on the number pad as MM:SS. The typed text lives here, in the view; the reducer gets
/// each accepted edit as it is typed, so totals follow the typing and Back or Save never miss the last digit.
struct StageDurationField: View {
    let stage: Stage
    /// Where the stage stands on the screen, which names the field for UI tests.
    let section: StageSection
    let index: Int
    @Binding var focus: Stage.ID?
    let hint: Text?
    let onTextChange: (String) -> Void

    /// The masked text accepted by an edit; the native field applies it before the delegate returns.
    @State private var text: String
    /// The last text the mask accepted, always masked; the base of every check, never a rejected edit.
    @State private var lastAccepted: String
    /// Whether this focus accepted an edit: without one, the field keeps showing the stored duration.
    @State private var didEdit = false

    init(
        stage: Stage,
        section: StageSection,
        index: Int,
        focus: Binding<Stage.ID?>,
        hint: Text?,
        onTextChange: @escaping (String) -> Void
    ) {
        self.stage = stage
        self.section = section
        self.index = index
        _focus = focus
        self.hint = hint
        self.onTextChange = onTextChange
        let text = StageDurationText.text(for: stage.duration)
        _text = State(initialValue: text)
        _lastAccepted = State(initialValue: text)
    }

    var body: some View {
        // The native field includes the horizontal insets so taps beside the digits also position the caret.
        Text(verbatim: "00:00")
            .hidden()
            .padding(.horizontal, .token(spacing: .m))
            .overlay {
                NumericTextField(text: text, placeholder: "00:00", isFocused: isFocused, onEdit: edit) { focused in
                    if focused, !isFocused {
                        focus = stage.id
                    } else if !focused, isFocused {
                        focus = nil
                    }
                }
                .accessibilityLabel(Text("editor.stage.duration", bundle: .module))
                .accessibilityIdentifier(AccessibilityID.Editor.stageDuration(section, index))
                // Unconditional, so the field keeps its identity and its focus: VoiceOver edits the typed text and
                // otherwise hears the stored duration in words.
                .accessibilityValue(isFocused ? Text(verbatim: text) : Text(spokenDuration))
                .accessibilityHint(hint ?? Text(verbatim: ""))
            }
            .font(.token(.body))
            .monospacedDigit()
            .padding(.vertical, .token(spacing: .s))
            .background { StageFieldPlaque(isFocused: isFocused, isEditable: true) }
            // The whole plaque focuses the field; on iOS 26 this beats the row's tap, which focuses the name.
            .contentShape(Rectangle())
            .onTapGesture {
                if !isFocused {
                    focus = stage.id
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
        focus == stage.id
    }

    /// Sends from the native edit callback: a send from `.onChange` could arrive after Back or Save clears focus.
    private func edit(_ newText: String, caretOffset: Int) -> (text: String, caretOffset: Int)? {
        guard let edit = StageDurationText.masked(newText, caretOffset: caretOffset) else { return nil }
        let accepted = edit.text
        text = accepted

        // Zeros typed over a stored fraction of a second still need to replace its duration with zero.
        let current = didEdit ? StageDurationText.duration(from: lastAccepted) : stage.duration
        let changesDuration = StageDurationText.duration(from: accepted) != current
        let changesText = accepted != lastAccepted
        lastAccepted = accepted
        if changesText || changesDuration {
            didEdit = true
            onTextChange(accepted)
        }
        return edit
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
