import Foundation

public struct StoreNamespace: Hashable, ExpressibleByStringLiteral, Sendable {
    public static let root = StoreNamespace()

    public let rawValue: String

    public init(_ rawValue: String = "") {
        self.rawValue = Self.normalize(rawValue)
    }

    public init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }

    public func appending(_ component: String) -> StoreNamespace {
        guard !component.isEmpty else { return self }
        if rawValue.isEmpty {
            return StoreNamespace(component)
        }
        return StoreNamespace("\(rawValue)/\(component)")
    }

    public var pathComponents: [String] {
        rawValue
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func normalize(_ value: String) -> String {
        value
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .joined(separator: "/")
    }
}

public struct StoreKey: Hashable, ExpressibleByStringLiteral, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }
}

public protocol StoreBackend: AnyObject {
    func ensureNamespace(_ namespace: StoreNamespace) throws
    func loadData(in namespace: StoreNamespace, key: StoreKey) throws -> Data?
    func saveData(_ data: Data, in namespace: StoreNamespace, key: StoreKey) throws
    func deleteData(in namespace: StoreNamespace, key: StoreKey) throws
    func listKeys(in namespace: StoreNamespace) throws -> [StoreKey]
}

public final class FileSystemStoreBackend: StoreBackend, @unchecked Sendable {
    private let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    public func ensureNamespace(_ namespace: StoreNamespace) throws {
        try fileManager.createDirectory(
            at: url(for: namespace),
            withIntermediateDirectories: true
        )
    }

    public func loadData(in namespace: StoreNamespace, key: StoreKey) throws -> Data? {
        let fileURL = url(for: namespace, key: key)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try Data(contentsOf: fileURL)
    }

    public func saveData(_ data: Data, in namespace: StoreNamespace, key: StoreKey) throws {
        try ensureNamespace(namespace)
        try data.write(to: url(for: namespace, key: key), options: .atomic)
    }

    public func deleteData(in namespace: StoreNamespace, key: StoreKey) throws {
        let fileURL = url(for: namespace, key: key)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    public func listKeys(in namespace: StoreNamespace) throws -> [StoreKey] {
        let directoryURL = url(for: namespace)
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }

        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        return try urls
            .filter { url in
                try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            }
            .map { StoreKey($0.lastPathComponent) }
            .sorted { $0.rawValue < $1.rawValue }
    }

    public func url(for namespace: StoreNamespace, key: StoreKey? = nil) -> URL {
        let namespaceURL = namespace.pathComponents.reduce(rootURL) { partialURL, component in
            partialURL.appendingPathComponent(component, isDirectory: true)
        }

        guard let key else { return namespaceURL }
        return namespaceURL.appendingPathComponent(key.rawValue)
    }
}
