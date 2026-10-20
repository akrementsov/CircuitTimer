@testable import AppFeature
@testable import WorkoutEditorFeature

import ComposableArchitecture
import WorkoutDomain

extension AppFeature.State {
    static func list(_ workouts: IdentifiedArrayOf<Workout>, hiddenRecordCount: Int = 0) -> Self {
        var state = Self()
        state.workouts = .loaded(workouts)
        state.hiddenRecordCount = hiddenRecordCount
        return state
    }

    static var failedList: Self {
        var state = Self()
        state.workouts = .failed
        return state
    }

    static func viewing(_ workout: Workout) -> Self {
        var state = Self.list([workout])
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: workout)))
        return state
    }

    static func editing(_ workout: Workout) -> Self {
        var editor = WorkoutEditorFeature.State(viewing: workout)
        editor.phase = .editing
        var state = Self.list([workout])
        state.path.append(.editor(editor))
        return state
    }
}
