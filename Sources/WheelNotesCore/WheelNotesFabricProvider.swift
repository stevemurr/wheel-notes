import AppKit
import Fabric
import Foundation
import WheelSupport

public enum WheelNotesFabricIDs {
    public static let browser = "wheel.browser"
    public static let notes = "wheel.notes"
}

@MainActor
public protocol WheelNotesSession: AnyObject {
    var selectedWorkspaceID: UUID? { get }
    func allNotes() -> [NoteRecord]
    func noteRecord(id: UUID) -> NoteRecord?
    func createNote(title: String) -> NoteRecord?
    func appendPlainText(_ text: String, to noteID: UUID) -> NoteRecord?
    func openNote(id: UUID) -> NoteRecord?
}

@MainActor
public final class WheelNotesFabricProvider: FabricResourceProvider, FabricActionProvider, FabricSubscriptionProvider {
    public let appID = WheelNotesFabricIDs.notes

    private weak var session: (any WheelNotesSession)?

    public init(session: any WheelNotesSession) {
        self.session = session
    }

    public func listResources(query: String?) async throws -> [FabricResourceDescriptor] {
        guard let session else { return [] }

        let resources = session.allNotes().map { note in
            FabricResourceDescriptor(
                uri: noteURI(for: note.id),
                kind: "note",
                title: note.displayTitle,
                summary: note.excerpt,
                capabilities: [.read, .mention, .subscribe, .open],
                metadata: [
                    "workspaceID": .string(note.workspaceID.uuidString),
                    "noteID": .string(note.id.uuidString),
                ],
                presentation: .init(
                    systemImage: "note.text",
                    tint: "accent",
                    subtitle: note.excerpt,
                    categoryLabel: "Note"
                )
            )
        }

        guard let query, !query.isEmpty else { return resources }
        let loweredQuery = query.lowercased()

        return resources.filter { resource in
            [resource.title, resource.summary]
                .joined(separator: " ")
                .lowercased()
                .contains(loweredQuery)
        }
    }

    public func resolveContext(for uri: FabricURI) async throws -> FabricContextPayload? {
        guard uri.kind == "note",
              let noteID = UUID(uuidString: uri.id),
              let note = session?.noteRecord(id: noteID) else {
            return nil
        }

        return FabricContextPayload(
            uri: uri,
            kind: uri.kind,
            title: note.displayTitle,
            body: note.document.plainText(maxLength: Int.max),
            metadata: [
                "workspaceID": .string(note.workspaceID.uuidString),
                "noteID": .string(note.id.uuidString),
            ],
            presentation: .init(
                systemImage: "note.text",
                tint: "accent",
                subtitle: note.excerpt,
                categoryLabel: "Note"
            )
        )
    }

