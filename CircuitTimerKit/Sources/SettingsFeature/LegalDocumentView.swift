import DesignSystem
import Foundation
import os
import SwiftUI

public enum LegalDocument: Hashable, Sendable, CaseIterable {
    case privacyPolicy
    case termsOfUse
}

/// A legal page: the bundled copy of its text in `docs/legal`, in the language the rest of the module shows.
struct LegalDocumentView: View {
    let document: LegalDocument

    @State private var content: Content = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .token(spacing: .m)) {
                switch content {
                    case .loading:
                        EmptyView()
                    case let .loaded(text):
                        ForEach(Array(text.blocks.enumerated()), id: \.offset) { _, block in
                            LegalBlockView(block: block)
                        }
                    case .failed:
                        Text("legal.loadFailed", bundle: .module)
                            .font(.token(.body))
                            .foregroundStyle(.text(.secondary))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, .token(spacing: .l))
        }
        .contentMargins(.vertical, .token(spacing: .l), for: .scrollContent)
        .navigationTitle(document.title)
        .screenChrome()
        .task(id: document) {
            let localization = LegalDocument.localization(Bundle.module.preferredLocalizations)
            content = document.load(localization: localization).map(Content.loaded) ?? .failed
        }
    }

    private enum Content: Equatable {
        case loading
        case loaded(LegalText)
        case failed
    }
}

private struct LegalBlockView: View {
    let block: LegalText.Block

    var body: some View {
        switch block {
            case let .heading(text):
                Text(text)
                    .font(.token(.headline))
                    .foregroundStyle(.text(.primary))
                    .padding(.top, .token(spacing: .s))
                    .accessibilityAddTraits(.isHeader)
            case let .paragraph(text):
                Text(text)
                    .font(.token(.body))
                    .foregroundStyle(.text(.primary))
            case let .bullet(text):
                HStack(alignment: .firstTextBaseline, spacing: .token(spacing: .xs)) {
                    Text(verbatim: "•")
                        .accessibilityHidden(true)
                    Text(text)
                }
                .font(.token(.body))
                .foregroundStyle(.text(.primary))
        }
    }
}

extension LegalDocument {
    var title: Text {
        switch self {
            case .privacyPolicy:
                Text("about.privacyPolicy", bundle: .module)
            case .termsOfUse:
                Text("about.termsOfUse", bundle: .module)
        }
    }

    /// The localization to read: the first of the bundle's own choice, which its string catalog follows too.
    static func localization(_ preferred: [String]) -> String {
        preferred.first ?? "en"
    }

    /// The bundled text in `localization`, or nil, logged, when it is missing or unreadable.
    func load(localization: String, bundle: Bundle = .module) -> LegalText? {
        let url = bundle.url(
            forResource: resourceName,
            withExtension: "md",
            subdirectory: nil,
            localization: localization
        )
        guard let url else {
            Self.logger.error("No \(resourceName, privacy: .public).md for \(localization, privacy: .public)")
            return nil
        }
        do {
            return LegalText(markdown: try String(contentsOf: url, encoding: .utf8))
        } catch {
            Self.logger.error("\(resourceName, privacy: .public).md unreadable: \(error)")
            return nil
        }
    }

    private var resourceName: String {
        switch self {
            case .privacyPolicy:
                "PrivacyPolicy"
            case .termsOfUse:
                "TermsOfUse"
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer",
        category: "LegalDocument"
    )
}
