import Foundation
import CaskIndex
import Inventory
import Net
import Versions

/// Apps built with electron-builder say where they update from in `app-update.yml`;
/// the provider serves `latest-mac.yml` with the version, files and SHA-512 checksums.
public struct ElectronSource: Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        case unsupportedProvider(String)
        case unreachable(String)
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .unsupportedProvider(let p): String(localized: "Update provider \"\(p)\" isn't supported")
            case .unreachable(let why): String(localized: "Feed not reachable (\(why))")
            case .unreadable: String(localized: "The update feed couldn't be read")
            }
        }
    }

    /// Where the app's `latest-mac.yml` lives, and the base its file names resolve against.
    public struct Feed: Sendable, Hashable {
        public let manifest: URL
        public let fileBase: URL
        public let github: GitHubRepository?
    }

    let client: HTTPClient
    let isARM: Bool

    public init(client: HTTPClient, isARM: Bool = Platform.currentIsARM) {
        self.client = client
        self.isARM = isARM
    }

    public static func feed(fromConfig yaml: String) throws(Failure) -> Feed {
        let config = MiniYAML.parse(yaml)
        let provider = config["provider"]?.string ?? "generic"
        let channel = config["channel"]?.string ?? "latest"
        let manifestName = "\(channel)-mac.yml"
        switch provider {
        case "generic":
            guard let raw = config["url"]?.string, var base = URL(string: raw), base.scheme == "https" else {
                throw .unsupportedProvider("generic without an HTTPS url")
            }
            if !base.absoluteString.hasSuffix("/") { base = URL(string: base.absoluteString + "/")! }
            return Feed(manifest: base.appendingPathComponent(manifestName), fileBase: base, github: nil)
        case "github":
            guard let owner = config["owner"]?.string, let repo = config["repo"]?.string else {
                throw .unsupportedProvider("github without owner/repo")
            }
            let repository = GitHubRepository(owner: owner, name: repo)
            let manifest = URL(string: "https://github.com/\(owner)/\(repo)/releases/latest/download/\(manifestName)")!
            return Feed(manifest: manifest, fileBase: manifest.deletingLastPathComponent(), github: repository)
        case "s3":
            guard let bucket = config["bucket"]?.string else { throw .unsupportedProvider("s3 without bucket") }
            let region = config["region"]?.string
            let host = region.map { "\(bucket).s3.\($0).amazonaws.com" } ?? "\(bucket).s3.amazonaws.com"
            let path = (config["path"]?.string ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let base = URL(string: "https://\(host)/" + (path.isEmpty ? "" : path + "/"))!
            return Feed(manifest: base.appendingPathComponent(manifestName), fileBase: base, github: nil)
        case "spaces":
            guard let name = config["name"]?.string, let region = config["region"]?.string else {
                throw .unsupportedProvider("spaces without name/region")
            }
            let path = (config["path"]?.string ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let base = URL(string: "https://\(name).\(region).digitaloceanspaces.com/" + (path.isEmpty ? "" : path + "/"))!
            return Feed(manifest: base.appendingPathComponent(manifestName), fileBase: base, github: nil)
        default:
            throw .unsupportedProvider(provider)
        }
    }

    public func check(configFile: URL) async throws(Failure) -> Release {
        guard let text = try? String(contentsOf: configFile, encoding: .utf8) else { throw .unreadable }
        let feed = try Self.feed(fromConfig: text)
        let response: HTTPResponse
        do {
            response = try await client.get(feed.manifest, headers: [:], timeout: Net.feedTimeout)
        } catch {
            throw .unreachable((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        guard response.isSuccess else { throw .unreachable("HTTP \(response.status)") }
        return try release(fromManifest: String(decoding: response.body, as: UTF8.self), feed: feed)
    }

    func release(fromManifest text: String, feed: Feed) throws(Failure) -> Release {
        let manifest = MiniYAML.parse(text)
        guard let version = manifest["version"]?.string else { throw .unreadable }
        var files = manifest["files"]?.list ?? []
        if files.isEmpty, let path = manifest["path"]?.string {
            files = [["url": path, "sha512": manifest["sha512"]?.string ?? ""]]
        }
        guard let file = pickFile(files) else { throw .unreadable }

        let fileURL: URL?
        if let raw = file["url"], let absolute = URL(string: raw), absolute.scheme != nil {
            fileURL = absolute
        } else if let raw = file["url"] {
            // GitHub release assets live under the `v<version>` tag by electron-builder's default.
            let base = feed.github.map { URL(string: "https://github.com/\($0.owner)/\($0.name)/releases/download/v\(version)/")! } ?? feed.fileBase
            fileURL = URL(string: raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw, relativeTo: base)?.absoluteURL
        } else {
            fileURL = nil
        }
        let notes = manifest["releaseNotes"]?.string.map { ReleaseNotes(text: $0, format: $0.contains("<") ? .html : .markdown) }
        return Release(
            source: .electron,
            version: VersionPair(short: version),
            basis: .shortVersion,
            downloadURL: fileURL,
            downloadPage: feed.github?.releasesPage,
            releaseNotes: notes,
            minimumOS: manifest["minimumSystemVersion"]?.string,
            date: manifest["releaseDate"]?.string.flatMap(Self.parseDate),
            sha512: file["sha512"]?.nilIfEmpty,
            length: file["size"].flatMap { Int64($0) }
        )
    }

    /// Prefers a zip (what electron-updater installs on macOS), built for this Mac's processor.
    func pickFile(_ files: [[String: String]]) -> [String: String]? {
        func score(_ file: [String: String]) -> Int {
            let name = (file["url"] ?? "").lowercased()
            var s = 0
            if name.hasSuffix(".zip") { s += 4 } else if name.hasSuffix(".dmg") { s += 2 } else { s -= 10 }
            let arm = name.contains("arm64") || name.contains("aarch64")
            let intel = name.contains("x64") || name.contains("x86_64") || name.contains("intel")
            let universal = name.contains("universal") || (!arm && !intel)
            if isARM { s += arm ? 3 : (universal ? 2 : -5) } else { s += intel ? 3 : (universal ? 2 : -5) }
            return s
        }
        return files.filter { $0["url"] != nil }.max { score($0) < score($1) }.flatMap { score($0) > 0 ? $0 : nil }
    }

    static func parseDate(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
