import Foundation
import Testing
import WheelSupport
@testable import WheelNotesCore

@Suite("NoteStore", .serialized)
@MainActor
struct NoteStoreTests {
    @Test("Creating notes yields distinct records")
    func createsDistinctNotes() {
        let store = makeStore()
        let workspaceID = UUID()
        store.bindToWorkspace(workspaceID)

        let first = store.createNote(title: "First")
        let second = store.createNote(title: "Second")

        #expect(first.id != second.id)
        #expect(store.notes.count == 2)
    }

    @Test("Notes persist and reload")
    func persistsAndReloadsNotes() throws {
        let root = tempDirectory()
        let workspaceID = UUID()

        let store = NoteStore(storageRoot: root, saveDebounceInterval: .seconds(60))
        store.bindToWorkspace(workspaceID)
        let first = store.createNote(title: "Ideas")
        let second = store.createNote(title: "Research")
        store.updateDocument(
            id: second.id,
            document: NoteDocument(
                root: [
                    "type": AnyCodable("doc"),
                    "content": AnyCodable([
                        [
                            "type": "paragraph",
                            "content": [
                                [
                                    "type": "text",
                                    "text": "Track launch notes",
                                ],
                            ],
                        ],
                    ]),
                ]
            )
        )
        store.flushPendingSaves()

        let reloaded = NoteStore(storageRoot: root, saveDebounceInterval: .seconds(60))
        reloaded.bindToWorkspace(workspaceID)

        #expect(reloaded.notes.count == 2)
        #expect(reloaded.note(with: first.id) != nil)
        let savedSecond = try #require(reloaded.note(with: second.id))
        #expect(savedSecond.title == "Track launch notes")
        #expect(savedSecond.excerpt.isEmpty)
    }

    @Test("Workspace binding isolates note collections")
    func isolatesWorkspaces() {
        let store = makeStore()
        let workspaceA = UUID()
        let workspaceB = UUID()

        store.bindToWorkspace(workspaceA)
        let noteA = store.createNote(title: "A")
        store.flushPendingSaves()

        store.bindToWorkspace(workspaceB)
        _ = store.createNote(title: "B")
        store.flushPendingSaves()

        store.bindToWorkspace(workspaceA)

        #expect(store.notes.count == 1)
        #expect(store.notes.first?.id == noteA.id)
    }

    @Test("Source insertion updates excerpt and persists")
    func insertsPageSource() throws {
        let root = tempDirectory()
        let store = NoteStore(storageRoot: root, saveDebounceInterval: .seconds(60))
        let workspaceID = UUID()
        store.bindToWorkspace(workspaceID)
        let note = store.createNote(title: "Research")

        store.insertPageSource(
            id: note.id,
            source: NotePageSource(title: "Wheel Docs", url: "https://example.com/docs")
        )
        store.flushPendingSaves()

        let reloaded = NoteStore(storageRoot: root, saveDebounceInterval: .seconds(60))
        reloaded.bindToWorkspace(workspaceID)

        let updated = try #require(reloaded.note(with: note.id))
        #expect(updated.title == "Research")
        #expect(updated.excerpt.contains("Wheel Docs"))
        #expect(updated.excerpt.contains("https://example.com/docs"))
    }

    @Test("Document updates use the first line as the note title")
    func derivesTitleFromDocument() {
        let store = makeStore()
        let workspaceID = UUID()
        store.bindToWorkspace(workspaceID)

        let note = store.createNote()
        store.updateDocument(
            id: note.id,
            document: NoteDocument(
                root: [
                    "type": AnyCodable("doc"),
                    "content": AnyCodable([
                        [
                            "type": "paragraph",
                            "content": [
                                [
                                    "type": "text",
                                    "text": "Release notes",
                                ],
                            ],
                        ],
                        [
                            "type": "paragraph",
                            "content": [
                                [
                                    "type": "text",
                                    "text": "Tighten slash commands and task styling.",
                                ],
                            ],
                        ],
                    ]),
                ]
            )
        )

        let updated = try! #require(store.note(with: note.id))
        #expect(updated.title == "Release notes")
        #expect(updated.excerpt == "Tighten slash commands and task styling.")
    }

    @Test("Equivalent document updates do not bump note timestamps")
    func ignoresEquivalentDocumentUpdates() throws {
        let store = makeStore()
        let workspaceID = UUID()
        store.bindToWorkspace(workspaceID)

        let note = store.createNote()
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
                                "text": "Release notes",
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
                                "text": "Release notes",
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

        store.updateDocument(id: note.id, document: first)
        let updated = try #require(store.note(with: note.id))
        let firstUpdatedAt = updated.updatedAt

        store.updateDocument(id: note.id, document: second)
        let resolved = try #require(store.note(with: note.id))

        #expect(resolved.updatedAt == firstUpdatedAt)
        #expect(resolved.title == "Release notes")
    }

    @Test("Duplicating a note copies the full document into a new record")
    func duplicatesNote() {
        let store = makeStore()
        let workspaceID = UUID()
        store.bindToWorkspace(workspaceID)

        let note = store.createNote()
        store.updateDocument(
            id: note.id,
            document: NoteDocument(
                root: [
                    "type": AnyCodable("doc"),
                    "content": AnyCodable([
                        [
                            "type": "paragraph",
                            "content": [
                                [
                                    "type": "text",
                                    "text": "Design review",
                                ],
                            ],
                        ],
                        [
                            "type": "paragraph",
                            "content": [
                                [
                                    "type": "text",
                                    "text": "Compare note duplication and deletion flows.",
                                ],
                            ],
                        ],
                    ]),
                ]
            )
        )

        let duplicated = try! #require(store.duplicateNote(id: note.id))
        let resolved = try! #require(store.note(with: duplicated.id))

        #expect(resolved.id != note.id)
        #expect(resolved.document.plainText(maxLength: Int.max) == "Design review\nCompare note duplication and deletion flows.")
        #expect(resolved.title == "Design review")
    }

    @Test("Deleting a note removes it from memory and disk")
    func deletesNote() throws {
        let root = tempDirectory()
        let workspaceID = UUID()
        let store = NoteStore(storageRoot: root, saveDebounceInterval: .seconds(60))
        store.bindToWorkspace(workspaceID)

        let note = store.createNote(title: "Disposable")
        store.flushPendingSaves()
        store.deleteNote(id: note.id)

        let fileURL = root
            .appendingPathComponent(workspaceID.uuidString, isDirectory: true)
            .appendingPathComponent("\(note.id.uuidString).json")

        #expect(store.note(with: note.id) == nil)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    @Test("Ordered notes prioritize the most recently updated note")
    func ordersNotesByRecentActivity() {
        let store = makeStore()
        let workspaceID = UUID()
        store.bindToWorkspace(workspaceID)

        let older = store.createNote(title: "Older")
        let newer = store.createNote(title: "Newer")
        store.updateDocument(
            id: older.id,
            document: NoteDocument(
                root: [
                    "type": AnyCodable("doc"),
                    "content": AnyCodable([
                        [
                            "type": "paragraph",
                            "content": [
                                [
                                    "type": "text",
                                    "text": "Fresh note",
                                ],
                            ],
                        ],
                    ]),
                ]
            )
        )

        let ordered = store.orderedNotes
        #expect(ordered.first?.id == older.id)
        #expect(ordered.contains { $0.id == newer.id })
    }

    private func makeStore() -> NoteStore {
        NoteStore(storageRoot: tempDirectory(), saveDebounceInterval: .seconds(60))
    }

    private func tempDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
