import Fabric
import Foundation
import Observation
import WheelNotesCore
import WheelSupport

@MainActor
@Observable
final class WheelNotesModel: WheelNotesSession {
    var workspaces: [WheelWorkspaceDescriptor] = []
    var currentWheelWorkspaceID: UUID?
    var selectedWorkspaceID: UUID? {
        didSet {
            guard oldValue != selectedWorkspaceID else { return }
            handleSelectedWorkspaceChange()
        }
    }
    var selectedNoteID: UUID?
    var isConnectedToWheel = false
    var lastWorkspaceRefreshError: String?

    private let noteStore: NoteStore
    @ObservationIgnored private let noteRepository: NoteRepository
    @ObservationIgnored private let workspaceCacheStore: JSONBackedStore<WorkspaceCatalogSnapshot>
    @ObservationIgnored private let selectedWorkspaceDefaultsKey = "wheelNotes.selectedWorkspaceID"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let consumerClient: FabricXPCClient
    @ObservationIgnored private lazy var notesProvider = WheelNotesFabricProvider(session: self)
    @ObservationIgnored private lazy var providerClient = FabricXPCClient(
        resourceProvider: AnyFabricResourceProvider(notesProvider),
        actionProvider: AnyFabricActionProvider(notesProvider),
        subscriptionProvider: AnyFabricSubscriptionProvider(notesProvider)
    )
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var workspaceEventsTask: Task<Void, Never>?
    @ObservationIgnored private var currentWorkspaceEventsTask: Task<Void, Never>?
    @ObservationIgnored private var isProviderRegistered = false

    init(
        noteStorageRoot: URL = AppSupportPaths
            .directory(forAppNamed: "WheelNotes")
            .appendingPathComponent("Notes", isDirectory: true),
        workspaceCacheURL: URL = AppSupportPaths
            .directory(forAppNamed: "WheelNotes")
            .appendingPathComponent("workspace_catalog.json"),
        defaults: UserDefaults = .standard
    ) {
        self.noteStore = NoteStore(storageRoot: noteStorageRoot, saveDebounceInterval: .milliseconds(700))
        self.noteRepository = NoteRepository(storageRoot: noteStorageRoot)
        self.workspaceCacheStore = JSONBackedStore(
            backend: FileSystemStoreBackend(rootURL: workspaceCacheURL.deletingLastPathComponent()),
            key: StoreKey(workspaceCacheURL.lastPathComponent),
            codingConfiguration: .prettyPrintedSortedKeysISO8601
        )
        self.defaults = defaults
        self.consumerClient = FabricXPCClient()

        WheelNotesMigration.runIfNeeded(workspaceCacheStore: workspaceCacheStore)
        loadCachedWorkspaceSnapshot()

        noteStore.changeHandler = { [weak self] change in
            Task { @MainActor in
                await self?.publishNoteChange(change)
            }
        }
    }

    deinit {
        workspaceEventsTask?.cancel()
        currentWorkspaceEventsTask?.cancel()
    }

    var notes: [NoteRecord] {
        noteStore.orderedNotes
    }

    var selectedWorkspace: WheelWorkspaceDescriptor? {
        guard let selectedWorkspaceID else { return nil }
        return workspaces.first { $0.id == selectedWorkspaceID }
    }

    var selectedNote: NoteRecord? {
        guard let selectedNoteID else { return nil }
        return noteStore.note(with: selectedNoteID)
    }

    var currentWheelWorkspaceName: String? {
        guard let currentWheelWorkspaceID else { return nil }
        return workspaces.first { $0.id == currentWheelWorkspaceID }?.name
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        do {
            try await providerClient.register(
                appID: notesProvider.appID,
                exposesResources: true,
                exposesActions: true,
                exposesSubscriptions: true
            )
            isProviderRegistered = true
        } catch {
            isProviderRegistered = false
        }

        await refreshWorkspaceCatalog()
        await startWorkspaceSubscriptions()
    }

    func createNoteFromUI() {
        _ = createNote(title: "")
    }

