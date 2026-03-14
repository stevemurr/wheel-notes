import Fabric
import Foundation
import Observation
import WheelNotesCore
import WheelSupport

protocol WheelNotesFabricConsumerClient: Sendable {
    func discoverResources(
        callerAppID: String,
        query: String?
    ) async throws -> [FabricResourceDescriptor]

    func subscribeToResources(
        callerAppID: String,
        request: FabricSubscriptionRequest
    ) async throws -> WheelNotesFabricSubscription
}

protocol WheelNotesFabricProviderClient: Sendable {
    func registerProvider(
        appID: String,
        exposesResources: Bool,
        exposesActions: Bool,
        exposesSubscriptions: Bool
    ) async throws

    func publishEvent(_ event: FabricEvent, from appID: String) async throws
}

struct WheelNotesFabricSubscription: Sendable {
    let stream: AsyncStream<FabricEvent>

    private let cancelHandler: @Sendable () async -> Void

    init(
        stream: AsyncStream<FabricEvent>,
        cancelHandler: @escaping @Sendable () async -> Void = {}
    ) {
        self.stream = stream
        self.cancelHandler = cancelHandler
    }

    func cancel() async {
        await cancelHandler()
    }
}

private struct FabricXPCConsumerAdapter: WheelNotesFabricConsumerClient {
    let client: FabricXPCClient

    func discoverResources(
        callerAppID: String,
        query: String?
    ) async throws -> [FabricResourceDescriptor] {
        try await client.discoverResources(callerAppID: callerAppID, query: query)
    }

    func subscribeToResources(
        callerAppID: String,
        request: FabricSubscriptionRequest
    ) async throws -> WheelNotesFabricSubscription {
        let subscription = try await client.subscribe(callerAppID: callerAppID, request: request)
        return WheelNotesFabricSubscription(
            stream: subscription.stream,
            cancelHandler: {
                await subscription.cancel()
            }
        )
    }
}

private struct FabricXPCProviderAdapter: WheelNotesFabricProviderClient {
    let client: FabricXPCClient

    func registerProvider(
        appID: String,
        exposesResources: Bool,
        exposesActions: Bool,
        exposesSubscriptions: Bool
    ) async throws {
        try await client.register(
            appID: appID,
            exposesResources: exposesResources,
            exposesActions: exposesActions,
            exposesSubscriptions: exposesSubscriptions
        )
    }

    func publishEvent(_ event: FabricEvent, from appID: String) async throws {
        try await client.publish(event: event, from: appID)
    }
}

private enum WheelNotesConnectionTimeoutError: LocalizedError {
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let operation):
            return "\(operation) timed out"
        }
    }
}

private enum WorkspaceSubscriptionKind {
    case workspaceCatalog
    case currentWorkspace

    var resourceKind: String {
        switch self {
        case .workspaceCatalog:
            "workspace"
        case .currentWorkspace:
            "current-workspace"
        }
    }

    var eventKinds: Set<FabricEventKind> {
        switch self {
        case .workspaceCatalog:
            [.resourceUpdated, .resourceRemoved]
        case .currentWorkspace:
            [.resourceUpdated]
        }
    }

