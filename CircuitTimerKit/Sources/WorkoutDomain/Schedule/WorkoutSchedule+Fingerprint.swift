import CryptoKit
import Foundation

extension WorkoutSchedule {
    /// Hex SHA-256 of the canonical string
    /// `"v1|" + stages.map { "index:section:round/roundCount:kind:stageID-or--:durationMs" }.joined(separator: ",")`.
    ///
    /// A saved run is dropped when the rebuilt schedule's fingerprint differs. Names are left out,
    /// so renaming a stage keeps the run; tokens are spelled out, so renaming a case changes nothing
    /// that is stored. Hashed piece by piece: a schedule at the limits would build a string of
    /// hundreds of kilobytes.
    static func fingerprint(of stages: [ScheduledStage]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("v1|".utf8))
        for stage in stages {
            let separator = stage.index == 0 ? "" : ","
            let piece = "\(separator)\(stage.index):\(stage.section.fingerprintToken):\(stage.round)/\(stage.roundCount):"
                + "\(stage.kind.fingerprintToken):\(stage.stageID?.uuidString ?? "-"):\(stage.duration.inMilliseconds)"
            hasher.update(data: Data(piece.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension WorkoutSectionKind {
    var fingerprintToken: String {
        switch self {
            case .warmUp: "warmUp"
            case .training: "training"
            case .coolDown: "coolDown"
        }
    }
}

private extension ScheduledStage.Kind {
    var fingerprintToken: String {
        switch self {
            case .work: "work"
            case .rest: "rest"
            case .pause: "pause"
        }
    }
}
