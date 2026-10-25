import CaskIndex
import Foundation
import Versions

/// Turns a matched cask into a release. Homebrew gives a version, a download and maybe a
/// checksum, but no release notes: only a link to the app's homepage.
public enum HomebrewSource {
    public static func release(for cask: Cask) -> Release {
        Release(
            source: .homebrew,
            version: cask.versionPair,
            basis: .shortVersion,
            downloadURL: cask.needsManualInstall ? nil : cask.url,
            downloadPage: cask.homepage,
            releaseNotes: cask.homepage.map { ReleaseNotes(text: nil, format: .html, link: $0) },
            minimumOS: cask.minimumMacOS,
            sha256: cask.sha256,
            installsPkg: cask.installsPkg,
            needsManualInstall: cask.needsManualInstall,
            caskToken: cask.token
        )
    }

    /// `https://github.com/owner/repo/releases/download/...` → (owner, repo)
    public static func githubRepository(for cask: Cask) -> GitHubRepository? {
        cask.url.flatMap(GitHubRepository.init(releaseAssetURL:))
    }
}

public struct GitHubRepository: Sendable, Hashable, Codable {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    /// Accepts release-asset URLs on github.com only.
    public init?(releaseAssetURL url: URL) {
        guard url.scheme == "https", url.host?.lowercased() == "github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[2] == "releases" else { return nil }
        self.init(owner: parts[0], name: parts[1])
    }

    public var releasesPage: URL { URL(string: "https://github.com/\(owner)/\(name)/releases")! }
}