    public func listActions() async throws -> [FabricActionDescriptor] {
        [
            FabricActionDescriptor(
                id: "wheel.notes.create-note",
                appID: appID,
                name: "create-note",
                title: "Create Note",
                summary: "Create a new note in the selected WheelNotes workspace.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": "string",
                        "body": "string",
                    ],
                ],
                isMutation: true,
                requiresConfirmation: true
            ),
            FabricActionDescriptor(
                id: "wheel.notes.append-to-note",
                appID: appID,
                name: "append-to-note",
                title: "Append To Note",
                summary: "Append plaintext content to an existing Wheel note.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "noteURI": "string",
                        "content": "string",
                    ],
                ],
                isMutation: true,
                requiresConfirmation: true
            ),
            FabricActionDescriptor(
                id: "wheel.notes.open-note",
                appID: appID,
                name: "open-note",
                title: "Open Note",
                summary: "Open a Wheel note in the WheelNotes app.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "noteURI": "string",
                    ],
                ],
                isMutation: false,
                requiresConfirmation: false
            ),
        ]
    }

    public func invoke(_ invocation: FabricActionInvocation) async throws -> FabricActionResult {
        switch invocation.actionID {
        case "wheel.notes.create-note":
            let title = invocation.arguments["title"]?.stringValue ?? ""
            let body = invocation.arguments["body"]?.stringValue ?? ""
            guard let note = session?.createNote(title: title) else {
                throw FabricError.invalidURI("No workspace selected in WheelNotes")
            }

            let resolvedNote: NoteRecord
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let updated = session?.appendPlainText(body, to: note.id) {
                resolvedNote = updated
            } else {
                resolvedNote = note
            }

            let createdURI = noteURI(for: resolvedNote.id)
            return FabricActionResult(
                success: true,
                message: "Created note '\(resolvedNote.displayTitle)'",
                output: [
                    "noteURI": .string(createdURI.rawValue),
                    "title": .string(resolvedNote.displayTitle),
                ],
                createdResources: [createdURI]
            )

        case "wheel.notes.append-to-note":
            guard let noteURIString = invocation.arguments["noteURI"]?.stringValue,
                  let content = invocation.arguments["content"]?.stringValue else {
                throw FabricError.invalidURI("Missing noteURI or content")
            }

            let parsedURI = try FabricURI(string: noteURIString)
            guard parsedURI.appID == appID,
                  parsedURI.kind == "note",
                  let noteID = UUID(uuidString: parsedURI.id),
                  let note = session?.appendPlainText(content, to: noteID) else {
                throw FabricError.resourceNotFound(noteURIString)
            }

            let updatedURI = noteURI(for: note.id)
            return FabricActionResult(
                success: true,
                message: "Updated note '\(note.displayTitle)'",
                output: [
                    "noteURI": .string(updatedURI.rawValue),
                    "title": .string(note.displayTitle),
                ],
                updatedResources: [updatedURI]
            )

        case "wheel.notes.open-note":
            guard let noteURIString = invocation.arguments["noteURI"]?.stringValue else {
                throw FabricError.invalidURI("Missing noteURI")
            }

            let parsedURI = try FabricURI(string: noteURIString)
            guard parsedURI.appID == appID,
                  parsedURI.kind == "note",
                  let noteID = UUID(uuidString: parsedURI.id),
                  let note = session?.openNote(id: noteID) else {
                throw FabricError.resourceNotFound(noteURIString)
            }

            NSApp.activate(ignoringOtherApps: true)
            return FabricActionResult(
                success: true,
                message: "Opened note '\(note.displayTitle)'",
                output: [
                    "noteURI": .string(parsedURI.rawValue),
                    "title": .string(note.displayTitle),
                ]
            )

        default:
            throw FabricError.actionNotFound(invocation.actionID)
        }
    }

    public func validateSubscription(_ request: FabricSubscriptionRequest) async throws {
        if let requestedAppID = request.appID, requestedAppID != appID {
            throw FabricError.unsupportedSubscription("Wheel notes provider only supports \(appID)")
        }
    }

    public func noteEvent(for change: NoteStoreChange) -> FabricEvent {
        switch change {
        case .created(let note), .updated(let note):
            return FabricEvent(
                appID: appID,
                kind: .resourceUpdated,
                resourceURI: noteURI(for: note.id),
                resourceKind: "note",
                payload: [
                    "title": .string(note.displayTitle),
                    "workspaceID": .string(note.workspaceID.uuidString),
                    "noteID": .string(note.id.uuidString),
                ]
            )

        case .deleted(let noteID, let workspaceID):
            return FabricEvent(
                appID: appID,
                kind: .resourceRemoved,
                resourceURI: noteURI(for: noteID),
                resourceKind: "note",
                payload: [
                    "workspaceID": .string(workspaceID.uuidString),
                    "noteID": .string(noteID.uuidString),
                ]
            )
        }
    }

    private func noteURI(for noteID: UUID) -> FabricURI {
        FabricURI(appID: appID, kind: "note", id: noteID.uuidString)
    }
}

public extension NoteDocument {
    func appendingPlainText(_ text: String) -> NoteDocument {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return self }

        var updatedRoot = root
        var content = updatedRoot["content"]?.arrayValue ?? []

        for line in normalized.components(separatedBy: .newlines) {
            if line.isEmpty {
                content.append([
                    "type": AnyCodable("paragraph"),
                    "content": AnyCodable([]),
                ])
            } else {
                content.append([
                    "type": AnyCodable("paragraph"),
                    "content": AnyCodable([
                        [
                            "type": "text",
                            "text": line,
                        ],
                    ]),
                ])
            }
        }

        updatedRoot["content"] = AnyCodable(content)
        return NoteDocument(root: updatedRoot)
    }
}
