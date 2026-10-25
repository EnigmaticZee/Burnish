import CaskIndex
import Foundation
import Net
import Store

/// Match fixes contributed by pull request to `overrides/community-overrides.json` in the
/// repository. Fetched at most once a day; the last copy is used offline (F17).
public actor CommunityOverrides {
    public static let sourceURL = URL(string: "https://raw.githubusercontent.com/EnigmaticZee/Burnish/main/overrides/community-overrides.json")!

    struct File: Codable {
        var schema: Int
        /// Bundle ID → cask token, or null for "this app has no cask".
        var overrides: [String: String?]
    }

    struct Cached: Codable {
        var fetchedAt: Date
        var etag: String?
        var file: File
    }

    private let client: HTTPClient
    private let store: StateStore
    private let now: @Sendable () -> Date
    private static let key = StoreKey<Cached>("community-overrides.json")

    public init(client: HTTPClient, store: StateStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client
        self.store = store
        self.now = now
    }

    public func load() async -> MatchOverrides {
        let cached = await store.load(Self.key)
        if let cached, now().timeIntervalSince(cached.fetchedAt) < 24 * 3600 {
            return Self.overrides(from: cached.file)
        }
        var headers: [String: String] = [:]
        if let etag = cached?.etag { headers["If-None-Match"] = etag }
        if let response = try? await client.get(Self.sourceURL, headers: headers, timeout: Net.feedTimeout) {
            if response.status == 304, var cached {
                cached.fetchedAt = now()
                await store.save(cached, Self.key)
                return Self.overrides(from: cached.file)
            }
            if response.isSuccess, let file = try? JSONDecoder().decode(File.self, from: response.body), file.schema == 1 {
                await store.save(Cached(fetchedAt: now(), etag: response.header("ETag"), file: file), Self.key)
                return Self.overrides(from: file)
            }
        }
        return cached.map { Self.overrides(from: $0.file) } ?? .none
    }

    static func overrides(from file: File) -> MatchOverrides {
        var result = MatchOverrides()
        for (bundleID, token) in file.overrides {
            if let token { result.chosen[bundleID] = token } else { result.noCask.insert(bundleID) }
        }
        return result
    }
}

/// The user's own match corrections, which win over everything else.
public extension StoreKey where Value == MatchOverrides {
    static var userOverrides: StoreKey<MatchOverrides> { StoreKey<MatchOverrides>("match-overrides.json") }
}
