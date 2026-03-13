import Foundation
import Observation
import WheelSupport

public enum NoteStoreChange {
    case created(NoteRecord)
    case updated(NoteRecord)
    case deleted(id: UUID, workspaceID: UUID)
}

@MainActor
@Observable
public final class NoteStore {
    public private(set) var notes: [NoteRecord] = []
    public private(set) var currentWorkspaceID: UUID?

    @ObservationIgnored private let repository: NoteRepository
    @ObservationIgnored private let saveScheduler: StoreSaveScheduler
    @ObservationIgnored private var dirtyNoteIDs: Set<UUID> = []
    @ObservationIgnored public var changeHandler: ((NoteStoreChange) -> Void)?

    public init(
        storageRoot: URL = AppSupportPaths
            .directory(forAppNamed: "WheelNotes")
            .appendingPathComponent("Notes", isDirectory: true),
        saveDebounceInterval: Duration = .milliseconds(700)
    ) {
        self.repository = NoteRepository(storageRoot: storageRoot)
        self.saveScheduler = StoreSaveScheduler(delay: saveDebounceInterval)
    }

    public var orderedNotes: [NoteRecord] {
        notes.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    public func bindToWorkspace(_ workspaceID: UUID) {
        if currentWorkspaceID != workspaceID {
            flushPendingSaves()
        }

        currentWorkspaceID = workspaceID
        loadNotes(for: workspaceID)
    }

    public func note(with id: UUID) -> NoteRecord? {
        notes.first { $0.id == id }
    }

    @discardableResult
    public func createNote(title: String = "") -> NoteRecord {
        preconditionWorkspace()

        let document = NoteDocument.titled(title)
        let note = NoteRecord(
            workspaceID: currentWorkspaceID!,
            kind: .adhoc,
            title: document.titleLine(maxLength: Int.max),
            excerpt: document.previewText(),
            document: document
        )
        insert(note)
        persistNoteImmediately(note)
        changeHandler?(.created(note))
        return note
    }

    public func updateDocument(id: UUID, document: NoteDocument) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        if notes[index].document.canonicalJSONString == document.canonicalJSONString {
            return
        }

        notes[index].document = document
        notes[index].title = document.titleLine(maxLength: Int.max)
        notes[index].excerpt = document.previewText()
        notes[index].updatedAt = Date()
        markDirty(notes[index].id)
        changeHandler?(.updated(notes[index]))
    }

    @discardableResult
    public func duplicateNote(id: UUID) -> NoteRecord? {
        guard let source = note(with: id) else { return nil }

        let duplicated = NoteRecord(
            workspaceID: source.workspaceID,
            kind: .adhoc,
            title: source.title,
            createdAt: Date(),
            updatedAt: Date(),
            excerpt: source.excerpt,
            document: source.document
        )
        insert(duplicated)
        persistNoteImmediately(duplicated)
        changeHandler?(.created(duplicated))
        return duplicated
    }

    public func deleteNote(id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }

        let note = notes.remove(at: index)
        dirtyNoteIDs.remove(note.id)
        deletePersistedNote(note)
        changeHandler?(.deleted(id: note.id, workspaceID: note.workspaceID))
    }

    public func insertPageSource(id: UUID, source: NotePageSource) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }

        let document = notes[index].document.insertingPageSource(source)
        notes[index].document = document
        notes[index].title = document.titleLine(maxLength: Int.max)
        notes[index].excerpt = document.previewText()
        notes[index].updatedAt = Date()
        markDirty(notes[index].id)
        changeHandler?(.updated(notes[index]))
    }

    public func flushPendingSaves() {
        saveScheduler.flush { [weak self] in
            self?.persistDirtyNotes()
        }
    }

    private func insert(_ note: NoteRecord) {
        notes.append(note)
    }

    private func markDirty(_ noteID: UUID) {
        dirtyNoteIDs.insert(noteID)
        scheduleDebouncedSave()
    }

    private func scheduleDebouncedSave() {
        saveScheduler.schedule { [weak self] in
            self?.persistDirtyNotes()
        }
    }

    private func persistDirtyNotes() {
        guard !dirtyNoteIDs.isEmpty else { return }
        let dirtyIDs = dirtyNoteIDs
        dirtyNoteIDs.removeAll()

        for id in dirtyIDs {
            guard let note = note(with: id) else { continue }
            persistNoteImmediately(note)
        }
    }

    private func loadNotes(for workspaceID: UUID) {
        notes = repository.notes(in: workspaceID)
        dirtyNoteIDs.removeAll()
    }

    private func persistNoteImmediately(_ note: NoteRecord) {
        try? repository.save(note)
    }

    private func deletePersistedNote(_ note: NoteRecord) {
        try? repository.delete(note)
    }

    private func preconditionWorkspace() {
        precondition(currentWorkspaceID != nil, "NoteStore must bind to a workspace before note operations")
    }
}
