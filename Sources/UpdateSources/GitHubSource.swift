import CaskIndex
import Foundation
import Net
import Versions

public struct GitHubRelease: Sendable, Hashable, Codable {
    public struct Asset: Sendable, Hashable, Codable {
        public let name: String
        public let url: URL
        public let size: Int64?
        /// `sha256:<hex>` when GitHub has computed one.
        public let digest: String?

        public var sha256: String? {
            guard let digest, digest.hasPrefix("sha256:") else { return nil }
            return String(digest.dropFirst(7)).lowercased()
        }
    }

    public let tag: String
    public let name: String?
    public let body: String?
    public let page: URL?
    public let publishedAt: Date?
    public let assets: [Asset]

    /// `v2.0.4` → `2.0.4`; `rectangle-2.0.4` → `2.0.4`.
    public var versionString: String? { GitHubRelease.version(fromTag: tag) }

    public static func version(fromTag tag: String) -> String? {
        guard let first = tag.firstIndex(where: \.isNumber) else { return nil }
        let prefix = tag[..<first]
        guard prefix.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "_" || $0 == "." || $0 == "/" }) else { return nil }
        let candidate = String(tag[first...])
        return Version(candidate) == nil ? nil : candidate
    }
}

/// Newest non-draft, non-prerelease release from GitHub's API (F16). Requests are conditional
/// (ETag), so repeat checks don't use up GitHub's 60-requests-an-hour limit.
public actor GitHubSource {
    public enum Failure: Error, Equatable, LocalizedError {
        case rateLimited
        case unreachable(String)
        case noRelease

        public var errorDescription: String? {
            switch self {
            case .rateLimited: "GitHub's hourly limit was reached; try again later"
            case .unreachable(let why): "GitHub not reachable (\(why))"
            case .noRelease: "The repository has no published release"
            }
        }
    }

    private struct Cached {
        var etag: String?
        var release: GitHubRelease?
    }

    private let client: HTTPClient
    private var cache: [GitHubRepository: Cached] = [:]

    public init(client: HTTPClient) {
        self.client = client
    }

    public func latestRelease(of repo: GitHubRepository) async throws(Failure) -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(repo.owner)/\(repo.name)/releases/latest")!
        var headers = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
        if let etag = cache[repo]?.etag { headers["If-None-Match"] = etag }
        let response: HTTPResponse
        do {
            response = try await client.get(url, headers: headers, timeout: Net.feedTimeout)
        } catch {
            if let cached = cache[repo]?.release { return cached }
            throw .unreachable((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        switch response.status {
        case 304:
            if let cached = cache[repo]?.release { return cached }
            throw .unreachable("Unexpected 304")
        case 200:
            guard let release = Self.parse(response.body) else { throw .unreachable("Unreadable response") }
            cache[repo] = Cached(etag: response.header("ETag"), release: release)
            return release
        case 404:
            throw .noRelease
        case 403, 429:
            if let cached = cache[repo]?.release { return cached }
            throw .rateLimited
        default:
            throw .unreachable("HTTP \(response.status)")
        }
    }

    /// `https://github.com/o/r/releases/download/v2.0.4/file` → `v2.0.4`
    static func tag(inAssetURL url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 5, parts[2] == "releases", parts[3] == "download" else { return nil }
        return parts[4]
    }

    /// Everything before the first digit: `v` for `v2.0.4`, `cli-v` for `cli-v3.0`.
    static func tagPrefix(_ tag: String) -> String {
        String(tag.prefix { !$0.isNumber }).lowercased()
    }

    struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int64?
            let digest: String?
        }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String?
        let published_at: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]?
    }

    static func parse(_ data: Data) -> GitHubRelease? {
        guard let p = try? JSONDecoder().decode(Payload.self, from: data), p.draft != true, p.prerelease != true else { return nil }
        return GitHubRelease(
            tag: p.tag_name,
            name: p.name,
            body: p.body,
            page: p.html_url.flatMap(URL.init(string:)),
            publishedAt: p.published_at.flatMap { ISO8601DateFormatter().date(from: $0) },
            assets: (p.assets ?? []).compactMap { a in
                URL(string: a.browser_download_url).map { GitHubRelease.Asset(name: a.name, url: $0, size: a.size, digest: a.digest) }
            }
        )
    }

    /// A release for a cask whose download lives on GitHub. The asset is found by putting the new
    /// version into the cask's file name (`Rectangle2.0.4.dmg` → `Rectangle2.0.5.dmg`).
    public static func release(_ release: GitHubRelease, forCask cask: Cask) -> Release? {
        guard let version = release.versionString, let parsed = Version(version), !parsed.isPrerelease else { return nil }
        // Repos that ship several products tag them differently (`cli-v3.0` next to `v1.2`):
        // the new tag must look like the one in the cask's download URL.
        if let caskTag = cask.url.flatMap(Self.tag(inAssetURL:)), Self.tagPrefix(caskTag) != Self.tagPrefix(release.tag) {
            return nil
        }
        var asset: GitHubRelease.Asset?
        if let caskFile = cask.url?.lastPathComponent.removingPercentEncoding, let old = cask.versionPair.short, caskFile.contains(old) {
            let wanted = caskFile.replacingOccurrences(of: old, with: version)
            asset = release.assets.first { $0.name == wanted }
        }
        return Release(
            source: .github,
            version: VersionPair(short: version),
            basis: .shortVersion,
            downloadURL: asset?.url,
            downloadPage: release.page,
            releaseNotes: release.body.map { ReleaseNotes(text: $0, format: .markdown, link: release.page) },
            minimumOS: cask.minimumMacOS,
            date: release.publishedAt,
            sha256: asset?.sha256,
            length: asset?.size,
            installsPkg: asset.map { $0.name.lowercased().hasSuffix(".pkg") } ?? false,
            caskToken: cask.token
        )
    }
}
