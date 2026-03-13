import Foundation
import Testing
import WheelSupport
@testable import WheelNotesCore

@Suite("NoteDocument")
struct NoteModelsTests {
    @Test("Title and preview derive from the first line of the document")
    func extractsInlineTitleAndPreview() {
        let document = NoteDocument(
            root: [
                "type": AnyCodable("doc"),
                "content": AnyCodable([
                    [
                        "type": "paragraph",
                        "content": [
                            [
                                "type": "text",
                                "text": "Project plan",
                            ],
                        ],
                    ],
                    [
                        "type": "paragraph",
                        "content": [
                            [
                                "type": "text",
                                "text": "Ship the editor cleanup next.",
                            ],
                        ],
                    ],
                ]),
            ]
        )

        #expect(document.titleLine() == "Project plan")
        #expect(document.previewText() == "Ship the editor cleanup next.")
    }

    @Test("Legacy title metadata can migrate into the note body")
    func migratesLegacyTitlesIntoBody() throws {
        let document = NoteDocument.empty.migratedForInlineTitle("Scratchpad")

        #expect(document.titleLine() == "Scratchpad")

        let content = try #require(document.root["content"]?.arrayValue)
        let firstNode = try #require(content.first as? [String: Any])
        #expect(firstNode["type"] as? String == "paragraph")
    }

    @Test("Page sources replace the empty starter paragraph instead of adding leading blank space")
    func sourceInsertionIntoEmptyDocumentIsCompact() throws {
        let document = NoteDocument.empty.insertingPageSource(
            NotePageSource(title: "Wheel Docs", url: "https://example.com/docs", capturedAt: Date(timeIntervalSince1970: 0))
        )

        let content = try #require(document.root["content"]?.arrayValue)
        #expect(content.count == 2)

        let firstNode = try #require(content.first as? [String: Any])
        let secondNode = try #require(content.last as? [String: Any])

        #expect(firstNode["type"] as? String == "pageSource")
        #expect(secondNode["type"] as? String == "paragraph")
    }

    @Test("Page sources do not add duplicate spacer paragraphs when the note already ends with one")
    func sourceInsertionAvoidsDuplicateTrailingSpacer() throws {
        let document = NoteDocument(
            root: [
                "type": AnyCodable("doc"),
                "content": AnyCodable([
                    [
                        "type": "paragraph",
                        "content": [
                            [
                                "type": "text",
                                "text": "Existing note",
                            ],
                        ],
                    ],
                    [
                        "type": "paragraph",
                        "content": [],
                    ],
                ]),
            ]
        ).insertingPageSource(
            NotePageSource(title: "Wheel Docs", url: "https://example.com/docs", capturedAt: Date(timeIntervalSince1970: 0))
        )

        let content = try #require(document.root["content"]?.arrayValue)
        #expect(content.count == 4)

        let thirdNode = try #require(content[2] as? [String: Any])
        #expect(thirdNode["type"] as? String == "pageSource")
    }

    @Test("Canonical JSON stays stable when equivalent document keys are ordered differently")
    func canonicalJSONStringNormalizesKeyOrdering() {
        let first = NoteDocument(
            root: [
                "type": AnyCodable("doc"),
                "content": AnyCodable([
                    [
                        "type": "paragraph",
                        "attrs": [
                            "level": 2,
                            "kind": "section",
                        ],
                        "content": [
                            [
                                "type": "text",
                                "text": "Roadmap",
                            ],
                        ],
                    ],
                ]),
            ]
        )

        let second = NoteDocument(
            root: [
                "content": AnyCodable([
                    [
                        "content": [
                            [
                                "text": "Roadmap",
                                "type": "text",
                            ],
                        ],
                        "attrs": [
                            "kind": "section",
                            "level": 2,
                        ],
                        "type": "paragraph",
                    ],
                ]),
                "type": AnyCodable("doc"),
            ]
        )

        #expect(first.canonicalJSONString == second.canonicalJSONString)
    }

    @Test("Link cards contribute their title and URL to note text extraction")
    func extractsTitleAndPreviewFromLinkCards() {
        let document = NoteDocument(
            root: [
                "type": AnyCodable("doc"),
                "content": AnyCodable([
                    [
                        "type": "linkCard",
                        "attrs": [
                            "title": "Product Notes",
                            "url": "https://www.example.com/product/notes?view=full#section",
                        ],
                    ],
                    [
                        "type": "paragraph",
                        "content": [
                            [
                                "type": "text",
                                "text": "Need to refine the editor card copy.",
                            ],
                        ],
                    ],
                ]),
            ]
        )

        #expect(document.titleLine() == "Product Notes")
        #expect(document.previewText() == "example.com/product/notes…\nNeed to refine the editor card copy.")
    }
}
