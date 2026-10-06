import ComposableArchitecture
import DesignSystem
import Foundation
import SwiftUI
import WorkoutDomain
import WorkoutEditorFeature

@ViewAction(for: AppFeature.self)
public struct AppView: View {
    @Bindable public var store: StoreOf<AppFeature>

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text("workouts.title", bundle: .module))
                .toolbar {
                    if case .loaded = store.workouts {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                send(.addButtonTapped)
                            } label: {
                                Label {
                                    Text("workouts.add", bundle: .module)
                                } icon: {
                                    Image(systemName: "plus")
                                }
                            }
                        }
                    }
                }
        }
        .task { send(.task) }
        .sheet(item: $store.scope(\.$destination, action: \.destination).editor) { editorStore in
            NavigationStack {
                WorkoutEditorView(store: editorStore)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.workouts {
            case .idle, .loading:
                ProgressView()
            case let .loaded(workouts) where workouts.isEmpty:
                ContentUnavailableView {
                    Label {
                        Text("workouts.empty.title", bundle: .module)
                    } icon: {
                        Image(systemName: "figure.run")
                    }
                } description: {
                    hiddenRecordsNotice
                } actions: {
                    Button {
                        send(.addButtonTapped)
                    } label: {
                        Text("workouts.empty.create", bundle: .module)
                    }
                }
            case let .loaded(workouts):
                List {
                    Section {
                        ForEach(workouts) { workout in
                            Button {
                                send(.workoutTapped(workout.id))
                            } label: {
                                WorkoutRow(workout: workout)
                            }
                        }
                    } footer: {
                        hiddenRecordsNotice
                    }
                }
            case .failed:
                ContentUnavailableView {
                    Label {
                        Text("workouts.error.title", bundle: .module)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                } actions: {
                    Button {
                        send(.retryButtonTapped)
                    } label: {
                        Text("workouts.error.retry", bundle: .module)
                    }
                }
        }
    }

    @ViewBuilder
    private var hiddenRecordsNotice: some View {
        if store.hiddenRecordCount > 0 {
            Text("workouts.hidden \(store.hiddenRecordCount)", bundle: .module)
        }
    }
}

private struct WorkoutRow: View {
    let workout: Workout

    var body: some View {
        HStack(spacing: .token(spacing: .s)) {
            Text(workout.name)
                .font(.token(.headline))
                .foregroundStyle(.text(.primary))
            Spacer()
            Text(duration)
                .font(.token(.body))
                .monospacedDigit()
                .foregroundStyle(.text(.secondary))
        }
        .padding(.vertical, .token(spacing: .xxs))
    }

    private var duration: String {
        workout.totalDuration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }
}

#Preview {
    AppView(store: Store(initialState: AppFeature.State()) { AppFeature() })
}
