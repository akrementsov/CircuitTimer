import ComposableArchitecture
import DesignSystem
import Foundation
import SettingsFeature
import SwiftUI
import WorkoutDomain
import WorkoutEditorFeature
import WorkoutTimerFeature

@ViewAction(for: AppFeature.self)
public struct AppView: View {
    @Bindable public var store: StoreOf<AppFeature>

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        // No tint or bar background here: the selected tab takes the accent color, the bar stays the system one.
        TabView(selection: $store.selectedTab.sending(\.view.tabSelected)) {
            workoutsTab
                .onPageSwipe { send(.tabSwiped(.next)) } backward: { send(.tabSwiped(.previous)) }
                .tabItem {
                    Label {
                        Text("tabs.workouts", bundle: .module)
                    } icon: {
                        Image(systemName: "figure.run")
                    }
                }
                .tag(AppFeature.RootTab.workouts)
            SettingsView(store: store.scope(\.settings, action: \.settings))
                .onPageSwipe { send(.tabSwiped(.next)) } backward: { send(.tabSwiped(.previous)) }
                .tabItem {
                    Label {
                        Text("tabs.settings", bundle: .module)
                    } icon: {
                        Image(systemName: "gearshape")
                    }
                }
                .tag(AppFeature.RootTab.settings)
        }
        .tabBarOnlyOnRoots()
        .task { send(.task) }
        // Presented over the tab bar, so the write-failure alert shows on either tab.
        .alert($store.scope(\.$destination, action: \.destination).alert)
        .alert($store.scope(\.$destination, action: \.destination).resumeRun)
        // Full screen over the tab bar, with no swipe to dismiss: the timer closes only through its own X.
        .fullScreenCover(item: $store.scope(\.$destination, action: \.destination).timer) { timerStore in
            WorkoutTimerStack(store: timerStore)
                .onAppear { send(.timerCoverAppeared) }
        }
    }

    private var workoutsTab: some View {
        NavigationStack(path: $store.scope(\.path, action: \.path)) {
            content
                .navigationTitle(Text("workouts.title", bundle: .module))
                .toolbar {
                    if store.canAddWorkout {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                send(.addButtonTapped)
                            } label: {
                                Label {
                                    Text("workouts.add", bundle: .module)
                                } icon: {
                                    Image(systemName: "plus.app.fill")
                                        .imageScale(.large)
                                }
                            }
                            .tint(.brand)
                        }
                    }
                }
                .screenChrome()
                .tabBarOnlyOnRoot(isPushed: !store.path.isEmpty)
        } destination: { pathStore in
            switch pathStore.case {
                case let .editor(editorStore):
                    WorkoutEditorView(store: editorStore)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.workouts {
            case .idle, .loading:
                ProgressView()
                    .tint(.text(.secondary))
            case let .loaded(workouts) where workouts.isEmpty:
                VStack(spacing: .token(spacing: .m)) {
                    Text("workouts.empty.title", bundle: .module)
                        .font(.token(.body))
                        .foregroundStyle(.text(.secondary))
                    HiddenRecordsNotice(recordCount: store.hiddenRecordCount)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, .token(spacing: .l))
            case let .loaded(workouts):
                WorkoutListView(store: store, workouts: workouts, hiddenRecordCount: store.hiddenRecordCount)
            case .failed:
                VStack(spacing: .token(spacing: .m)) {
                    Text("workouts.error.title", bundle: .module)
                        .font(.token(.body))
                        .foregroundStyle(.text(.secondary))
                    Button {
                        send(.retryButtonTapped)
                    } label: {
                        Text("workouts.error.retry", bundle: .module)
                            .font(.token(.headline))
                            .foregroundStyle(.brand)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, .token(spacing: .l))
        }
    }
}

@MainActor
private func previewStore(
    _ content: AppFeature.Content,
    hiddenRecordCount: Int = 0,
    selectedTab: AppFeature.RootTab = .workouts
) -> StoreOf<AppFeature> {
    var state = AppFeature.State()
    state.selectedTab = selectedTab
    state.workouts = content
    state.hiddenRecordCount = hiddenRecordCount
    return Store(initialState: state) { AppFeature() }
}

private func previewWorkouts(count: Int) -> IdentifiedArrayOf<Workout> {
    IdentifiedArray(
        uniqueElements: (0..<count).map { index in
            Workout(
                id: UUID(index),
                name: "Workout \(index + 1)",
                training: [Stage(id: UUID(100 + index), name: "", duration: .seconds(75 * (index + 1)), intensity: .work)]
            )
        }
    )
}

#Preview("Live") {
    AppView(store: Store(initialState: AppFeature.State()) { AppFeature() })
        .preferredColorScheme(.dark)
}

#Preview("List") {
    AppView(store: previewStore(.loaded(previewWorkouts(count: 6))))
        .preferredColorScheme(.dark)
}

#Preview("Long list") {
    AppView(store: previewStore(.loaded(previewWorkouts(count: 60))))
        .preferredColorScheme(.dark)
}

#Preview("List with hidden records") {
    AppView(store: previewStore(.loaded(previewWorkouts(count: 6)), hiddenRecordCount: 2))
        .preferredColorScheme(.dark)
}

#Preview("Empty with hidden records") {
    AppView(store: previewStore(.loaded([]), hiddenRecordCount: 2))
        .preferredColorScheme(.dark)
}

#Preview("Settings tab") {
    AppView(store: previewStore(.loaded(previewWorkouts(count: 6)), selectedTab: .settings))
        .preferredColorScheme(.dark)
}

#Preview("Failed") {
    AppView(store: previewStore(.failed))
        .preferredColorScheme(.dark)
}

#Preview("Long values") {
    let longest = (0..<WorkoutLimits.maxStagesPerSection).map { index in
        Stage(id: UUID(100 + index), name: "", duration: WorkoutLimits.maxStageDuration, intensity: .work)
    }
    let workouts: IdentifiedArrayOf<Workout> = [
        Workout(id: UUID(0), name: "A workout with a name far too long to fit on one line of the list"),
        Workout(id: UUID(1), name: ""),
        Workout(id: UUID(2), name: "Short", training: [Stage(id: UUID(99), name: "", duration: .seconds(75), intensity: .work)]),
        Workout(id: UUID(3), name: "Longest", training: longest, trainingRounds: WorkoutLimits.maxTrainingRounds),
    ]
    AppView(store: previewStore(.loaded(workouts)))
        .preferredColorScheme(.dark)
}
