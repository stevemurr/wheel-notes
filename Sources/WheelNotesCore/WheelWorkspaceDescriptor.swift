import Foundation

public struct WheelWorkspaceDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var icon: String
    public var color: String

    public init(id: UUID, name: String, icon: String, color: String) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
    }
}

public struct WorkspaceCatalogSnapshot: Codable, Equatable, Sendable {
    public var workspaces: [WheelWorkspaceDescriptor]
    public var currentWorkspaceID: UUID?

    public init(workspaces: [WheelWorkspaceDescriptor], currentWorkspaceID: UUID?) {
        self.workspaces = workspaces
        self.currentWorkspaceID = currentWorkspaceID
    }
}
