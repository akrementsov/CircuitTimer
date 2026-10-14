import SwiftUI
import WorkoutDomain

/// A workout or stage name typed within `WorkoutLimits.maxNameLength`. The typed text lives here, like a duration's:
/// each accepted edit goes up at once from the setter, and an edit past the limit only shows until `.onChange` puts
/// the last accepted text back.
struct LimitedNameField: View {
    /// The name as the draft has it.
    let name: String
    let prompt: Text
    let label: Text
    let onChange: (String) -> Void

    @State private var text: String
    /// The last text the limit accepted; the base of every check, never a rejected edit.
    @State private var lastAccepted: String

    init(name: String, prompt: Text, label: Text, onChange: @escaping (String) -> Void) {
        self.name = name
        self.prompt = prompt
        self.label = label
        self.onChange = onChange
        _text = State(initialValue: name)
        _lastAccepted = State(initialValue: name)
    }

    var body: some View {
        TextField(text: typedText, prompt: prompt) { label }
            .onChange(of: text) {
                if text != lastAccepted {
                    text = lastAccepted
                }
            }
            // The draft changes the name on its own too: the trim on leaving the field, the pencil, a save.
            .onChange(of: name) {
                if name != lastAccepted {
                    lastAccepted = name
                    text = name
                }
            }
    }

    private var typedText: Binding<String> {
        Binding(
            get: { text },
            set: { newText in
                text = newText
                let accepted = WorkoutLimits.limitedName(newText, previous: lastAccepted)
                guard accepted != lastAccepted else { return }

                lastAccepted = accepted
                onChange(accepted)
            }
        )
    }
}
