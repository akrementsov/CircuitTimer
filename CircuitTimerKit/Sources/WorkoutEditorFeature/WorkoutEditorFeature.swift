import ComposableArchitecture
import Foundation
import os
import SwiftUI
import WorkoutDomain
import WorkoutStorage

/// One workout's screen: a saved workout opens read-only, and the pencil turns it into an editor of a draft
/// that is saved or discarded as a whole; a new workout opens in the editor. Leaving with changes asks first.
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
        public enum Phase: Equatable, Sendable {
            /// A workout that is not stored yet, edited until its first save.
            case new
            /// A stored workout, read-only.
            case viewing
            /// A stored workout being edited.
            case editing
        }

        public internal(set) var phase: Phase
        /// The workout exactly as it is stored: what the screen shows while viewing.
        public internal(set) var workout: Workout
        /// The base of the draft: `workout` as the editor offers it.
        public internal(set) var original: Workout
        public var draft: Workout
        public var isSaving = false
        /// The stage whose duration picker is open; one at a time.
        public var expandedStageID: Stage.ID?
        @Presents public var destination: Destination.State?

        /// A new workout starts with one work stage in the training section.
        public init(newWorkoutID: Workout.ID, firstStageID: Stage.ID) {
            let workout = Workout(id: newWorkoutID, training: [State.newStage(id: firstStageID)])
            phase = .new
            self.workout = workout
            original = workout
            draft = workout
        }

        /// A stored workout opens read-only.
        public init(viewing workout: Workout) {
            phase = .viewing
            self.workout = workout
            let editable = Self.editable(workout)
            original = editable
            draft = editable
        }

        /// Lifting a stored 0 to the editor's minimum in both the base and the draft keeps an untouched workout
        /// unchanged; `workout` keeps the stored value, which is what plays.
        static func editable(_ workout: Workout) -> Workout {
            var workout = workout
            let rounds = WorkoutLimits.normalizedTrainingRounds(workout.trainingRounds)
            workout.trainingRounds = max(Self.trainingRoundsRange.lowerBound, rounds)
            return workout
        }

        /// The rounds the editor offers: a workout without training rounds is not edited here.
        static let trainingRoundsRange = 1...WorkoutLimits.maxTrainingRounds

        public var hasChanges: Bool {
            draft != original
        }

        /// A workout needs a name and something to play.
        public var isDraftComplete: Bool {
            !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.totalDuration > .zero
        }

        /// Saving an untouched workout would write nothing new, so Save waits for a change.
        public var canSave: Bool {
            isDraftComplete && hasChanges && !isSaving
        }

        /// Explains what the draft is missing; an untouched or saving draft needs no hint.
        public var showsSaveHint: Bool {
            !isDraftComplete && !isSaving
        }

        /// The stored workout as the read-only screen shows it.
        public var outline: WorkoutOutline {
            WorkoutOutline(schedule: WorkoutSchedule(workout: workout))
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
            case stageDeleteButtonTapped(WorkoutSectionKind, Stage.ID)
            case stagesMoved(WorkoutSectionKind, IndexSet, Int)
            case stageMovedUp(WorkoutSectionKind, Stage.ID)
            case stageMovedDown(WorkoutSectionKind, Stage.ID)
            case stageNameChanged(WorkoutSectionKind, Stage.ID, String)
            case stageDurationChanged(WorkoutSectionKind, Stage.ID, Duration)
            case stageIntensityTapped(WorkoutSectionKind, Stage.ID)
            case stageDurationTapped(Stage.ID)
            case backButtonTapped
            case saveButtonTapped
            case editButtonTapped
        }

        @CasePathable
        public enum Internal: Equatable, Sendable {
            case saveFailed
            case saveSucceeded(Workout)
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

        // The read-only screen draws no editing controls; a late action from the editor it replaced changes nothing.
        switch state.phase {
            case .viewing:
                guard action == .backButtonTapped || action == .editButtonTapped else { return .none }
            case .new, .editing:
                guard action != .editButtonTapped else { return .none }
        }

        switch action {
            case let .nameChanged(name):
                state.draft.name = name
            case let .trainingRoundsChanged(rounds):
                let range = State.trainingRoundsRange
                state.draft.trainingRounds = min(max(rounds, range.lowerBound), range.upperBound)
            case let .pauseAfterWarmUpChanged(isOn):
                state.draft.pauseAfterWarmUp = isOn
            case let .pauseAfterTrainingChanged(isOn):
                state.draft.pauseAfterTraining = isOn
            case let .addStageButtonTapped(section):
                guard state.canAddStage(to: section) else { return .none }

                state.draft[section].append(State.newStage(id: uuid()))
            case let .stageDeleteButtonTapped(section, id):
                guard let index = state.draft[section].firstIndex(where: { $0.id == id }) else { return .none }

                if state.expandedStageID == id {
                    state.expandedStageID = nil
                }
                state.draft[section].remove(at: index)
            case let .stagesMoved(section, source, destination):
                // Offsets come from the list as it was drawn; stale ones would trap in `move`, so they are ignored.
                let count = state.draft[section].count
                guard !source.isEmpty, source.allSatisfy({ $0 < count }), (0...count).contains(destination) else { return .none }

                state.draft[section].move(fromOffsets: source, toOffset: destination)
            case let .stageMovedUp(section, id):
                guard let index = state.draft[section].indexMovableUp(id) else { return .none }

                state.draft[section].swapAt(index, index - 1)
            case let .stageMovedDown(section, id):
                guard let index = state.draft[section].indexMovableDown(id) else { return .none }

                state.draft[section].swapAt(index, index + 1)
            case let .stageNameChanged(section, id, name):
                updateStage(id, in: section, of: &state) { $0.name = name }
            case let .stageDurationChanged(section, id, duration):
                updateStage(id, in: section, of: &state) { $0.duration = min(max(duration, .zero), WorkoutLimits.maxStageDuration) }
            case let .stageIntensityTapped(section, id):
                updateStage(id, in: section, of: &state) { $0.intensity = $0.intensity == .work ? .rest : .work }
            case let .stageDurationTapped(id):
                state.expandedStageID = state.expandedStageID == id ? nil : id
            case .backButtonTapped:
                guard state.hasChanges else { return .run { [dismiss] _ in await dismiss() } }

                state.destination = .discardConfirmation(.discardChanges)
            case .saveButtonTapped:
                return save(&state)
            case .editButtonTapped:
                state.original = State.editable(state.workout)
                state.draft = state.original
                state.expandedStageID = nil
                state.phase = .editing
        }
        return .none
    }

    private func reduce(into state: inout State, _ action: Action.Internal) -> Effect<Action> {
        switch action {
            case .saveFailed:
                state.isSaving = false
                state.destination = .saveFailedAlert(.saveFailed)
                return .none
            case let .saveSucceeded(workout):
                state.isSaving = false
                state.workout = workout
                state.original = State.editable(workout)
                state.draft = state.original
                state.expandedStageID = nil
                state.phase = .viewing
                return .send(.delegate(.saved(workout)))
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
        return .run { [workoutStorage] send in
            do {
                try await workoutStorage.save(workout: workout)
                await send(.internal(.saveSucceeded(workout)))
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

/// One edge rule for the reducer and the rows' VoiceOver move actions:
/// the index of `id` when it can move one place within its section, otherwise `nil`.
extension Array where Element: Identifiable {
    func indexMovableUp(_ id: Element.ID) -> Int? {
        guard let index = firstIndex(where: { $0.id == id }), index > startIndex else { return nil }

        return index
    }

    func indexMovableDown(_ id: Element.ID) -> Int? {
        guard let index = firstIndex(where: { $0.id == id }), index < endIndex - 1 else { return nil }

        return index
    }
}

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
