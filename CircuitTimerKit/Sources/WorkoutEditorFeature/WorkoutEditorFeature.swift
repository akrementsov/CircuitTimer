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
    // An alert with actions needs a hand-written `Action`: with a macro-generated one the scoped
    // binding would drop the user's choice. See AGENTS.md › TCA.
    @Reducer
    public enum Destination {
        @ReducerCaseIgnored
        case saveFailedAlert(AlertState<Never>)
        @ReducerCaseIgnored
        case saveBlockedAlert(AlertState<Never>)
        @ReducerCaseIgnored
        case discardConfirmation(AlertState<DiscardConfirmation>)

        @CasePathable
        public enum Action: Equatable, Sendable {
            case saveFailedAlert(Never)
            case saveBlockedAlert(Never)
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
        /// Start was tapped and the timer is on its way; a second tap must not ask again.
        public internal(set) var isStarting = false
        /// The screen has stood still long enough since its layout last changed for the tip to point at Save.
        public internal(set) var hasSettled = false
        /// Tells the latest wait for `hasSettled` from an older one whose result arrives late.
        public internal(set) var settleGeneration = 0
        /// A tap on the dimmed Save explained it, so the tip must not follow the alert.
        public internal(set) var saveTipSuppressed = false
        @Presents public var destination: Destination.State?

        /// A new workout starts with an empty stage in every section, as in the original app: a place to type into.
        public init(newWorkoutID: Workout.ID, warmUpStageID: Stage.ID, trainingStageID: Stage.ID, coolDownStageID: Stage.ID) {
            let workout = Workout(
                id: newWorkoutID,
                warmUp: [State.newStage(id: warmUpStageID)],
                training: [State.newStage(id: trainingStageID)],
                coolDown: [State.newStage(id: coolDownStageID)]
            )
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

        /// Longer than the push and the iOS 26 tab bar's glass settling, so the tip never points at a moving button.
        static let tipSettleDelay: Duration = .seconds(1)

        /// The rounds the editor offers: a workout without training rounds is not edited here.
        static let trainingRoundsRange = 1...WorkoutLimits.maxTrainingRounds

        /// Why Save is dimmed, when the user can do something about it.
        public enum SaveBlocker: Equatable, Sendable {
            /// The draft has no name or nothing to play.
            case incomplete
            /// A stage was changed so that it would not play: Save would drop it without a word.
            case unsavableStage
        }

        /// Judged on the comparable draft: spaces around a name, which a save trims, are no change.
        public var hasChanges: Bool {
            comparable(draft) != comparable(original)
        }

        /// A workout needs a name and something to play.
        public var isDraftComplete: Bool {
            !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.totalDuration > .zero
        }

        /// The draft's stages that would not play and differ from the same stage of the original. An untouched one
        /// the stored workout already had is saved without it as before, and a deleted one is gone either way.
        public var unsavableStageIDs: Set<Stage.ID> {
            let comparableOriginal = comparable(original)
            let originalStages = Dictionary(
                WorkoutSectionKind.allCases.flatMap { comparableOriginal[$0] }.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let comparableDraft = comparable(draft)
            let unsavable = WorkoutSectionKind.allCases
                .flatMap { comparableDraft[$0] }
                .filter { !WorkoutLimits.isPlayable($0) && originalStages[$0.id] != $0 }
            return Set(unsavable.map(\.id))
        }

        public var hasUnsavableStageEdits: Bool {
            !unsavableStageIDs.isEmpty
        }

        /// A new workout's Save waits for a change. A saved workout's Save is the way back to Start, as in the
        /// original app: untouched, it writes nothing and only ends the editing, even for a stored workout the editor
        /// would not accept as it is.
        public var canSave: Bool {
            !isSaving && (endsEditingUntouched || isDraftComplete && hasChanges && !hasUnsavableStageEdits)
        }

        /// What keeps Save dimmed, or `nil` when it is not dimmed or there is nothing to explain: read-only, saving,
        /// or a complete draft that only waits for a change.
        public var saveBlocker: SaveBlocker? {
            guard isEditable, !isSaving, !canSave else { return nil }

            if hasUnsavableStageEdits {
                return .unsavableStage
            }
            if !isDraftComplete {
                return .incomplete
            }
            return nil
        }

        /// The tip may point at the dimmed Save: there is a reason, the screen stands still, no alert is up, and a tap
        /// has not explained it already. The view adds that no field is focused.
        public var showsSaveTip: Bool {
            saveBlocker != nil && hasSettled && !saveTipSuppressed && destination == nil
        }

        /// The workout as Save would judge it: names without the spaces around them, and without the untouched empty
        /// stages the editor offers, which a save drops anyway. So deleting or moving one is no change either.
        func comparable(_ workout: Workout) -> Workout {
            var workout = workout
            workout.name = workout.name.trimmingCharacters(in: .whitespacesAndNewlines)
            for section in WorkoutSectionKind.allCases {
                workout[section] = workout[section]
                    .map { stage in
                        var stage = stage
                        stage.name = stage.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        return stage
                    }
                    .filter { !isUntouchedStarter($0) }
            }
            return workout
        }

        /// A stage the editor offered — a new workout's or one from «+» — still exactly as offered. A stored stage
        /// that the user emptied is not one: it was there before and is a change.
        private func isUntouchedStarter(_ stage: Stage) -> Bool {
            guard stage == Self.newStage(id: stage.id) else { return false }

            return phase == .new || !WorkoutSectionKind.allCases.contains { section in
                original[section].contains { $0.id == stage.id }
            }
        }

        private var endsEditingUntouched: Bool {
            phase == .editing && !hasChanges
        }

        /// The read-only screen plays the stored workout, once.
        public var canStart: Bool {
            phase == .viewing && workout.isPlayable && !isStarting
        }

        /// The same cells serve both phases: read-only they show what the stored workout plays, and the pencil
        /// turns them into the draft's controls, as the original app did.
        public var isEditable: Bool {
            phase != .viewing
        }

        /// The read-only screen's title: the stored name, or `nil` when it has none and the screen says so.
        public var viewingTitle: String? {
            workout.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : workout.name
        }

        /// A section's stages reorder while editing, when there are at least two to swap.
        public func canReorderStages(in section: WorkoutSectionKind) -> Bool {
            isEditable && !isSaving && draft[section].count > 1
        }

        /// The stages a section shows: the draft's while editing; while read-only, the ones that play.
        public func shownStages(in section: WorkoutSectionKind) -> [Stage] {
            guard !isEditable else { return draft[section] }

            return workout.duration(of: section) > .zero ? WorkoutLimits.normalizedStages(workout[section]) : []
        }

        /// A read-only screen leaves out a section that plays nothing.
        public func showsSection(_ section: WorkoutSectionKind) -> Bool {
            isEditable || !shownStages(in: section).isEmpty
        }

        public func shownDuration(of section: WorkoutSectionKind) -> Duration {
            isEditable ? draft.duration(of: section) : workout.duration(of: section)
        }

        public var shownTotalDuration: Duration {
            isEditable ? draft.totalDuration : workout.totalDuration
        }

        public var shownTrainingRounds: Int {
            isEditable ? draft.trainingRounds : WorkoutLimits.normalizedTrainingRounds(workout.trainingRounds)
        }

        /// While editing, a pause card offers its switch wherever the pause would play; read-only, only a pause
        /// that plays shows.
        public func showsPause(after section: WorkoutSectionKind) -> Bool {
            switch (section, isEditable) {
                case (.warmUp, true): draft.canPauseAfterWarmUp
                case (.warmUp, false): workout.pauseAfterWarmUp && workout.canPauseAfterWarmUp
                case (.training, true): draft.canPauseAfterTraining
                case (.training, false): workout.pauseAfterTraining && workout.canPauseAfterTraining
                case (.coolDown, _): false
            }
        }

        public func canAddStage(to section: WorkoutSectionKind) -> Bool {
            draft[section].count < WorkoutLimits.maxStagesPerSection
        }

        static func newStage(id: Stage.ID) -> Stage {
            Stage(id: id, name: "", duration: .zero, intensity: .work)
        }
    }

    public enum Action: ViewAction, Equatable, Sendable {
        case view(View)
        case `internal`(Internal)
        case delegate(Delegate)
        case destination(PresentationAction<Destination.Action>)

        @CasePathable
        public enum View: Equatable, Sendable {
            /// The screen appeared, changed its phase or let the keyboard go: its layout moves for a moment.
            case layoutChanged
            case nameChanged(String)
            /// The workout name's field lost focus.
            case nameFieldLeft
            /// A stage name's field lost focus.
            case stageNameFieldLeft(Stage.ID)
            case trainingRoundsChanged(Int)
            case pauseAfterWarmUpChanged(Bool)
            case pauseAfterTrainingChanged(Bool)
            case addStageButtonTapped(WorkoutSectionKind)
            case stageDeleteButtonTapped(WorkoutSectionKind, Stage.ID)
            case stagesMoved(WorkoutSectionKind, IndexSet, Int)
            case stageMovedUp(WorkoutSectionKind, Stage.ID)
            case stageMovedDown(WorkoutSectionKind, Stage.ID)
            case stageNameChanged(WorkoutSectionKind, Stage.ID, String)
            /// The duration's MM:SS text as typed; the draft takes its duration at once.
            case stageDurationTextChanged(WorkoutSectionKind, Stage.ID, String)
            case stageIntensityTapped(WorkoutSectionKind, Stage.ID)
            case backButtonTapped
            case saveButtonTapped
            /// A tap on the dimmed Save, which asks why it is dimmed.
            case saveBlockedTapped
            case editButtonTapped
            case startButtonTapped
        }

        @CasePathable
        public enum Internal: Equatable, Sendable {
            case saveFailed
            case saveSucceeded(Workout)
            case editingEnded
            case settled(generation: Int)
        }

        @CasePathable
        public enum Delegate: Equatable, Sendable {
            /// The workout exactly as it was written to storage.
            case saved(Workout)
            /// The workout exactly as it is stored, to play in the timer.
            case startRequested(Workout)
        }
    }

    private enum CancelID: Hashable, Sendable {
        case settle
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "WorkoutEditor")

    /// The pencil and a save switch the screen with the short curve of a collection view's batch update, as the
    /// original screen did; a spring's long settle would drag the rows after it.
    static let phaseChangeAnimation: Animation = .easeInOut(duration: 0.3)

    @Dependency(\.continuousClock) private var clock
    @Dependency(\.dismiss) private var dismiss
    @Dependency(\.saveTip) private var saveTip
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
                guard [.layoutChanged, .backButtonTapped, .editButtonTapped, .startButtonTapped].contains(action) else { return .none }
            case .new, .editing:
                guard action != .editButtonTapped, action != .startButtonTapped else { return .none }
        }

        switch action {
            case .layoutChanged:
                return settle(&state)
            case let .nameChanged(name):
                state.draft.name = WorkoutLimits.limitedName(name, previous: state.draft.name)
            case .nameFieldLeft:
                // A save trims names anyway; trimming the one just left shows it before Back or Save is judged.
                state.draft.name = state.draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            case let .stageNameFieldLeft(id):
                guard let section = WorkoutSectionKind.allCases.first(where: { section in
                    state.draft[section].contains { $0.id == id }
                }) else { return .none }

                updateStage(id, in: section, of: &state) { $0.name = $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
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

                state.draft[section].remove(at: index)
            case let .stagesMoved(section, source, destination):
                // Offsets come from the rows as they were drawn; stale ones would trap in `move`, so they are ignored.
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
                updateStage(id, in: section, of: &state) { $0.name = WorkoutLimits.limitedName(name, previous: $0.name) }
            case let .stageDurationTextChanged(section, id, text):
                updateStage(id, in: section, of: &state) { $0.duration = StageDurationText.duration(from: text) }
            case let .stageIntensityTapped(section, id):
                updateStage(id, in: section, of: &state) { $0.intensity = $0.intensity == .work ? .rest : .work }
            case .backButtonTapped:
                guard state.hasChanges else {
                    // The screen is going away; the tip must not show on it while it slides out.
                    state.hasSettled = false
                    return .run { [dismiss] _ in await dismiss() }
                }

                state.destination = .discardConfirmation(.discardChanges)
            case .saveButtonTapped:
                return save(&state)
            case .saveBlockedTapped:
                guard let blocker = state.saveBlocker else { return .none }

                // At once, in the state: the tip must not show when the alert closes, whenever TipKit takes the write.
                state.saveTipSuppressed = true
                state.destination = .saveBlockedAlert(.saveBlocked(blocker))
                return .run { [saveTip] _ in await saveTip.markExplained() }
            case .editButtonTapped:
                state.original = State.editable(state.workout)
                state.draft = state.original
                state.phase = .editing
                state.isStarting = false
            case .startButtonTapped:
                guard state.canStart else { return .none }

                // The container presents the timer and then empties the stack under it, so this screen goes away.
                // It refuses only an unplayable workout, which `canStart` excludes, or something already presented:
                // an alert is modal, so Start cannot be tapped under it, and a timer comes only from this flag's
                // first tap. The flag only blocks Start; Back keeps working.
                state.isStarting = true
                return .send(.delegate(.startRequested(state.workout)))
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
                endEditing(&state)
                return .send(.delegate(.saved(workout)))
            case .editingEnded:
                endEditing(&state)
                return .none
            case let .settled(generation):
                guard generation == state.settleGeneration else { return .none }

                state.hasSettled = true
                return .none
        }
    }

    /// Waits for the screen to stand still before the tip may show; every layout change starts over, and a wait it
    /// replaced may still deliver late, so the generation must match.
    private func settle(_ state: inout State) -> Effect<Action> {
        state.hasSettled = false
        state.settleGeneration += 1
        let generation = state.settleGeneration
        return .run { [clock] send in
            do {
                try await clock.sleep(for: State.tipSettleDelay)
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("The tip's settle clock failed: \(String(reflecting: error), privacy: .public)")
                return
            }
            await send(.internal(.settled(generation: generation)))
        }
        .cancellable(id: CancelID.settle, cancelInFlight: true)
    }

    private func endEditing(_ state: inout State) {
        state.original = State.editable(state.workout)
        state.draft = state.original
        state.phase = .viewing
    }

    private func discardChanges(_ state: State) -> Effect<Action> {
        // A save in flight must finish; dismissing would cancel it.
        guard !state.isSaving else { return .none }

        return .run { [dismiss] _ in await dismiss() }
    }

    private func save(_ state: inout State) -> Effect<Action> {
        guard state.canSave else { return .none }

        guard state.hasChanges else {
            state.destination = nil
            // The cells turn read-only in place, so the change animates like the pencil's.
            return .run { send in await send(.internal(.editingEnded), animation: Self.phaseChangeAnimation) }
        }

        // The draft stays as typed, so a failed save loses nothing; storage gets the normalized copy.
        let workout = Self.normalizedForSaving(state.draft)
        state.destination = nil
        state.isSaving = true
        return .run { [workoutStorage] send in
            do {
                try await workoutStorage.save(workout: workout)
                // The cells turn read-only in place, so the change animates like the pencil's.
                await send(.internal(.saveSucceeded(workout)), animation: Self.phaseChangeAnimation)
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

    static func saveBlocked(_ blocker: WorkoutEditorFeature.State.SaveBlocker) -> Self {
        AlertState {
            TextState("editor.saveBlocked.title", bundle: .module)
        } message: {
            switch blocker {
                case .incomplete: TextState("editor.saveHint", bundle: .module)
                case .unsavableStage: TextState("editor.saveBlocked.zeroStages", bundle: .module)
            }
        }
    }
}

// An alert, not a confirmation dialog: on iOS 26 the dialog becomes a popover that drops its Cancel button,
// leaving no way to answer "stay".
extension AlertState where Action == WorkoutEditorFeature.DiscardConfirmation {
    static var discardChanges: Self {
        AlertState {
            TextState("editor.discard.title", bundle: .module)
        } actions: {
            ButtonState(role: .destructive, action: .discard) {
                TextState("editor.discard.confirm", bundle: .module)
            }
            ButtonState(role: .cancel) {
                TextState("editor.discard.keepEditing", bundle: .module)
            }
        } message: {
            TextState("editor.discard.message", bundle: .module)
        }
    }
}
