import ComposableArchitecture
import Foundation
import os
import SwiftUI
import WorkoutDomain
import WorkoutStorage

/// Edits a draft of one workout and saves it on request. Cancelling with changes asks first.
@Reducer
public struct WorkoutEditorFeature: Sendable {
    // A dialog with actions needs a hand-written `Action`: with a macro-generated one the scoped
    // binding would drop the user's choice. See AGENTS.md › TCA.
    @Reducer
    public enum Destination {
        @ReducerCaseIgnored
        case saveFailedAlert(AlertState<Never>)
        @ReducerCaseIgnored
        case discardConfirmation(ConfirmationDialogState<DiscardConfirmation>)

        @CasePathable
        public enum Action: Equatable, Sendable {
            case saveFailedAlert(Never)
            case discardConfirmation(DiscardConfirmation)
        }
    }

    public enum DiscardConfirmation: Equatable, Sendable {
        case discard
    }

    @ObservableState
    public struct State: Equatable, Sendable {
        public enum Mode: Equatable, Sendable {
            case create
            case edit
        }

        public let mode: Mode
        public let original: Workout
        public var draft: Workout
        public var isSaving = false
        /// The stage whose duration picker is open; one at a time.
        public var expandedStageID: Stage.ID?
        @Presents public var destination: Destination.State?

        /// A new workout starts with one work stage in the training section.
        public init(newWorkoutID: Workout.ID, firstStageID: Stage.ID) {
            let workout = Workout(id: newWorkoutID, training: [State.newStage(id: firstStageID)])
            self.init(mode: .create, workout: workout)
        }

        public init(editing workout: Workout) {
            self.init(mode: .edit, workout: workout)
        }

        private init(mode: Mode, workout: Workout) {
            // The editor offers 1…maxTrainingRounds rounds; lifting a stored 0 in both copies keeps an untouched
            // workout unchanged.
            var workout = workout
            workout.trainingRounds = max(1, WorkoutLimits.normalizedTrainingRounds(workout.trainingRounds))
            self.mode = mode
            original = workout
            draft = workout
        }

        public var hasChanges: Bool {
            draft != original
        }

        public var canSave: Bool {
            !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.totalDuration > .zero && !isSaving
        }

        /// Explains why Save is off; hidden while saving, when Save is off for another reason.
        public var showsSaveHint: Bool {
            !canSave && !isSaving
        }

        /// A swipe down must not drop unsaved changes or cancel a save in flight.
        public var blocksInteractiveDismiss: Bool {
            hasChanges || isSaving
        }

        public func canAddStage(to section: WorkoutSectionKind) -> Bool {
            draft[section].count < WorkoutLimits.maxStagesPerSection
        }

        static func newStage(id: Stage.ID) -> Stage {
            Stage(id: id, name: "", duration: .seconds(30), intensity: .work)
        }
    }

    public enum Action: ViewAction, Equatable, Sendable {
        case view(View)
        case `internal`(Internal)
        case delegate(Delegate)
        case destination(PresentationAction<Destination.Action>)

        @CasePathable
        public enum View: Equatable, Sendable {
            case nameChanged(String)
            case trainingRoundsChanged(Int)
            case pauseAfterWarmUpChanged(Bool)
            case pauseAfterTrainingChanged(Bool)
            case addStageButtonTapped(WorkoutSectionKind)
            case stagesDeleted(WorkoutSectionKind, IndexSet)
            case stagesMoved(WorkoutSectionKind, IndexSet, Int)
            case stageNameChanged(WorkoutSectionKind, Stage.ID, String)
            case stageDurationChanged(WorkoutSectionKind, Stage.ID, Duration)
            case stageIntensityTapped(WorkoutSectionKind, Stage.ID)
            case stageDurationTapped(Stage.ID)
            case cancelButtonTapped
            case saveButtonTapped
        }

        @CasePathable
        public enum Internal: Equatable, Sendable {
            case saveFailed
        }

        @CasePathable
        public enum Delegate: Equatable, Sendable {
            /// The workout exactly as it was written to storage.
            case saved(Workout)
        }
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "WorkoutEditor")

