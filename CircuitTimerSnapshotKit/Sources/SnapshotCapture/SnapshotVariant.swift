import Foundation
import SwiftUI
import Testing
import UIKit

public enum SnapshotLanguage: String, Sendable {
    case english = "en"
    case russian = "ru"

    static func languageCode(in preferredLanguages: [String]) -> String? {
        preferredLanguages.first.flatMap {
            Locale.Language(identifier: $0).languageCode?.identifier
        }
    }

    public static func current() throws -> Self {
        let processLanguage = languageCode(in: Locale.preferredLanguages)
        let bundleLanguage = languageCode(in: Bundle.main.preferredLocalizations)
        guard let processLanguage, let language = Self(rawValue: processLanguage),
              bundleLanguage == processLanguage else {
            throw LanguageError(process: processLanguage, bundle: bundleLanguage)
        }
        return language
    }

    private struct LanguageError: Error, CustomStringConvertible {
        let process: String?
        let bundle: String?

        var description: String {
            "Snapshot language must be en or ru and match the host localization "
                + "(process: \(process ?? "missing"), bundle: \(bundle ?? "missing")). "
                + ProcessInfo.processInfo.operatingSystemVersionString
        }
    }
}

public enum SnapshotTextSize: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case large
    case ax5

    public var testDescription: String { rawValue }

    public static func currentCases(in sizes: [Self] = Self.allCases) -> [Self] {
        guard let value = ProcessInfo.processInfo.environment["SNAPSHOT_TEXT_SIZE"], let selected = Self(rawValue: value) else {
            // Keep tests discoverable so a missing launch configuration fails instead of silently skipping them.
            return sizes
        }
        return sizes.filter { $0 == selected }
    }

    @MainActor
    func validateProcess() throws {
        let selected = ProcessInfo.processInfo.environment["SNAPSHOT_TEXT_SIZE"] ?? "missing"
        let actual = UIApplication.shared.preferredContentSizeCategory
        guard selected == rawValue, actual == contentSizeCategory else {
            throw SnapshotCaptureFailure(
                "Snapshot text size must match its process (argument: \(rawValue), selected: \(selected), "
                    + "process: \(actual.rawValue), expected: \(contentSizeCategory.rawValue)). Use make test-snapshots."
            )
        }
    }

    public var dynamicTypeSize: DynamicTypeSize {
        switch self {
            case .large: .large
            case .ax5: .accessibility5
        }
    }

    public var contentSizeCategory: UIContentSizeCategory {
        switch self {
            case .large: .large
            case .ax5: .accessibilityExtraExtraExtraLarge
        }
    }
}

public struct SnapshotVariant: Sendable {
    public let language: SnapshotLanguage
    public let textSize: SnapshotTextSize

    public init(language: SnapshotLanguage, textSize: SnapshotTextSize) {
        self.language = language
        self.textSize = textSize
    }

    public var name: String { "\(language.rawValue)-\(textSize.rawValue)" }
    public var locale: Locale { Locale(identifier: language.rawValue) }
    public var dynamicTypeSize: DynamicTypeSize { textSize.dynamicTypeSize }

    @MainActor
    public func traits(over base: UITraitCollection) -> UITraitCollection {
        base.modifyingTraits {
            $0.userInterfaceStyle = .dark
            $0.preferredContentSizeCategory = textSize.contentSizeCategory
            $0.displayScale = SnapshotViewport.scale
        }
    }
}
