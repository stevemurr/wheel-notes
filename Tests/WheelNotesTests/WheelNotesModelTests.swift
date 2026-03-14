import Fabric
import Foundation
import XCTest
@testable import WheelNotes

@MainActor
final class WheelNotesModelTests: XCTestCase {
    func testStartRecoversWhenWheelAppearsAfterLaunch() async throws {
        let workspaceID = UUID()
        let resources = makeWorkspaceResources(id: workspaceID, name: "Default")
        let consumer = ConsumerClientStub(mode: .failure("Wheel unavailable"))
        let provider = ProviderClientStub()
        let context = try makeModelContext()
        defer { context.cleanup() }

        let model = WheelNotesModel(
            noteStorageRoot: context.noteStorageRoot,
            workspaceCacheURL: context.workspaceCacheURL,
            defaults: context.defaults,
            consumerClient: consumer,
            providerClient: provider,
            connectionAttemptTimeout: .milliseconds(50),
            offlineReconnectInterval: .milliseconds(30),
            onlineRefreshInterval: .milliseconds(120)
        )
        await model.start()

        XCTAssertFalse(model.isConnectedToWheel)

        await consumer.setMode(.success(resources))

        let connected = await waitUntil { model.isConnectedToWheel }
        XCTAssertTrue(connected)
        XCTAssertEqual(model.currentWheelWorkspaceName, "Default")
        XCTAssertEqual(model.workspaces.map(\.name), ["Default"])

        model.stop()
    }

    func testModelReconnectsAfterTransientDiscoveryFailure() async throws {
        let workspaceID = UUID()
        let resources = makeWorkspaceResources(id: workspaceID, name: "Default")
        let consumer = ConsumerClientStub(mode: .success(resources))
        let provider = ProviderClientStub()
        let context = try makeModelContext()
        defer { context.cleanup() }

        let model = WheelNotesModel(
            noteStorageRoot: context.noteStorageRoot,
            workspaceCacheURL: context.workspaceCacheURL,
            defaults: context.defaults,
            consumerClient: consumer,
            providerClient: provider,
            connectionAttemptTimeout: .milliseconds(50),
            offlineReconnectInterval: .milliseconds(30),
            onlineRefreshInterval: .milliseconds(40)
        )
        await model.start()

        let initiallyConnected = await waitUntil { model.isConnectedToWheel }
        XCTAssertTrue(initiallyConnected)

        await consumer.setMode(.failure("Broker unavailable"))
        let wentOffline = await waitUntil { !model.isConnectedToWheel }
        XCTAssertTrue(wentOffline)

        await consumer.setMode(.success(resources))
        let reconnected = await waitUntil { model.isConnectedToWheel }
        XCTAssertTrue(reconnected)

        model.stop()
    }

    private func makeWorkspaceResources(id: UUID, name: String) -> [FabricResourceDescriptor] {
        [
            FabricResourceDescriptor(
                uri: FabricURI(appID: "wheel.browser", kind: "workspace", id: id.uuidString),
                kind: "workspace",
                title: name,
                summary: "Current Wheel workspace",
                capabilities: [.read],
                metadata: [
                    "workspaceID": .string(id.uuidString),
                    "name": .string(name),
                    "icon": .string("house"),
                    "color": .string("#007AFF"),
                    "isCurrent": .bool(true),
                ]
            ),
            FabricResourceDescriptor(
                uri: FabricURI(appID: "wheel.browser", kind: "current-workspace", id: "current"),
                kind: "current-workspace",
                title: name,
                summary: "Current Wheel workspace",
                capabilities: [.read, .subscribe],
                metadata: [
                    "workspaceID": .string(id.uuidString),
                    "name": .string(name),
                    "icon": .string("house"),
                    "color": .string("#007AFF"),
                    "isCurrent": .bool(true),
                ]
            ),
        ]
    }

    private func makeModelContext() throws -> ModelContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WheelNotesModelTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let suiteName = "WheelNotesModelTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw TestFailure("Failed to create isolated UserDefaults suite")
        }

        return ModelContext(
            root: root,
            defaults: defaults,
            suiteName: suiteName
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        pollingInterval: Duration = .milliseconds(10),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }

            do {
                try await Task.sleep(for: pollingInterval)
            } catch {
                return false
            }
        }

        return condition()
    }
}

private struct ModelContext {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String

    var noteStorageRoot: URL {
        root.appendingPathComponent("Notes", isDirectory: true)
    }

    var workspaceCacheURL: URL {
        root.appendingPathComponent("workspace_catalog.json")
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private struct TestFailure: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private actor ConsumerClientStub: WheelNotesFabricConsumerClient {
    enum Mode: Sendable {
        case success([FabricResourceDescriptor])
        case failure(String)
    }

    private var mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
    }

    func discoverResources(
        callerAppID: String,
        query: String?
    ) async throws -> [FabricResourceDescriptor] {
        switch mode {
        case .success(let resources):
            return resources
        case .failure(let message):
            throw TestFailure(message)
        }
    }

    func subscribeToResources(
        callerAppID: String,
        request: FabricSubscriptionRequest
    ) async throws -> WheelNotesFabricSubscription {
        WheelNotesFabricSubscription(stream: AsyncStream { _ in })
    }
}

private actor ProviderClientStub: WheelNotesFabricProviderClient {
    func registerProvider(
        appID: String,
        exposesResources: Bool,
        exposesActions: Bool,
        exposesSubscriptions: Bool
    ) async throws {}

    func publishEvent(_ event: FabricEvent, from appID: String) async throws {}
}
