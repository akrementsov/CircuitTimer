import Foundation
import os

extension Logger {
    static let runRecord = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "RunRecord")
}
