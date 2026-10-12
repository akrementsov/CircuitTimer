import SwiftUI
import TipKit

/// Explains a dimmed Save once per install. After that a tap on the dimmed button and VoiceOver's hint explain it.
struct SaveWorkoutTip: Tip {
    let blocker: WorkoutEditorFeature.State.SaveBlocker

    /// One tip whatever the reason, so it shows once in all.
    var id: String {
        "SaveWorkoutTip"
    }

    var title: Text {
        Text("editor.saveBlocked.title", bundle: .module)
    }

    var message: Text? {
        Text(blocker.messageKey, bundle: .module)
    }

    var options: [any TipOption] {
        Tips.MaxDisplayCount(1)
        Tips.IgnoresDisplayFrequency(true)
    }
}
