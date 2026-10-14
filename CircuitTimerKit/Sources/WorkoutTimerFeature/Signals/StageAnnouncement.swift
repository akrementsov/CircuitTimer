import Foundation
import WorkoutDomain

public enum StageAnnouncement: Equatable, Sendable {
    case named(String)
    case work
    case rest
    case pause

    init(stage: ScheduledStage) {
        let name = stage.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty {
            self = .named(name)
            return
        }
        switch stage.kind {
            case .work: self = .work
            case .rest: self = .rest
            case .pause: self = .pause
        }
    }

    var text: String {
        switch self {
            case let .named(name): name
            case .work: String(localized: "work", table: "Speech", bundle: .module)
            case .rest: String(localized: "rest", table: "Speech", bundle: .module)
            case .pause: String(localized: "pause", table: "Speech", bundle: .module)
        }
    }
}
