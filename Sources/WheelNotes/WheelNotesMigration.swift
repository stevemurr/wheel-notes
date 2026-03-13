import Foundation
import WheelNotesCore
import WheelSupport

enum WheelNotesMigration {
    private static let notesDirectoryName = "Notes"
    private static let legacyAppName = "WheelBrowser"
    private static let destinationAppName = "WheelNotes"

    static func runIfNeeded(workspaceCacheStore: JSONBackedStore<WorkspaceCatalogSnapshot>) {
        migrateNotesIfNeeded()
        seedWorkspaceCacheIfNeeded(workspaceCacheStore: workspaceCacheStore)
    }

    private static func migrateNotesIfNeeded() {
        let destination = AppSupportPaths
            .directory(forAppNamed: destinationAppName)
            .appendingPathComponent(notesDirectoryName, isDirectory: true)
        let legacy = AppSupportPaths
            .directory(forAppNamed: legacyAppName)
            .appendingPathComponent(notesDirectoryName, isDirectory: true)
        let fileManager = FileManager.default

        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let destinationHasEntries = ((try? fileManager.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).isEmpty == false

        guard !destinationHasEntries, fileManager.fileExists(atPath: legacy.path) else {
            return
        }

        guard let legacyEntries = try? fileManager.contentsOfDirectory(
            at: legacy,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for entry in legacyEntries {
            let destinationURL = destination.appendingPathComponent(entry.lastPathComponent, isDirectory: true)
            guard !fileManager.fileExists(atPath: destinationURL.path) else { continue }
            try? fileManager.copyItem(at: entry, to: destinationURL)
        }
    }

    private static func seedWorkspaceCacheIfNeeded(workspaceCacheStore: JSONBackedStore<WorkspaceCatalogSnapshot>) {
        if (try? workspaceCacheStore.load()) != nil {
            return
        }

        if let snapshot = loadLegacyWorkspaceSnapshot() {
            try? workspaceCacheStore.save(snapshot)
            return
        }

        let fallbackSnapshot = synthesizeWorkspaceSnapshotFromNotes()
        if !fallbackSnapshot.workspaces.isEmpty {
            try? workspaceCacheStore.save(fallbackSnapshot)
        }
    }

    private static func loadLegacyWorkspaceSnapshot() -> WorkspaceCatalogSnapshot? {
        let legacyURL = AppSupportPaths
            .directory(forAppNamed: legacyAppName)
            .appendingPathComponent("workspaces.json")
        guard let data = try? Data(contentsOf: legacyURL) else {
            return nil
        }

        guard let payload = try? JSONDecoder().decode(LegacyWorkspacesData.self, from: data) else {
            return nil
        }

        return WorkspaceCatalogSnapshot(
            workspaces: payload.workspaces.map {
                WheelWorkspaceDescriptor(id: $0.id, name: $0.name, icon: $0.icon, color: $0.color)
            },
            currentWorkspaceID: payload.currentWorkspaceID
        )
    }

    private static func synthesizeWorkspaceSnapshotFromNotes() -> WorkspaceCatalogSnapshot {
        let notesRoot = AppSupportPaths
            .directory(forAppNamed: destinationAppName)
            .appendingPathComponent(notesDirectoryName, isDirectory: true)
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(
            at: notesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let workspaces = entries.compactMap { url -> WheelWorkspaceDescriptor? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let id = UUID(uuidString: url.lastPathComponent) else {
                return nil
            }

            return WheelWorkspaceDescriptor(
                id: id,
                name: "Workspace \(id.uuidString.prefix(8))",
                icon: "folder",
                color: "#007AFF"
            )
        }

        return WorkspaceCatalogSnapshot(
            workspaces: workspaces.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            currentWorkspaceID: workspaces.first?.id
        )
    }
}

private struct LegacyWorkspacesData: Codable {
    let workspaces: [LegacyWorkspace]
    let currentWorkspaceID: UUID?
}

private struct LegacyWorkspace: Codable {
    let id: UUID
    let name: String
    let icon: String
    let color: String
}
