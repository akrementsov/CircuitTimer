import ComposableArchitecture
import Foundation
import os

final class TimerPreferenceTrace: NSObject, @unchecked Sendable {
    private static let keys = [
        "signalSound", "signalVibration", "signalSpokenStageNames",
        "signalBackgroundNotifications", "timerKeepScreenOn",
    ]
    private static let logger = Logger(subsystem: "CircuitTimer.CT16", category: "suite")

    private let defaults: UserDefaults
    private let label: String
    private let events = LockIsolated<[String]>([])
    private let suiteName: String

    init(_ defaults: UserDefaults, label: String) {
        self.defaults = defaults
        self.label = label
        let selector = Selector(("_identifier"))
        if defaults.responds(to: selector),
           let identifier = defaults.perform(selector)?.takeUnretainedValue() as? String {
            suiteName = identifier
        } else {
            suiteName = "unavailable"
        }
        super.init()
        for key in Self.keys {
            defaults.addObserver(self, forKeyPath: key, options: [.old, .new], context: nil)
        }
        mark("begin")
    }

    deinit {
        for key in Self.keys {
            defaults.removeObserver(self, forKeyPath: key)
        }
    }

    // Preference keys are dynamic strings and have no Swift key paths.
    // swiftlint:disable:next block_based_kvo
    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        let old = String(describing: change?[.oldKey])
        let new = String(describing: change?[.newKey])
        let stack = Thread.callStackSymbols.prefix(40).joined(separator: " > ")
        mark("KVO key=\(keyPath ?? "nil") old=\(old) new=\(new) stack=\(stack)")
    }

    func mark(_ message: String) {
        let entry = events.withValue { entries in
            let entry = "\(entries.count) t=\(ProcessInfo.processInfo.systemUptime) main=\(Thread.isMainThread) \(message)"
            entries.append(entry)
            return entry
        }
        Self.logger.notice("CT16_SUITE test=\(self.label, privacy: .public) store=\(String(describing: ObjectIdentifier(self.defaults)), privacy: .public) suite=\(self.suiteName, privacy: .public) \(entry, privacy: .public)")
    }

    var report: String {
        "test=\(label) store=\(ObjectIdentifier(defaults)) suite=\(suiteName)\n"
            + events.withValue { $0.joined(separator: "\n") }
    }
}
