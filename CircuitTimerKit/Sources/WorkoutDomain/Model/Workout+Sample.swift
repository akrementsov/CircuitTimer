import Foundation

// TODO: [CT-2] Move to a preview/test support target once storage is backed by SwiftData.
extension Workout {
    public static let sample = Workout(
        id: UUID(sample: 0),
        name: "Morning HIIT",
        warmUp: [
            Stage(id: UUID(sample: 1), name: "Jumping jacks", duration: .seconds(60), intensity: .work),
            Stage(id: UUID(sample: 2), name: "Arm circles", duration: .seconds(30), intensity: .rest),
        ],
        training: [
            Stage(id: UUID(sample: 3), name: "Burpees", duration: .seconds(40), intensity: .work),
            Stage(id: UUID(sample: 4), name: "Rest", duration: .seconds(20), intensity: .rest),
            Stage(id: UUID(sample: 5), name: "Squats", duration: .seconds(40), intensity: .work),
            Stage(id: UUID(sample: 6), name: "Rest", duration: .seconds(20), intensity: .rest),
        ],
        trainingRounds: 3,
        coolDown: [
            Stage(id: UUID(sample: 7), name: "Stretching", duration: .seconds(120), intensity: .rest),
        ],
        pauseAfterWarmUp: true
    )
}

private extension UUID {
    /// Deterministic identifiers keep previews and snapshots stable.
    init(sample index: UInt8) {
        self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, index))
    }
}
