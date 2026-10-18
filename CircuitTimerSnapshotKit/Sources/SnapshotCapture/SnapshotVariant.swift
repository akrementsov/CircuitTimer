import Foundation
import SwiftUI
import Testing
import UIKit

public enum SnapshotLanguage: String, Sendable {
    case english = "en"
    case russian = "ru"

    public static func current() throws -> Self {
        let processLanguage = Locale.preferredLanguages.first.flatMap {
            Locale.Language(identifier: $0).languageCode?.identifier
        }
        let bundleLanguage = Bundle.main.preferredLocalizations.first.flatMap {
            Locale.Language(identifier: $0).languageCode?.identifier
        }
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
