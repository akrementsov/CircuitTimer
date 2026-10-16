import SwiftUI
import WorkoutActivity

extension Text {
    init(_ title: WorkoutActivityDisplay.Title) {
        switch title {
            case let .named(name):
                self.init(verbatim: name)
            case .untitled:
                self.init("activity.untitled")
        }
    }

    init(_ label: WorkoutActivityDisplay.Label) {
        switch label {
            case let .named(name):
                self.init(verbatim: name)
            case .work:
                self.init("activity.stage.work")
            case .rest:
                self.init("activity.stage.rest")
            case .pause:
                self.init("activity.stage.pause")
            case .getReady:
                self.init("activity.getReady")
            case .finished:
                self.init("activity.finished")
            case .openApp:
                self.init("activity.openApp")
        }
    }
}

extension WorkoutActivityDisplay.Tone {
    /// The Lock Screen card.
    var fill: Color {
        switch self {
            case .work: .stage(.work)
            case .rest: .stage(.rest)
            case .dark: .stage(.pause)
        }
    }

    /// Text on `fill`.
    var ink: Color {
        self == .dark ? .text(.primary) : .text(.onAccent)
    }

    /// Text on the black of the Dynamic Island.
    var accent: Color {
        switch self {
            case .work: .stage(.work)
            case .rest: .stage(.rest)
            case .dark: .text(.primary)
        }
    }
}