    var description: String {
        switch self {
        case .workspaceCatalog:
            "workspace catalog subscription"
        case .currentWorkspace:
            "current workspace subscription"
        }
    }
}

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
    @ObservationIgnored private let consumerClient: any WheelNotesFabricConsumerClient
    @ObservationIgnored private let injectedProviderClient: (any WheelNotesFabricProviderClient)?
    @ObservationIgnored private let connectionAttemptTimeout: Duration
    @ObservationIgnored private let offlineReconnectInterval: Duration
    @ObservationIgnored private let onlineRefreshInterval: Duration
    @ObservationIgnored private lazy var notesProvider = WheelNotesFabricProvider(session: self)
    @ObservationIgnored private lazy var providerClient: any WheelNotesFabricProviderClient = {
        if let injectedProviderClient {
            return injectedProviderClient
        }

        return FabricXPCProviderAdapter(
            client: FabricXPCClient(
                resourceProvider: AnyFabricResourceProvider(notesProvider),
                actionProvider: AnyFabricActionProvider(notesProvider),
                subscriptionProvider: AnyFabricSubscriptionProvider(notesProvider)
            )
        )
    }()
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var workspaceEventsTask: Task<Void, Never>?
    @ObservationIgnored private var currentWorkspaceEventsTask: Task<Void, Never>?
    @ObservationIgnored private var connectionMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var isMaintainingConnection = false
    @ObservationIgnored private var isProviderRegistered = false

    init(
        noteStorageRoot: URL = AppSupportPaths
            .directory(forAppNamed: "WheelNotes")
            .appendingPathComponent("Notes", isDirectory: true),
        workspaceCacheURL: URL = AppSupportPaths
            .directory(forAppNamed: "WheelNotes")
            .appendingPathComponent("workspace_catalog.json"),
        defaults: UserDefaults = .standard,
        consumerClient: (any WheelNotesFabricConsumerClient)? = nil,
        providerClient: (any WheelNotesFabricProviderClient)? = nil,
        connectionAttemptTimeout: Duration = .seconds(2),
        offlineReconnectInterval: Duration = .seconds(2),
        onlineRefreshInterval: Duration = .seconds(20)
    ) {
        self.noteStore = NoteStore(storageRoot: noteStorageRoot, saveDebounceInterval: .milliseconds(700))
        self.noteRepository = NoteRepository(storageRoot: noteStorageRoot)
        self.workspaceCacheStore = JSONBackedStore(
            backend: FileSystemStoreBackend(rootURL: workspaceCacheURL.deletingLastPathComponent()),
            key: StoreKey(workspaceCacheURL.lastPathComponent),
            codingConfiguration: .prettyPrintedSortedKeysISO8601
        )
        self.defaults = defaults
        self.consumerClient = consumerClient ?? FabricXPCConsumerAdapter(client: FabricXPCClient())
        self.injectedProviderClient = providerClient
        self.connectionAttemptTimeout = connectionAttemptTimeout
        self.offlineReconnectInterval = offlineReconnectInterval
        self.onlineRefreshInterval = onlineRefreshInterval

        WheelNotesMigration.runIfNeeded(workspaceCacheStore: workspaceCacheStore)
        loadCachedWorkspaceSnapshot()

        noteStore.changeHandler = { [weak self] change in
            Task { @MainActor in
                await self?.publishNoteChange(change)
            }
        }
    }

    deinit {
        connectionMonitorTask?.cancel()
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

        await maintainFabricConnection()
        startConnectionMonitor()
    }

    func stop() {
        connectionMonitorTask?.cancel()
        connectionMonitorTask = nil
        cancelWorkspaceSubscriptions()
        isMaintainingConnection = false
        isProviderRegistered = false
        hasStarted = false
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

    @discardableResult
    func refreshWorkspaceCatalog() async -> Bool {
        do {
            let resources = try await Self.performWithTimeout(
                "Wheel workspace discovery",
                timeout: connectionAttemptTimeout
            ) { [consumerClient] in
                try await consumerClient.discoverResources(
                    callerAppID: WheelNotesFabricIDs.notes,
                    query: nil
                )
            }

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
                return true
            } else {
                isConnectedToWheel = false
                lastWorkspaceRefreshError = "Wheel did not publish any workspace resources."
            }
        } catch {
            isConnectedToWheel = false
            lastWorkspaceRefreshError = error.localizedDescription
        }

        return false
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

    private func startConnectionMonitor() {
        guard connectionMonitorTask == nil else { return }

        connectionMonitorTask = Task { [weak self] in
            guard let self else { return }
            await self.runConnectionMonitor()
        }
    }

    private func runConnectionMonitor() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: nextConnectionMonitorDelay())
            } catch {
                return
            }

            await maintainFabricConnection()
        }
    }

    private func nextConnectionMonitorDelay() -> Duration {
        isConnectedToWheel ? onlineRefreshInterval : offlineReconnectInterval
    }

    private func maintainFabricConnection() async {
        guard !isMaintainingConnection else { return }
        isMaintainingConnection = true
        defer { isMaintainingConnection = false }

        await ensureProviderRegistration()
        let isLive = await refreshWorkspaceCatalog()

        if isLive {
            await ensureWorkspaceSubscriptions()
        } else {
            cancelWorkspaceSubscriptions()
        }
    }

    private func ensureProviderRegistration() async {
        do {
            try await Self.performWithTimeout(
                "WheelNotes provider registration",
                timeout: connectionAttemptTimeout
            ) { [providerClient] in
                try await providerClient.registerProvider(
                    appID: WheelNotesFabricIDs.notes,
                    exposesResources: true,
                    exposesActions: true,
                    exposesSubscriptions: true
                )
            }
            isProviderRegistered = true
        } catch let fabricError as FabricError {
            switch fabricError {
            case .duplicateProvider:
                isProviderRegistered = true
            default:
                isProviderRegistered = false
            }
        } catch {
            isProviderRegistered = false
        }
    }

    private func ensureWorkspaceSubscriptions() async {
        if workspaceEventsTask == nil {
            workspaceEventsTask = Task { [weak self] in
                await self?.runWorkspaceSubscription(kind: .workspaceCatalog)
            }
        }

        if currentWorkspaceEventsTask == nil {
            currentWorkspaceEventsTask = Task { [weak self] in
                await self?.runWorkspaceSubscription(kind: .currentWorkspace)
            }
        }
    }

    private func cancelWorkspaceSubscriptions() {
        workspaceEventsTask?.cancel()
        workspaceEventsTask = nil
        currentWorkspaceEventsTask?.cancel()
        currentWorkspaceEventsTask = nil
    }

    private func runWorkspaceSubscription(kind: WorkspaceSubscriptionKind) async {
        var subscription: WheelNotesFabricSubscription?
        var errorDescription: String?

        do {
            subscription = try await Self.performWithTimeout(
                kind.description,
                timeout: connectionAttemptTimeout
            ) { [consumerClient] in
                try await consumerClient.subscribeToResources(
                    callerAppID: WheelNotesFabricIDs.notes,
                    request: FabricSubscriptionRequest(
                        appID: WheelNotesFabricIDs.browser,
                        resourceKind: kind.resourceKind,
                        eventKinds: kind.eventKinds
                    )
                )
            }

            if let subscription {
                for await _ in subscription.stream {
                    let isLive = await refreshWorkspaceCatalog()
                    if !isLive {
                        scheduleConnectionMaintenance()
                    }
                }
            }
        } catch {
            errorDescription = error.localizedDescription
        }

        if let subscription {
            await subscription.cancel()
        }

        await handleSubscriptionTermination(
            kind: kind,
            wasCancelled: Task.isCancelled,
            errorDescription: errorDescription
        )
    }

    private func handleSubscriptionTermination(
        kind: WorkspaceSubscriptionKind,
        wasCancelled: Bool,
        errorDescription: String?
    ) async {
        switch kind {
        case .workspaceCatalog:
            workspaceEventsTask = nil
        case .currentWorkspace:
            currentWorkspaceEventsTask = nil
        }

        guard !wasCancelled else { return }

        isConnectedToWheel = false
        if let errorDescription, !errorDescription.isEmpty {
            lastWorkspaceRefreshError = errorDescription
        }
        scheduleConnectionMaintenance()
    }

    private func scheduleConnectionMaintenance() {
        guard hasStarted else { return }
        Task { @MainActor [weak self] in
            await self?.maintainFabricConnection()
        }
    }

    private func publishNoteChange(_ change: NoteStoreChange) async {
        guard isProviderRegistered else { return }

        let event = notesProvider.noteEvent(for: change)

        do {
            try await Self.performWithTimeout(
                "WheelNotes event publish",
                timeout: connectionAttemptTimeout
            ) { [providerClient] in
                try await providerClient.publishEvent(event, from: WheelNotesFabricIDs.notes)
            }
        } catch {
            isProviderRegistered = false
            scheduleConnectionMaintenance()
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

    private static func performWithTimeout<Result: Sendable>(
        _ operationDescription: String,
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw WheelNotesConnectionTimeoutError.timedOut(operationDescription)
            }

            guard let result = try await group.next() else {
                throw WheelNotesConnectionTimeoutError.timedOut(operationDescription)
            }
            group.cancelAll()
            return result
        }
    }
}
