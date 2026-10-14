import Foundation

public enum CueTone: String, CaseIterable, Sendable {
    case countdown = "cue-countdown"
    case stageStart = "cue-stage-start"
    case finish = "cue-finish"

    var url: URL? {
        Bundle.module.url(forResource: rawValue, withExtension: "wav")
    }
}
