import Foundation

public struct Stage: Identifiable, Hashable, Sendable {
    public enum Intensity: Hashable, Sendable, CaseIterable {
        case work
        case rest
    }

    public let id: UUID
    public var name: String
    public var duration: Duration
    public var intensity: Intensity

    public init(
        id: UUID,
        name: String,
        duration: Duration,
        intensity: Intensity
    ) {
        self.id = id
        self.name = name
        self.duration = duration
        self.intensity = intensity
    }
}
