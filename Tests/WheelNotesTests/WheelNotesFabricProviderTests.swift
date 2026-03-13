import Fabric
import Foundation
import Testing
@testable import WheelNotesCore

@MainActor
@Suite("Wheel notes Fabric provider")
struct WheelNotesFabricProviderTests {
    @Test("Create and append actions mutate note resources")
    func createAndAppendNote() async throws {
        let session = WheelNotesSessionStub()
        let provider = WheelNotesFabricProvider(session: session)

        let created = try await provider.invoke(
            FabricActionInvocation(
                actionID: "wheel.notes.create-note",
                arguments: [
                    "title": .string("Architecture notes"),
                    "body": .string("Capture Fabric-backed notes."),
                ]
            )
        )

        let createdURIString = try #require(created.output["noteURI"]?.stringValue)
        let createdURI = try FabricURI(string: createdURIString)

        #expect(created.success)
        #expect(created.createdResources == [createdURI])

        let appended = try await provider.invoke(
            FabricActionInvocation(
                actionID: "wheel.notes.append-to-note",
                arguments: [
                    "noteURI": .string(createdURIString),
                    "content": .string("Workspace aware."),
                ]
            )
        )

        #expect(appended.success)
        #expect(appended.updatedResources == [createdURI])
        #expect(session.noteRecord(id: UUID(uuidString: createdURI.id)!)?.document.plainText(maxLength: Int.max).contains("Workspace aware.") == true)
    }

    @Test("Note resources include workspace metadata")
    func listsWorkspaceScopedNoteResources() async throws {
        let session = WheelNotesSessionStub()
        let note = session.createNote(title: "Roadmap")!
        let provider = WheelNotesFabricProvider(session: session)

        let resources = try await provider.listResources(query: nil)
        let resource = try #require(resources.first { $0.uri.id == note.id.uuidString })

        #expect(resource.kind == "note")
        #expect(resource.metadata["workspaceID"]?.stringValue == session.selectedWorkspaceID?.uuidString)
        #expect(resource.capabilities.contains(.mention))
    }
}

@MainActor
private final class WheelNotesSessionStub: WheelNotesSession {
    var selectedWorkspaceID: UUID? = UUID()

    private var orderedNoteIDs: [UUID] = []
    private var notesByID: [UUID: NoteRecord] = [:]

    func allNotes() -> [NoteRecord] {
        orderedNoteIDs.compactMap { notesByID[$0] }
    }

    func noteRecord(id: UUID) -> NoteRecord? {
        notesByID[id]
    }

    func createNote(title: String) -> NoteRecord? {
        guard let workspaceID = selectedWorkspaceID else { return nil }
        let document = NoteDocument.titled(title)
        let note = NoteRecord(
            workspaceID: workspaceID,
            kind: .adhoc,
            title: document.titleLine(maxLength: Int.max),
            excerpt: document.previewText(),
            document: document
        )
        notesByID[note.id] = note
        orderedNoteIDs.append(note.id)
        return note
    }

    func appendPlainText(_ text: String, to noteID: UUID) -> NoteRecord? {
        guard var note = notesByID[noteID] else { return nil }
        note.document = note.document.appendingPlainText(text)
        note.title = note.document.titleLine(maxLength: Int.max)
        note.excerpt = note.document.previewText()
        note.updatedAt = Date()
        notesByID[noteID] = note
        return note
    }

    func openNote(id: UUID) -> NoteRecord? {
        notesByID[id]
    }
}
