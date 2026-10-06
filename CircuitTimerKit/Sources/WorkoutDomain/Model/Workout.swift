import Foundation

/// A workout as the user edits it. Only the training section repeats; warm-up and cool-down run once.
public struct Workout: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var warmUp: [Stage]
    public var training: [Stage]
    public var trainingRounds: Int
    public var coolDown: [Stage]
    /// Inserts a manual pause that waits for the user between warm-up and training.
    public var pauseAfterWarmUp: Bool
    /// Inserts a manual pause that waits for the user between training and cool-down.
    public var pauseAfterTraining: Bool

    public init(
        id: UUID,
        name: String = "",
        warmUp: [Stage] = [],
        training: [Stage] = [],
        trainingRounds: Int = 1,
        coolDown: [Stage] = [],
        pauseAfterWarmUp: Bool = false,
        pauseAfterTraining: Bool = false
    ) {
        self.id = id
        self.name = name
        self.warmUp = warmUp
        self.training = training
        self.trainingRounds = trainingRounds
        self.coolDown = coolDown
        self.pauseAfterWarmUp = pauseAfterWarmUp
        self.pauseAfterTraining = pauseAfterTraining
    }
}