    func deleteSelectedNote() {
        guard let selectedNote else { return }
        noteStore.deleteNote(id: selectedNote.id)
        selectedNoteID = noteStore.orderedNotes.first?.id
    }

    func selectNote(id: UUID?) {
        selectedNoteID = id
    }

    func updateSelectedNoteDocument(_ document: NoteDocument) {
        guard let selectedNoteID else { return }
        noteStore.updateDocument(id: selectedNoteID, document: document)
    }

    func allNotes() -> [NoteRecord] {
        noteRepository.allNotes()
    }

    func noteRecord(id: UUID) -> NoteRecord? {
        if let note = noteStore.note(with: id) {
            return note
        }
        return noteRepository.note(with: id)
    }

    func createNote(title: String) -> NoteRecord? {
        guard let selectedWorkspaceID else { return nil }
        if noteStore.currentWorkspaceID != selectedWorkspaceID {
            noteStore.bindToWorkspace(selectedWorkspaceID)
        }

        let note = noteStore.createNote(title: title)
        selectedNoteID = note.id
        return noteStore.note(with: note.id) ?? note
    }

    func appendPlainText(_ text: String, to noteID: UUID) -> NoteRecord? {
        guard let note = noteRepository.note(with: noteID) else {
            return nil
        }

        let updatedDocument = note.document.appendingPlainText(text)

        if note.workspaceID == selectedWorkspaceID, noteStore.note(with: noteID) != nil {
            noteStore.updateDocument(id: noteID, document: updatedDocument)
            return noteStore.note(with: noteID)
        }

        var updated = note
        updated.document = updatedDocument
        updated.title = updatedDocument.titleLine(maxLength: Int.max)
        updated.excerpt = updatedDocument.previewText()
        updated.updatedAt = Date()
        try? noteRepository.save(updated)
        Task { @MainActor in
            await publishNoteChange(.updated(updated))
        }
        return updated
    }

    func openNote(id: UUID) -> NoteRecord? {
        guard let note = noteRepository.note(with: id) else {
            return nil
        }

        if selectedWorkspaceID != note.workspaceID {
            selectedWorkspaceID = note.workspaceID
        } else if noteStore.currentWorkspaceID != note.workspaceID {
            noteStore.bindToWorkspace(note.workspaceID)
        }

        selectedNoteID = id
        return noteStore.note(with: id) ?? note
    }

    func refreshWorkspaceCatalog() async {
        do {
            let resources = try await consumerClient.discoverResources(
                callerAppID: WheelNotesFabricIDs.notes,
                query: nil
            )

            let workspaceResources = resources.filter {
                $0.uri.appID == WheelNotesFabricIDs.browser && $0.kind == "workspace"
            }
            let currentWorkspaceResource = resources.first {
                $0.uri.appID == WheelNotesFabricIDs.browser && $0.kind == "current-workspace"
            }

            let descriptors = workspaceResources.compactMap(Self.workspaceDescriptor(from:)).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            let currentWorkspaceID = Self.workspaceID(from: currentWorkspaceResource)
                ?? descriptors.first(where: { resource in
                    workspaceResources.contains {
                        Self.workspaceID(from: $0) == resource.id && $0.metadata["isCurrent"]?.boolValue == true
                    }
                })?.id

            if !descriptors.isEmpty || currentWorkspaceResource != nil {
                isConnectedToWheel = true
                lastWorkspaceRefreshError = nil
                applyWorkspaceSnapshot(
                    WorkspaceCatalogSnapshot(
                        workspaces: descriptors,
                        currentWorkspaceID: currentWorkspaceID
                    )
                )
            } else {
                isConnectedToWheel = false
            }
        } catch {
            isConnectedToWheel = false
            lastWorkspaceRefreshError = error.localizedDescription
        }
    }

    private func loadCachedWorkspaceSnapshot() {
        let snapshot = (try? workspaceCacheStore.load()) ?? WorkspaceCatalogSnapshot(workspaces: [], currentWorkspaceID: nil)
        applyWorkspaceSnapshot(snapshot)
    }

