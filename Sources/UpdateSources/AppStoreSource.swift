import Foundation
import Inventory
import Net
import Versions

/// Apple's public lookup endpoint, batched by bundle ID. Detect only: updates open in the App Store.
public struct AppStoreSource: Sendable {
    public static let batchSize = 200
    /// The App Store's Updates page, where Apple's own Update All installs every App Store update at once.
    public static let updatesPage = URL(string: "macappstore://showUpdatesPage")!

    let client: HTTPClient
    let country: String?

    public init(client: HTTPClient, country: String? = Locale.current.region?.identifier) {
        self.client = client
        self.country = country?.lowercased()
    }

    /// Returns releases keyed by bundle ID. Apps the App Store doesn't know are left out.
    public func lookup(_ apps: [InstalledApp]) async throws -> [String: Release] {
        let mac = apps.filter { !$0.isWrappedIOSApp }.map(\.bundleID)
        let iOS = apps.filter(\.isWrappedIOSApp).map(\.bundleID)
        var results: [String: Release] = [:]
        for batch in Self.batches(of: Array(Set(mac)).sorted()) {
            results.merge(try await fetch(batch, entity: "desktopSoftware")) { a, _ in a }
        }
        // iPhone and iPad apps on Apple silicon, plus Mac apps the desktop entity missed.
        let missing = Array(Set(iOS + mac.filter { results[$0] == nil })).sorted()
        for batch in Self.batches(of: missing) where !batch.isEmpty {
            results.merge(try await fetch(batch, entity: "software")) { a, _ in a }
        }
        return results
    }

    static func batches(of ids: [String]) -> [[String]] {
        stride(from: 0, to: ids.count, by: batchSize).map { Array(ids[$0..<min($0 + batchSize, ids.count)]) }
    }

    public func url(for ids: [String], entity: String) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        var items = [
            URLQueryItem(name: "bundleId", value: ids.joined(separator: ",")),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: String(ids.count)),
        ]
        if let country { items.append(URLQueryItem(name: "country", value: country)) }
        components.queryItems = items
        return components.url!
    }

    func fetch(_ ids: [String], entity: String) async throws -> [String: Release] {
        guard !ids.isEmpty else { return [:] }
        let response = try await client.get(url(for: ids, entity: entity), headers: [:], timeout: Net.feedTimeout)
        guard response.isSuccess else { throw HTTPError.status(response.status) }
        // `software` results are iPhone and iPad apps, whose minimum is an iOS version.
        return try Self.parse(response.body, asked: Set(ids), minimumIsMacOS: entity == "desktopSoftware")
    }

    struct Payload: Decodable {
        struct Item: Decodable {
            let bundleId: String?
            let version: String?
            let trackId: Int?
            let trackViewUrl: String?
            let releaseNotes: String?
            let minimumOsVersion: String?
            let currentVersionReleaseDate: String?
            let kind: String?
        }
        let results: [Item]
    }

    static func parse(_ data: Data, asked: Set<String>, minimumIsMacOS: Bool = true) throws -> [String: Release] {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let dates = ISO8601DateFormatter()
        var out: [String: Release] = [:]
        for item in payload.results {
            guard let id = item.bundleId, asked.contains(id), let version = item.version else { continue }
            out[id] = Release(
                source: .appStore,
                version: VersionPair(short: version),
                basis: .shortVersion,
                downloadPage: item.trackId.flatMap { URL(string: "macappstore://apps.apple.com/app/id\($0)") }
                    ?? item.trackViewUrl.flatMap(URL.init(string:)),
                releaseNotes: item.releaseNotes.map { ReleaseNotes(text: $0, format: .plainText) },
                minimumOS: minimumIsMacOS ? item.minimumOsVersion : nil,
                date: item.currentVersionReleaseDate.flatMap { dates.date(from: $0) },
                appStoreID: item.trackId
            )
        }
        return out
    }
}
