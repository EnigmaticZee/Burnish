import Foundation

/// What Homebrew's Caskroom says it installed. Apps found here are "Managed by Homebrew":
/// Burnish shows their status and leaves the update to `brew upgrade --cask`.
public struct CaskroomScan: Sendable, Hashable {
    /// Cask token → `.app` names it installed. Empty when the metadata didn't say.
    public var installed: [String: [String]]
    /// Cask token → version folders in the Caskroom.
    public var versions: [String: [String]]

    public init(installed: [String: [String]] = [:], versions: [String: [String]] = [:]) {
        self.installed = installed
        self.versions = versions
    }

    public var tokens: [String] { installed.keys.sorted() }

    /// The cask that installed this app. When several claim it (`iterm2` and `iterm2@beta`),
    /// the one whose Caskroom version matches wins, then a token without a channel, then the
    /// alphabetically first, so the answer never depends on dictionary order.
    public func token(forAppNamed fileName: String, version: String? = nil) -> String? {
        index().token(forAppNamed: fileName, version: version)
    }

    /// The same answers from an index built once, for a whole scan rather than once per app.
    public func index() -> Index {
        var claims: [String: Set<String>] = [:]
        for (token, apps) in installed {
            for app in apps { claims[app.lowercased(), default: []].insert(token) }
        }
        return Index(claims: claims.mapValues { $0.sorted() }, shortVersions: versions.mapValues { Set($0.map(Self.short)) })
    }

    /// `1.2.3,456` → `1.2.3`: a Caskroom version without its build part.
    static func short(_ version: String) -> String {
        version.split(separator: ",").first.map(String.init) ?? version
    }

    /// Lowercased `.app` name → the tokens that claim it, answering `token(forAppNamed:version:)`.
    public struct Index: Sendable {
        let claims: [String: [String]]
        let shortVersions: [String: Set<String>]

        public func token(forAppNamed fileName: String, version: String? = nil) -> String? {
            guard let claims = claims[fileName.lowercased()] else { return nil }
            guard claims.count > 1 else { return claims.first }
            if let version {
                let short = CaskroomScan.short(version)
                let matching = claims.filter { shortVersions[$0]?.contains(short) ?? false }
                if matching.count == 1 { return matching[0] }
            }
            return claims.first { !$0.contains("@") } ?? claims.first
        }
    }
}

struct CaskroomScanner {
    let roots: [URL]

    /// `app "Foo.app"` in a cask file; the capture is the quoted path. Built once: `Regex` is
    /// immutable, it just hasn't been marked `Sendable`.
    nonisolated(unsafe) private static let appLine = /^\s*app\s+"([^"]+\.app)"/.anchorsMatchLineEndings()

    func scan() -> CaskroomScan {
        let fm = FileManager.default
        var installed: [String: [String]] = [:]
        var versions: [String: [String]] = [:]
        for root in roots {
            guard let tokens = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for token in tokens where !token.hasPrefix(".") {
                let dir = root.appendingPathComponent(token)
                installed[token, default: []].append(contentsOf: appNames(in: dir))
                versions[token, default: []].append(contentsOf: ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") })
            }
        }
        return CaskroomScan(installed: installed, versions: versions)
    }

    /// Reads app names from Homebrew's install receipt, or from the cask file saved at install time.
    func appNames(in caskDir: URL) -> [String] {
        let metadata = caskDir.appendingPathComponent(".metadata")
        if let data = try? Data(contentsOf: metadata.appendingPathComponent("INSTALL_RECEIPT.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let artifacts = json["uninstall_artifacts"] as? [[String: Any]] {
            let names = Self.apps(fromArtifacts: artifacts)
            if !names.isEmpty { return names }
        }
        // .metadata/<version>/<timestamp>/Casks/<token>.json (or .rb)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: metadata, includingPropertiesForKeys: nil) else { return [] }
        var newest: (file: URL, date: Date)?
        for case let file as URL in enumerator where file.deletingLastPathComponent().lastPathComponent == "Casks" {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let newest, date <= newest.date { continue }
            newest = (file, date)
        }
        guard let file = newest?.file, let data = try? Data(contentsOf: file) else { return [] }
        if file.pathExtension == "json",
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let artifacts = json["artifacts"] as? [[String: Any]] {
            return Self.apps(fromArtifacts: artifacts)
        }
        let source = String(decoding: data, as: UTF8.self)
        return source.matches(of: Self.appLine).map { (String($0.output.1) as NSString).lastPathComponent }
    }

    /// `{"app": ["Foo.app"], "target": "/Applications/Foo.app"}`; `app "Foo.app", target: "Bar.app"`
    /// installs as Bar.app, so a target wins over the source name.
    static func apps(fromArtifacts artifacts: [[String: Any]]) -> [String] {
        var names: [String] = []
        for artifact in artifacts {
            guard let apps = artifact["app"] as? [Any] else { continue }
            if let target = artifact["target"] as? String, target.hasSuffix(".app") {
                names.append((target as NSString).lastPathComponent)
            } else if let target = apps.lazy.compactMap({ ($0 as? [String: Any])?["target"] as? String }).first {
                names.append((target as NSString).lastPathComponent)
            } else {
                names += apps.compactMap { $0 as? String }.map { ($0 as NSString).lastPathComponent }
            }
        }
        return Array(Set(names)).sorted()
    }
}
