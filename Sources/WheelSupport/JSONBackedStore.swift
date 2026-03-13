import Foundation

public struct JSONCodingConfiguration {
    public static let `default` = JSONCodingConfiguration()
    public static let prettyPrintedSortedKeys = JSONCodingConfiguration(
        outputFormatting: [.prettyPrinted, .sortedKeys]
    )
    public static let iso8601 = JSONCodingConfiguration(
        dateEncodingStrategy: .iso8601,
        dateDecodingStrategy: .iso8601
    )
    public static let prettyPrintedSortedKeysISO8601 = JSONCodingConfiguration(
        outputFormatting: [.prettyPrinted, .sortedKeys],
        dateEncodingStrategy: .iso8601,
        dateDecodingStrategy: .iso8601
    )

    public let outputFormatting: JSONEncoder.OutputFormatting
    public let dateEncodingStrategy: JSONEncoder.DateEncodingStrategy
    public let dateDecodingStrategy: JSONDecoder.DateDecodingStrategy

    public init(
        outputFormatting: JSONEncoder.OutputFormatting = [],
        dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .deferredToDate,
        dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .deferredToDate
    ) {
        self.outputFormatting = outputFormatting
        self.dateEncodingStrategy = dateEncodingStrategy
        self.dateDecodingStrategy = dateDecodingStrategy
    }

    public func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = outputFormatting
        encoder.dateEncodingStrategy = dateEncodingStrategy
        return encoder
    }

    public func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateDecodingStrategy
        return decoder
    }
}

public final class JSONBackedStore<Value: Codable>: @unchecked Sendable {
    private let backend: StoreBackend
    private let namespace: StoreNamespace
    private let key: StoreKey
    private let codingConfiguration: JSONCodingConfiguration

    public init(
        backend: StoreBackend,
        namespace: StoreNamespace = .root,
        key: StoreKey,
        codingConfiguration: JSONCodingConfiguration = .default
    ) {
        self.backend = backend
        self.namespace = namespace
        self.key = key
        self.codingConfiguration = codingConfiguration
    }

    public var fileURL: URL? {
        (backend as? FileSystemStoreBackend)?.url(for: namespace, key: key)
    }

    public func load() throws -> Value? {
        guard let data = try backend.loadData(in: namespace, key: key) else {
            return nil
        }
        return try codingConfiguration.makeDecoder().decode(Value.self, from: data)
    }

    public func rawData() throws -> Data? {
        try backend.loadData(in: namespace, key: key)
    }

    public func save(_ value: Value) throws {
        let data = try codingConfiguration.makeEncoder().encode(value)
        try backend.saveData(data, in: namespace, key: key)
    }

    public func delete() throws {
        try backend.deleteData(in: namespace, key: key)
    }
}

public final class JSONBackedDirectoryStore<Value: Codable>: @unchecked Sendable {
    private let backend: StoreBackend
    private let namespace: StoreNamespace
    private let codingConfiguration: JSONCodingConfiguration

    public init(
        backend: StoreBackend,
        namespace: StoreNamespace,
        codingConfiguration: JSONCodingConfiguration = .default
    ) {
        self.backend = backend
        self.namespace = namespace
        self.codingConfiguration = codingConfiguration
    }

    public var directoryURL: URL? {
        (backend as? FileSystemStoreBackend)?.url(for: namespace)
    }

    public func fileURL(for key: StoreKey) -> URL? {
        (backend as? FileSystemStoreBackend)?.url(for: namespace, key: key)
    }

    public func load(key: StoreKey) throws -> Value? {
        guard let data = try backend.loadData(in: namespace, key: key) else {
            return nil
        }
        return try codingConfiguration.makeDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value, for key: StoreKey) throws {
        let data = try codingConfiguration.makeEncoder().encode(value)
        try backend.saveData(data, in: namespace, key: key)
    }

    public func delete(key: StoreKey) throws {
        try backend.deleteData(in: namespace, key: key)
    }

    public func keys() throws -> [StoreKey] {
        try backend.listKeys(in: namespace)
    }
}
