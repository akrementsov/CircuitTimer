import ComposableArchitecture
import DesignSystem
import Foundation
import SwiftUI
import WorkoutDomain

@ViewAction(for: AppFeature.self)
public struct AppView: View {
    public let store: StoreOf<AppFeature>

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text("workouts.title", bundle: .module))
        }
        .task { send(.task) }
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
                }
            case let .loaded(workouts):
                List(workouts) { workout in
                    WorkoutRow(workout: workout)
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
