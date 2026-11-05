import Foundation

/// The watch's selected schedule, handed to the iPhone app for admission to its ordinary Start flow.
public struct WatchStartRequest: Equatable, Sendable {
    public let id: Int
    public let workoutID: UUID
    public let scheduleFingerprint: String

    public init(id: Int, workoutID: UUID, scheduleFingerprint: String) {
        self.id = id
        self.workoutID = workoutID
        self.scheduleFingerprint = scheduleFingerprint
    }
}
