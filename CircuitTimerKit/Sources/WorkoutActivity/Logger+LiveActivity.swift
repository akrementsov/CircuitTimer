import Foundation
import os

extension Logger {
    static let liveActivity = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "LiveActivity")
}
