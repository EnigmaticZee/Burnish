import Foundation
import Net
import os

/// Downloads Homebrew's bulk cask list, revalidates it with its ETag at most once every
/// 24 hours, keeps it on disk and works offline from the last copy.
public actor CaskDataStore {
    public static let sourceURL = URL(string: "https://formulae.brew.sh/api/cask.json")!
    public static let refreshInterval: TimeInterval = 24 * 60 * 60
    /// Bump when `Cask` changes shape so the compact index is rebuilt from the raw file.
    static let indexSchema = 5

    public struct Loaded: Sendable {
        public let catalog: CaskCatalog
        /// When the data was last confirmed current with Homebrew.
        public let dataDate: Date
        /// True when Burnish couldn't reach Homebrew and is using the last copy.
        public let isOffline: Bool
    }

    public enum Failure: Error, LocalizedError {
        case noData(underlying: String)
        public var errorDescription: String? {
            switch self {
            case .noData(let underlying): String(localized: "Homebrew's app list isn't available yet (\(underlying))")
            }
        }
    }

    struct Meta: Codable {
        var etag: String?
        var fetchedAt: Date
        var indexSchema: Int?
        var platform: String?
    }

    private let directory: URL
    private let client: HTTPClient
    private let platform: Platform
    private let now: @Sendable () -> Date
    private var cached: Loaded?
    private let log = Logger(subsystem: "io.github.enigmaticzee.Burnish", category: "casks")

    public init(directory: URL, client: HTTPClient, platform: Platform = .current, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.client = client
        self.platform = platform
        self.now = now
    }

    var rawURL: URL { directory.appendingPathComponent("cask.json") }
    var indexURL: URL { directory.appendingPathComponent("cask-index.json") }
    var metaURL: URL { directory.appendingPathComponent("cask-meta.json") }

    public func load() async throws -> Loaded {
        let meta = readMeta()
        let fresh = meta.map { now().timeIntervalSince($0.fetchedAt) < Self.refreshInterval } ?? false

        if fresh, let cached { return cached }
        if fresh, let meta, let catalog = loadFromDisk(meta: meta) {
            return remember(Loaded(catalog: catalog, dataDate: meta.fetchedAt, isOffline: false))
        }

        // Stale or missing: revalidate with Homebrew.
        do {
            var headers: [String: String] = [:]
            if let etag = meta?.etag, FileManager.default.fileExists(atPath: rawURL.path) {
                headers["If-None-Match"] = etag
            }
            let response = try await client.get(Self.sourceURL, headers: headers, timeout: 60)
            let fetchedAt = now()
            if response.status == 304, var meta {
                meta.fetchedAt = fetchedAt
                writeMeta(meta)
                if let cached { return remember(Loaded(catalog: cached.catalog, dataDate: fetchedAt, isOffline: false)) }
                if let catalog = loadFromDisk(meta: meta) {
                    return remember(Loaded(catalog: catalog, dataDate: fetchedAt, isOffline: false))
                }
                throw HTTPError.other(String(localized: "Cached cask list is unreadable"))
            }
            guard response.isSuccess else { throw HTTPError.status(response.status) }
            let casks = try Self.parse(response.body, platform: platform)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try response.body.write(to: rawURL, options: .atomic)
            writeIndex(casks)
            writeMeta(Meta(etag: response.header("ETag"), fetchedAt: fetchedAt, indexSchema: Self.indexSchema, platform: platform.variationKey))
            log.info("Fetched \(casks.count) casks")
            return remember(Loaded(catalog: CaskCatalog(casks: casks), dataDate: fetchedAt, isOffline: false))
        } catch {
            log.error("Cask list refresh failed: \(error.localizedDescription, privacy: .public)")
            if let cached { return remember(Loaded(catalog: cached.catalog, dataDate: cached.dataDate, isOffline: true)) }
            if let meta, let catalog = loadFromDisk(meta: meta) {
                return remember(Loaded(catalog: catalog, dataDate: meta.fetchedAt, isOffline: true))
            }
            throw Failure.noData(underlying: error.localizedDescription)
        }
    }

    /// Drops the in-memory copy (the next load reads the compact index from disk).
    public func releaseMemory() { cached = nil }

    private func remember(_ loaded: Loaded) -> Loaded {
        cached = loaded
        return loaded
    }

    // MARK: Disk

    private func loadFromDisk(meta: Meta) -> CaskCatalog? {
        if meta.indexSchema == Self.indexSchema, meta.platform == platform.variationKey,
           let data = try? Data(contentsOf: indexURL),
           let casks = try? JSONDecoder().decode([Cask].self, from: data) {
            return CaskCatalog(casks: casks)
        }
        guard let raw = try? Data(contentsOf: rawURL), let casks = try? Self.parse(raw, platform: platform) else { return nil }
        writeIndex(casks)
        var updated = meta
        updated.indexSchema = Self.indexSchema
        updated.platform = platform.variationKey
        writeMeta(updated)
        return CaskCatalog(casks: casks)
    }

    private func readMeta() -> Meta? {
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Meta.self, from: data)
    }

    private func writeMeta(_ meta: Meta) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encoder.encode(meta).write(to: metaURL, options: .atomic)
    }

    private func writeIndex(_ casks: [Cask]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(casks).write(to: indexURL, options: .atomic)
    }

    // MARK: Parsing

    /// Parses `cask.json`, keeping only casks that install something Burnish can match.
    /// Unknown fields are ignored, so new Homebrew fields don't break anything.
    public static func parse(_ data: Data, platform: Platform) throws -> [Cask] {
        try autoreleasepool {
            guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw HTTPError.other(String(localized: "Unexpected cask list format"))
            }
            return list.compactMap { entry -> Cask? in
                guard let cask = Cask(json: entry, platform: platform) else { return nil }
                let installsApp = !cask.appNames.isEmpty || !cask.uninstallAppNames.isEmpty || !cask.quitBundleIDs.isEmpty
                return installsApp ? cask : nil
            }
        }
    }
}