    @Dependency(\.dismiss) private var dismiss
    @Dependency(\.uuid) private var uuid
    @Dependency(\.workoutStorage) private var workoutStorage

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
                case let .view(action):
                    reduce(into: &state, action)
                case let .internal(action):
                    reduce(into: &state, action)
                case .destination(.presented(.discardConfirmation(.discard))):
                    discardChanges(state)
                case .delegate, .destination:
                    .none
            }
        }
        .ifLet(\.$destination, action: \.destination)
    }

    private func reduce(into state: inout State, _ action: Action.View) -> Effect<Action> {
        // Nothing may change the draft or close the editor while it is being written.
        guard !state.isSaving else { return .none }

        switch action {
            case let .nameChanged(name):
                state.draft.name = name
            case let .trainingRoundsChanged(rounds):
                state.draft.trainingRounds = min(max(rounds, 1), WorkoutLimits.maxTrainingRounds)
            case let .pauseAfterWarmUpChanged(isOn):
                state.draft.pauseAfterWarmUp = isOn
            case let .pauseAfterTrainingChanged(isOn):
                state.draft.pauseAfterTraining = isOn
            case let .addStageButtonTapped(section):
                guard state.canAddStage(to: section) else { return .none }

                state.draft[section].append(State.newStage(id: uuid()))
            case let .stagesDeleted(section, offsets):
                if let expanded = state.expandedStageID, offsets.contains(where: { state.draft[section][$0].id == expanded }) {
                    state.expandedStageID = nil
                }
                state.draft[section].remove(atOffsets: offsets)
            case let .stagesMoved(section, source, destination):
                state.draft[section].move(fromOffsets: source, toOffset: destination)
            case let .stageNameChanged(section, id, name):
                updateStage(id, in: section, of: &state) { $0.name = name }
            case let .stageDurationChanged(section, id, duration):
                updateStage(id, in: section, of: &state) { $0.duration = min(max(duration, .zero), WorkoutLimits.maxStageDuration) }
            case let .stageIntensityTapped(section, id):
                updateStage(id, in: section, of: &state) { $0.intensity = $0.intensity == .work ? .rest : .work }
            case let .stageDurationTapped(id):
                state.expandedStageID = state.expandedStageID == id ? nil : id
            case .cancelButtonTapped:
                guard state.hasChanges else { return .run { [dismiss] _ in await dismiss() } }

                state.destination = .discardConfirmation(.discardChanges)
            case .saveButtonTapped:
                return save(&state)
        }
        return .none
    }

    private func reduce(into state: inout State, _ action: Action.Internal) -> Effect<Action> {
        switch action {
            case .saveFailed:
                state.isSaving = false
                state.destination = .saveFailedAlert(.saveFailed)
                return .none
        }
    }

    private func discardChanges(_ state: State) -> Effect<Action> {
        // A save in flight must finish; dismissing would cancel it.
        guard !state.isSaving else { return .none }

        return .run { [dismiss] _ in await dismiss() }
    }

    private func save(_ state: inout State) -> Effect<Action> {
        guard state.canSave else { return .none }

        // The draft stays as typed, so a failed save loses nothing; storage gets the normalized copy.
        let workout = Self.normalizedForSaving(state.draft)
        state.destination = nil
        state.isSaving = true
        return .run { [workoutStorage, dismiss] send in
            do {
                try await workoutStorage.save(workout: workout)
                await send(.delegate(.saved(workout)))
                await dismiss()
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Failed to save a workout: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.saveFailed))
            }
        }
    }

    private func updateStage(
        _ id: Stage.ID,
        in section: WorkoutSectionKind,
        of state: inout State,
        _ update: (inout Stage) -> Void
    ) {
        guard let index = state.draft[section].firstIndex(where: { $0.id == id }) else { return }

        update(&state.draft[section][index])
    }

    static func normalizedForSaving(_ draft: Workout) -> Workout {
        var workout = draft
        workout.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        for section in WorkoutSectionKind.allCases {
            workout[section] = WorkoutLimits.normalizedStages(draft[section]).map { stage in
                var stage = stage
                stage.name = stage.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return stage
            }
        }
        workout.trainingRounds = WorkoutLimits.normalizedTrainingRounds(draft.trainingRounds)
        return workout
    }
}

extension WorkoutEditorFeature.Destination.State: Equatable, Sendable {}

extension AlertState where Action == Never {
    static var saveFailed: Self {
        AlertState {
            TextState("editor.saveFailed.title", bundle: .module)
        } message: {
            TextState("editor.saveFailed.message", bundle: .module)
        }
    }
}

extension ConfirmationDialogState where Action == WorkoutEditorFeature.DiscardConfirmation {
    static var discardChanges: Self {
        ConfirmationDialogState(titleVisibility: .visible) {
            TextState("editor.discard.title", bundle: .module)
        } actions: {
            ButtonState(role: .destructive, action: .discard) {
                TextState("editor.discard.confirm", bundle: .module)
            }
            ButtonState(role: .cancel) {
                TextState("editor.discard.keepEditing", bundle: .module)
            }
        }
    }
}
