import Foundation
import os

extension Logger {
    static let designSystem = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "DesignSystem")
}
