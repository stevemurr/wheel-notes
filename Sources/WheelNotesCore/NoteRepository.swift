import Foundation
import WheelSupport

@MainActor
public final class NoteRepository {
    private let storageRoot: URL
    private let backend: FileSystemStoreBackend

    public init(
        storageRoot: URL = AppSupportPaths
            .directory(forAppNamed: "WheelNotes")
            .appendingPathComponent("Notes", isDirectory: true)
    ) {
        self.storageRoot = storageRoot
        self.backend = FileSystemStoreBackend(rootURL: storageRoot)
        try? FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
    }

    public func workspaceIDs() -> [UUID] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storageRoot.path),
              let urls = try? fileManager.contentsOfDirectory(
                at: storageRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            return UUID(uuidString: url.lastPathComponent)
        }
        .sorted { $0.uuidString < $1.uuidString }
    }

    public func notes(in workspaceID: UUID) -> [NoteRecord] {
        let store = noteStore(for: workspaceID)
        let keys: [StoreKey] = (try? store.keys()) ?? []
        var notes: [NoteRecord] = []

        for key in keys {
            guard let note = try? store.load(key: key) else {
                continue
            }
            notes.append(normalizedRecord(note))
        }

        return notes.sorted(by: Self.sortNotes(lhs:rhs:))
    }

    public func allNotes() -> [NoteRecord] {
        workspaceIDs()
            .flatMap(notes(in:))
            .sorted(by: Self.sortNotes(lhs:rhs:))
    }

    public func note(with id: UUID) -> NoteRecord? {
        for workspaceID in workspaceIDs() {
            if let note = note(with: id, workspaceID: workspaceID) {
                return note
            }
        }
        return nil
    }

    public func note(with id: UUID, workspaceID: UUID) -> NoteRecord? {
        let key = noteKey(for: id)
        guard let note = try? noteStore(for: workspaceID).load(key: key) else {
            return nil
        }
        return normalizedRecord(note)
    }

    public func save(_ note: NoteRecord) throws {
        try noteStore(for: note.workspaceID).save(note, for: noteKey(for: note.id))
    }

    public func delete(_ note: NoteRecord) throws {
        try noteStore(for: note.workspaceID).delete(key: noteKey(for: note.id))
    }

    private func noteStore(for workspaceID: UUID) -> JSONBackedDirectoryStore<NoteRecord> {
        JSONBackedDirectoryStore(
            backend: backend,
            namespace: StoreNamespace(workspaceID.uuidString),
            codingConfiguration: .prettyPrintedSortedKeysISO8601
        )
    }

    private func noteKey(for id: UUID) -> StoreKey {
        StoreKey("\(id.uuidString).json")
    }

    private func normalizedRecord(_ note: NoteRecord) -> NoteRecord {
        var normalized = note
        let migratedDocument = note.document.migratedForInlineTitle(note.title)
        normalized.document = migratedDocument
        normalized.title = migratedDocument.titleLine(maxLength: Int.max)
        normalized.excerpt = migratedDocument.previewText()
        return normalized
    }

    private static func sortNotes(lhs: NoteRecord, rhs: NoteRecord) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.createdAt > rhs.createdAt
    }
}