    private func applyWorkspaceSnapshot(_ snapshot: WorkspaceCatalogSnapshot) {
        workspaces = snapshot.workspaces
        currentWheelWorkspaceID = snapshot.currentWorkspaceID

        let persistedSelection = defaults.string(forKey: selectedWorkspaceDefaultsKey)
            .flatMap(UUID.init(uuidString:))
        let availableIDs = Set(workspaces.map(\.id))
        let nextSelection = [selectedWorkspaceID, persistedSelection, currentWheelWorkspaceID, workspaces.first?.id]
            .compactMap { $0 }
            .first(where: availableIDs.contains)

        if selectedWorkspaceID != nextSelection {
            selectedWorkspaceID = nextSelection
        } else if let selectedWorkspaceID {
            noteStore.bindToWorkspace(selectedWorkspaceID)
            if !noteStore.orderedNotes.contains(where: { $0.id == selectedNoteID }) {
                selectedNoteID = noteStore.orderedNotes.first?.id
            }
        }

        try? workspaceCacheStore.save(
            WorkspaceCatalogSnapshot(
                workspaces: workspaces,
                currentWorkspaceID: currentWheelWorkspaceID
            )
        )
    }

    private func handleSelectedWorkspaceChange() {
        guard let selectedWorkspaceID else {
            defaults.removeObject(forKey: selectedWorkspaceDefaultsKey)
            selectedNoteID = nil
            return
        }

        defaults.set(selectedWorkspaceID.uuidString, forKey: selectedWorkspaceDefaultsKey)
        noteStore.bindToWorkspace(selectedWorkspaceID)
        if !noteStore.orderedNotes.contains(where: { $0.id == selectedNoteID }) {
            selectedNoteID = noteStore.orderedNotes.first?.id
        }
    }

    private func startWorkspaceSubscriptions() async {
        workspaceEventsTask?.cancel()
        currentWorkspaceEventsTask?.cancel()

        workspaceEventsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let subscription = try await consumerClient.subscribe(
                    callerAppID: WheelNotesFabricIDs.notes,
                    request: FabricSubscriptionRequest(
                        appID: WheelNotesFabricIDs.browser,
                        resourceKind: "workspace",
                        eventKinds: [.resourceUpdated, .resourceRemoved]
                    )
                )
                for await _ in subscription.stream {
                    await refreshWorkspaceCatalog()
                }
            } catch {
                return
            }
        }

        currentWorkspaceEventsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let subscription = try await consumerClient.subscribe(
                    callerAppID: WheelNotesFabricIDs.notes,
                    request: FabricSubscriptionRequest(
                        appID: WheelNotesFabricIDs.browser,
                        resourceKind: "current-workspace",
                        eventKinds: [.resourceUpdated]
                    )
                )
                for await _ in subscription.stream {
                    await refreshWorkspaceCatalog()
                }
            } catch {
                return
            }
        }
    }

    private func publishNoteChange(_ change: NoteStoreChange) async {
        guard isProviderRegistered else { return }

        do {
            try await providerClient.publish(
                event: notesProvider.noteEvent(for: change),
                from: notesProvider.appID
            )
        } catch {
            return
        }
    }

    private static func workspaceDescriptor(from resource: FabricResourceDescriptor) -> WheelWorkspaceDescriptor? {
        guard let workspaceID = workspaceID(from: resource) else {
            return nil
        }

        let name = resource.metadata["name"]?.stringValue ?? resource.title
        let icon = resource.metadata["icon"]?.stringValue ?? "folder"
        let color = resource.metadata["color"]?.stringValue ?? "#007AFF"
        return WheelWorkspaceDescriptor(id: workspaceID, name: name, icon: icon, color: color)
    }

    private static func workspaceID(from resource: FabricResourceDescriptor?) -> UUID? {
        guard let resource else { return nil }
        let rawValue = resource.metadata["workspaceID"]?.stringValue ?? resource.uri.id
        return UUID(uuidString: rawValue)
    }
}
