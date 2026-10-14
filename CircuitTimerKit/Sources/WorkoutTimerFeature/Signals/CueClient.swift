import ComposableArchitecture
import Foundation

public struct CueBurst: Equatable, Sendable {
    public let owner: UUID
    public let revision: Int
    public var tone: CueTone?
    public var announcement: StageAnnouncement?

    public init(owner: UUID, revision: Int, tone: CueTone? = nil, announcement: StageAnnouncement? = nil) {
        self.owner = owner
        self.revision = revision
        self.tone = tone
        self.announcement = announcement
    }
}

public struct CueOutputs: OptionSet, Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let tone = Self(rawValue: 1 << 0)
    public static let voice = Self(rawValue: 1 << 1)
    public static let announcement = Self(rawValue: 1 << 2)
}

public enum CueError: Error, Hashable, Sendable {
    case toneMissing
    case playerFailed
    case sessionFailed(code: Int)
    case voiceUnavailable(language: String)
}

public struct CueResult: Equatable, Sendable {
    public var outputs: CueOutputs
    public var failures: Set<CueError>

    public init(outputs: CueOutputs = [], failures: Set<CueError> = []) {
        self.outputs = outputs
        self.failures = failures
    }
}

@DependencyClient
public struct CueClient: Sendable {
    public var play: @Sendable (CueBurst) async throws -> CueResult
    public var suspend: @Sendable (_ owner: UUID, _ through: Int) async -> Void
    public var end: @Sendable (_ owner: UUID) async -> Void
}

extension CueClient: DependencyKey {
    public static let previewValue = Self(play: { _ in CueResult() }, suspend: { _, _ in }, end: { _ in })
    public static let testValue = Self()
}

extension DependencyValues {
    public var cues: CueClient {
        get { self[CueClient.self] }
        set { self[CueClient.self] = newValue }
    }
}
