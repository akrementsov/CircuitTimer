import DesignSystem
import Foundation
import SwiftUI
import WorkoutDomain

/// The workout's stages, read-only, pushed over the paused timer: the original app showed its workout screen here
/// with the cells inactive. The editor's read-only phase draws the same cards from its own rows and strings: a feature
/// never imports another, and DesignSystem knows no workouts.
struct TimerStageListView: View {
    let title: String
    let outline: WorkoutOutline

    var body: some View {
        List {
            TitleAndTimeRow(
                title: Text("timer.list.totalTime", bundle: .module),
                duration: outline.totalDuration,
                style: .hoursMinutesSeconds,
                font: .headline
            )
            .padding(.top, .token(spacing: .xs))
            .padding(.bottom, .token(spacing: .xl))
            .screenRow()
            .listSectionSeparator(.hidden)

            ForEach(outline.sections, id: \.kind) { section in
                sectionCard(section, endsList: section.kind == outline.sections.last?.kind && !section.isFollowedByPause)
                if section.isFollowedByPause {
                    pauseCard(after: section.kind)
                }
            }
        }
        .cardList()
        .navigationTitle(title)
        .screenChrome()
    }

    private func sectionCard(_ section: WorkoutOutline.Section, endsList: Bool) -> some View {
        Section {
            TitleAndTimeRow(title: sectionTitle(section.kind), duration: section.duration, style: .adaptive, font: .body)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, .token(spacing: .l))
                .padding(.top, .token(spacing: .xl))
                .padding(.bottom, .token(spacing: .l))
                .cardRow(.top)

            if section.kind == .training {
                CaptionPlate(Text("timer.list.rounds \(section.roundCount)", bundle: .module))
                    .padding(.horizontal, .token(spacing: .l))
                    .padding(.vertical, .token(spacing: .xxs))
                    .cardRow(.middle)
            }

            ForEach(section.stages, id: \.index) { stage in
                let isLast = stage.index == section.stages.last?.index
                ReadOnlyStageRow(name: stageName(stage), intensityName: intensityName(stage), tone: tone(stage), duration: stage.duration)
                    .padding(.horizontal, .token(spacing: .l))
                    // Half of the gap between stages on each side; the last one closes the card.
                    .padding(.top, .token(spacing: .xxs))
                    .padding(.bottom, isLast ? .token(spacing: .l) : .token(spacing: .xxs))
                    .cardRow(isLast ? .bottom : .middle, endsList: endsList)
            }
        }
        .listSectionSeparator(.hidden)
    }

    private func pauseCard(after section: WorkoutSectionKind) -> some View {
        Section {
            pauseTitle(after: section)
                .font(.token(.body))
                .foregroundStyle(.text(.primary))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.token(spacing: .l))
                .cardRow(.single)
        }
        .listSectionSeparator(.hidden)
    }

    private func sectionTitle(_ section: WorkoutSectionKind) -> Text {
        switch section {
            case .warmUp: Text("timer.list.section.warmUp", bundle: .module)
            case .training: Text("timer.list.section.training", bundle: .module)
            case .coolDown: Text("timer.list.section.coolDown", bundle: .module)
        }
    }

    /// The schedule keeps a manual pause only after the warm-up or the training.
    private func pauseTitle(after section: WorkoutSectionKind) -> Text {
        switch section {
            case .warmUp: Text("timer.list.pause.afterWarmUp", bundle: .module)
            case .training, .coolDown: Text("timer.list.pause.afterTraining", bundle: .module)
        }
    }

    private func stageName(_ stage: ScheduledStage) -> Text? {
        guard let name = stage.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return Text(verbatim: name)
    }

    private func intensityName(_ stage: ScheduledStage) -> Text {
        switch stage.kind {
            case .work: Text("timer.stage.work", bundle: .module)
            case .rest, .pause: Text("timer.stage.rest", bundle: .module)
        }
    }

    private func tone(_ stage: ScheduledStage) -> DesignSystem.Token.StageColor {
        switch stage.kind {
            case .work: .work
            case .rest: .rest
            case .pause: .pause
        }
    }
}

private let previewWorkout = Workout(
    id: UUID(0),
    name: "Back day",
    warmUp: [Stage(id: UUID(1), name: "Jumping jacks", duration: .seconds(60), intensity: .work)],
    training: [
        Stage(id: UUID(2), name: "Squats with weight", duration: .seconds(45), intensity: .work),
        Stage(id: UUID(3), name: "", duration: .seconds(15), intensity: .rest),
    ],
    trainingRounds: 3,
    coolDown: [Stage(id: UUID(4), name: "Stretching", duration: .seconds(120), intensity: .rest)],
    pauseAfterWarmUp: true
)

#Preview("Stage list") {
    NavigationStack {
        TimerStageListView(title: previewWorkout.name, outline: WorkoutOutline(schedule: WorkoutSchedule(workout: previewWorkout)))
    }
    .preferredColorScheme(.dark)
}
