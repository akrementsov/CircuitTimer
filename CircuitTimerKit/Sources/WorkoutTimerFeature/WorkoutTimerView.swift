import ComposableArchitecture
import DesignSystem
import Foundation
import SwiftUI
import WorkoutDomain

/// The full-screen timer, laid out after the original app.
@ViewAction(for: WorkoutTimerFeature.self)
public struct WorkoutTimerView: View {
    @Bindable public var store: StoreOf<WorkoutTimerFeature>

    public init(store: StoreOf<WorkoutTimerFeature>) {
        self.store = store
    }

    public var body: some View {
        GeometryReader { proxy in
            // Heights are the original app's shares of a 718-point screen below the navigation bar, which runs to the
            // bottom edge, home indicator strip included.
            let unit = (proxy.size.height + proxy.safeAreaInsets.bottom) / 718
            VStack(spacing: .zero) {
                SegmentedProgressBar(segments: store.progressSegments)
                    .frame(height: .token(size: .progressBar))
                    .padding(.top, .token(spacing: .xs))
                VStack(spacing: .token(spacing: .l)) {
                    TotalCard(value: store.totalLeft, spokenValue: store.spokenTotalLeft)
                        .frame(height: 100 * unit)
                    CurrentStageCard(card: store.currentCard)
                        .frame(height: 289 * unit)
                    NextStageCard(name: store.nextStageName)
                        .frame(height: 100 * unit)
                }
                .padding(.horizontal, .token(spacing: .l))
                .padding(.top, .token(spacing: .xxl))
                TimerButtons(
                    playButton: store.playButton,
                    isPlayEnabled: store.isPlayEnabled,
                    isNextEnabled: store.isNextEnabled,
                    onPlayPause: { send(.playPauseButtonTapped) },
                    onNext: { send(.nextButtonTapped) }
                )
                .frame(height: 98 * unit)
                .padding(.horizontal, .token(spacing: .xxxl))
                .padding(.top, .token(spacing: .xxl))
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .screenChrome()
        // On iOS 17 the editor toolbar role adds a system back button to the cover's root, which would close a running
        // workout without asking.
        .navigationBarBackButtonHidden(true)
        .navigationTitle(store.title)
        .toolbar { toolbar }
        .accessibilityAction(.escape) { send(.closeButtonTapped) }
        .alert($store.scope(\.$destination, action: \.destination).closeConfirmation)
        // Not `await send(.task).finish()`: that would tie the first clock loop to this view, a screen pushed over
        // the timer would cancel it, and `.task` acts only once, so nothing would start it again.
        .task { send(.task) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                send(.closeButtonTapped)
            } label: {
                Label {
                    Text("timer.button.close", bundle: .module)
                } icon: {
                    Image(systemName: "xmark")
                }
                .labelStyle(.iconOnly)
            }
            .tint(.text(.primary))
            // Escape from a bar item would otherwise go up to the navigation controller.
            .accessibilityAction(.escape) { send(.closeButtonTapped) }
        }
    }
}

/// Fixed states for the previews: the clock never advances, so each one holds still.
private enum PreviewTimer {
    static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_017.4)

    static let workout = Workout(
        id: UUID(0),
        name: "Back day",
        warmUp: [Stage(id: UUID(1), name: "Jumping jacks", duration: .seconds(60), intensity: .work)],
        training: [
            Stage(id: UUID(2), name: "Squats with weight", duration: .seconds(45), intensity: .work),
            Stage(id: UUID(3), name: "", duration: .seconds(15), intensity: .rest),
        ],
        trainingRounds: 3,
        coolDown: [Stage(id: UUID(4), name: "Stretching", duration: .seconds(120), intensity: .work)],
        pauseAfterWarmUp: true
    )

    static let longNames = Workout(
        id: UUID(0),
        name: "A workout with a name far too long for the navigation bar",
        training: [
            Stage(id: UUID(1), name: "Bulgarian split squats with a heavy barbell", duration: .seconds(5_999), intensity: .work),
            Stage(id: UUID(2), name: "Single-arm dumbbell row on an incline bench", duration: .seconds(45), intensity: .work),
        ],
        trainingRounds: WorkoutLimits.maxTrainingRounds
    )

    /// `play` moves the run from its start; the first stage starts at `start`.
    static func state(
        _ workout: Workout = workout,
        countdown: WorkoutTimerFeature.Countdown? = nil,
        hasClockFailed: Bool = false,
        play: (inout WorkoutRun) -> Void = { $0.start(at: PreviewTimer.start) }
    ) -> WorkoutTimerFeature.State {
        var state = WorkoutTimerFeature.State(id: UUID(0), title: workout.name, schedule: WorkoutSchedule(workout: workout))
        play(&state.run)
        state.run.tick(at: now)
        state.snapshot = state.run.snapshot(at: now)
        state.countdown = countdown
        state.hasClockFailed = hasClockFailed
        return state
    }

    static func skip(_ count: Int, in run: inout WorkoutRun) {
        run.start(at: start)
        for _ in 0..<count {
            run.skipToNextStage(at: start)
        }
    }

    @MainActor
    static func view(_ state: WorkoutTimerFeature.State) -> some View {
        NavigationStack {
            WorkoutTimerView(
                store: Store(initialState: state) {
                    WorkoutTimerFeature()
                } withDependencies: {
                    $0.date = .constant(now)
                    $0.continuousClock = TestClock()
                }
            )
        }
        .preferredColorScheme(.dark)
    }
}

#Preview("Get ready") {
    PreviewTimer.view(PreviewTimer.state(countdown: WorkoutTimerFeature.Countdown(purpose: .start, remaining: 3)) { _ in })
}

#Preview("Not started") {
    PreviewTimer.view(PreviewTimer.state { _ in })
}

#Preview("Work") {
    PreviewTimer.view(PreviewTimer.state())
}

#Preview("Rest") {
    // Skips the warm-up, the manual pause and the first squats: the rest plays.
    PreviewTimer.view(PreviewTimer.state { PreviewTimer.skip(3, in: &$0) })
}

#Preview("User pause") {
    PreviewTimer.view(
        PreviewTimer.state {
            $0.start(at: PreviewTimer.start)
            $0.pause(at: PreviewTimer.now)
        }
    )
}

#Preview("Stay countdown") {
    PreviewTimer.view(
        PreviewTimer.state(countdown: WorkoutTimerFeature.Countdown(purpose: .resume, remaining: 2)) {
            $0.start(at: PreviewTimer.start)
            $0.pause(at: PreviewTimer.now)
        }
    )
}

#Preview("Manual pause") {
    PreviewTimer.view(PreviewTimer.state { PreviewTimer.skip(1, in: &$0) })
}

#Preview("Finished") {
    PreviewTimer.view(PreviewTimer.state { PreviewTimer.skip(9, in: &$0) })
}

#Preview("Clock failed") {
    PreviewTimer.view(
        PreviewTimer.state(hasClockFailed: true) {
            $0.start(at: PreviewTimer.start)
            $0.pause(at: PreviewTimer.now)
        }
    )
}

#Preview("Longest names") {
    PreviewTimer.view(PreviewTimer.state(PreviewTimer.longNames))
}

#Preview("Accessibility size") {
    PreviewTimer.view(PreviewTimer.state())
        .dynamicTypeSize(.accessibility1)
}

#Preview("Live") {
    NavigationStack {
        WorkoutTimerView(
            store: Store(initialState: PreviewTimer.state(countdown: WorkoutTimerFeature.Countdown(.start)) { _ in }) {
                WorkoutTimerFeature()
            }
        )
    }
    .preferredColorScheme(.dark)
}
