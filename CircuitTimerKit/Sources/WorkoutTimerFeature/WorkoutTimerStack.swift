import ComposableArchitecture
import SwiftUI

/// The timer's navigation stack: the timer at its root and the stage list pushed over it.
public struct WorkoutTimerStack: View {
    @Bindable public var store: StoreOf<WorkoutTimerFeature>
    @Environment(\.scenePhase) private var scenePhase

    public init(store: StoreOf<WorkoutTimerFeature>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack(path: $store.scope(\.path, action: \.path)) {
            WorkoutTimerView(store: store)
        } destination: { pathStore in
            switch pathStore.case {
                case let .stageList(outline):
                    TimerStageListView(title: store.title, outline: outline)
            }
        }
        // The back button is white, like the legacy bar.
        .tint(.text(.primary))
        // Here rather than on the timer view, which leaves the screen while the stage list is open.
        .onChange(of: scenePhase) { _, phase in
            store.send(.view(.scenePhaseChanged(phase)))
        }
    }
}
