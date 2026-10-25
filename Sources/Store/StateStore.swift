import Foundation
import os

/// A named JSON file in Burnish's Application Support folder.
public struct StoreKey<Value: Codable & Sendable>: Sendable {
    public let file: String
    public init(_ file: String) { self.file = file }
}

extension StoreKey {
    public static var settings: StoreKey<Settings> { StoreKey<Settings>("settings.json") }
    public static var ignoreRules: StoreKey<IgnoreRules> { StoreKey<IgnoreRules>("ignore-rules.json") }
    public static var appState: StoreKey<AppState> { StoreKey<AppState>("state.json") }
}

/// Everything Burnish remembers, as Codable JSON in `~/Library/Application Support/Burnish`.
/// Nothing here ever leaves the Mac.
public actor StateStore {
    public nonisolated let directory: URL
    private let log = Logger(subsystem: "io.github.enigmaticzee.Burnish", category: "store")

    public init(directory: URL = StateStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Burnish", isDirectory: true)
    }

    public nonisolated func url<Value>(for key: StoreKey<Value>) -> URL {
        directory.appendingPathComponent(key.file)
    }

    public func load<Value>(_ key: StoreKey<Value>) -> Value? {
        let url = url(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try Self.decoder.decode(Value.self, from: data)
        } catch {
            log.error("Couldn't read \(key.file, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public func load<Value>(_ key: StoreKey<Value>, default value: Value) -> Value {
        load(key) ?? value
    }

    public func save<Value>(_ value: Value, _ key: StoreKey<Value>) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(value).write(to: url(for: key), options: .atomic)
        } catch {
            log.error("Couldn't save \(key.file, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Load, change and save in one step.
    @discardableResult
    public func update<Value>(_ key: StoreKey<Value>, default value: Value, _ change: @Sendable (inout Value) -> Void) -> Value {
        var current = load(key) ?? value
        change(&current)
        save(current, key)
        return current
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
