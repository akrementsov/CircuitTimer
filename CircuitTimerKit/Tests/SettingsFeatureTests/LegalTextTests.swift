@testable import SettingsFeature

import Foundation
import Testing

@Suite
struct LegalTextTests {
    @Test
    func test_init_documentWithEveryBlock_keepsBlocksInOrderWithoutFrontMatterOrTitle() {
        let text = LegalText(markdown: """
        ---
        title: Privacy Policy
        lang: en
        ---

        # Privacy Policy

        Last updated: today

        ## On your device

        The app keeps:

        - your workouts;
        - your settings.

        ## Contact
        """)

        #expect(text.blocks == [
            .paragraph("Last updated: today"),
            .heading("On your device"),
            .paragraph("The app keeps:"),
            .bullet("your workouts;"),
            .bullet("your settings."),
            .heading("Contact"),
        ])
    }

    @Test
    func test_init_paragraphOverSeveralLines_joinsLinesWithSpaces() {
        let text = LegalText(markdown: "First line\nsecond line\n\nNext paragraph\n\n\n")

        #expect(text.blocks == [.paragraph("First line second line"), .paragraph("Next paragraph")])
    }

    @Test
    func test_init_textRightUnderHeading_startsParagraph() {
        let text = LegalText(markdown: "## Heading\nParagraph\n- bullet\ncontinued")

        #expect(text.blocks == [.heading("Heading"), .paragraph("Paragraph"), .bullet("bullet continued")])
    }

    @Test
    func test_init_linkAndBold_keepsThemAsAttributes() throws {
        let text = LegalText(markdown: "Write to [me](mailto:me@example.com), **now**.")

        let paragraph = try #require(text.blocks.first.flatMap(\.text))
        #expect(String(paragraph.characters) == "Write to me, now.")
        let link = try #require(paragraph.runs.first { $0.link != nil })
        #expect(link.link == URL(string: "mailto:me@example.com"))
        #expect(String(paragraph[link.range].characters) == "me")
        let bold = try #require(paragraph.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized })
        #expect(String(paragraph[bold.range].characters) == "now")
    }

    @Test
    func test_init_bracketWithoutLink_keepsTheBracket() throws {
        let text = LegalText(markdown: "A [link without its end")

        let paragraph = try #require(text.blocks.first.flatMap(\.text))
        #expect(String(paragraph.characters) == "A [link without its end")
    }

    @Test
    func test_localization_preferredList_takesItsFirstOrEnglish() {
        #expect(LegalDocument.localization(["ru", "en"]) == "ru")
        #expect(LegalDocument.localization(["en"]) == "en")
        #expect(LegalDocument.localization([]) == "en")
    }

    @Test(arguments: LegalDocument.allCases)
    func test_load_eachBundledLanguage_readsHeadingsWithoutEmptyBlocks(document: LegalDocument) throws {
        let english = try #require(document.load(localization: "en"))
        let russian = try #require(document.load(localization: "ru"))

        for text in [english, russian] {
            #expect(text.blocks.contains { if case .heading = $0 { true } else { false } })
            #expect(text.blocks.allSatisfy { $0.text.map { !$0.characters.isEmpty } ?? false })
        }
        #expect(english != russian)
    }

    @Test
    func test_load_unknownLocalization_returnsNil() {
        #expect(LegalDocument.privacyPolicy.load(localization: "xx") == nil)
    }

    @Test(arguments: ["en", "ru"])
    func test_load_privacyPolicy_endsWithLinkToItsPublicPage(localization: String) throws {
        let text = try #require(LegalDocument.privacyPolicy.load(localization: localization))

        let last = try #require(text.blocks.last?.text)
        let links = last.runs.compactMap(\.link)
        #expect(links.contains { $0.absoluteString.hasPrefix("https://akrementsov.github.io/CircuitTimer/legal/") })
    }
}

private extension LegalText.Block {
    var text: AttributedString? {
        switch self {
            case let .heading(text), let .paragraph(text), let .bullet(text):
                text
        }
    }
}
