struct HapticCue: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case countdown
        case stageStart
        case finish
    }

    let kind: Kind
    let revision: Int
}

enum CueFailure: Hashable, Sendable {
    case tone
    case session
    case voice
}
