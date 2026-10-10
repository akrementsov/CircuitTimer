import DesignSystem
import Foundation
import SwiftUI
import WorkoutDomain

/// A stored workout, read-only: the total time, each section with its rounds and stages, and the pauses between them.
/// The timer's stage list draws the same layout from its own strings (`TimerStageListView`): a feature never imports
/// another, and DesignSystem knows no workouts.
struct WorkoutOverviewList: View {
    let outline: WorkoutOutline

    var body: some View {
        List {
            TitleAndTimeRow(
                title: Text("editor.totalWorkoutTime", bundle: .module),
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
                CaptionPlate(Text("editor.rounds \(section.roundCount)", bundle: .module))
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
            case .warmUp: Text("editor.section.warmUp", bundle: .module)
            case .training: Text("editor.section.training", bundle: .module)
            case .coolDown: Text("editor.section.coolDown", bundle: .module)
        }
    }

    /// The schedule keeps a manual pause only after the warm-up or the training.
    private func pauseTitle(after section: WorkoutSectionKind) -> Text {
        switch section {
            case .warmUp: Text("editor.pause.afterWarmUp", bundle: .module)
            case .training, .coolDown: Text("editor.pause.afterTraining", bundle: .module)
        }
    }

    private func stageName(_ stage: ScheduledStage) -> Text? {
        guard let name = stage.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return Text(verbatim: name)
    }

    private func intensityName(_ stage: ScheduledStage) -> Text {
        switch stage.kind {
            case .work: Text("editor.intensity.work", bundle: .module)
            case .rest, .pause: Text("editor.intensity.rest", bundle: .module)
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
