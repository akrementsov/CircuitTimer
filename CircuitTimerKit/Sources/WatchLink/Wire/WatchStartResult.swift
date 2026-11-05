/// Admission to the iPhone's Start flow. Acceptance does not mean the timer has opened yet.
public enum WatchStartResult: Codable, Equatable, Sendable {
    case accepted(asksOnPhone: Bool)
    case openPhoneApp
    case busy
    case listUnavailable
    case changed
    case gone
    case notPlayable
}
