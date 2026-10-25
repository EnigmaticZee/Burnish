import Foundation
import Versions

/// The parts of one Homebrew cask that Burnish uses, already resolved for this Mac's
/// processor and macOS version.
public struct Cask: Sendable, Hashable, Codable, Identifiable {
    public var id: String { token }

    public let token: String
    public let names: [String]
    public let homepage: URL?
    /// `version` as Homebrew writes it, such as `1.2.3,456` or `latest`.
    public let version: String
    /// Hex SHA-256, or nil when the cask says `no_check`.
    public let sha256: String?
    public let url: URL?
    /// `.app` names the cask installs, after any `target:` rename.
    public let appNames: [String]
    /// `.app` names a cask without an `app` stanza (a `.pkg` or vendor installer) deletes from
    /// `/Applications` on uninstall: the app it installs.
    public let uninstallAppNames: [String]
    /// Bundle IDs the cask asks to quit before installing, in order.
    public let quitBundleIDs: [[String]]
    /// Bundle-ID-looking strings from `zap`, `launchctl`, `pkgutil` and file paths. Hints only.
    public let hintBundleIDs: [String]
    public let minimumMacOS: String?
    /// For `depends_on macos: [...]` lists of exact versions.
    public let allowedMacOS: [String]?
    public let deprecated: Bool
    public let disabled: Bool
    public let deprecationReason: String?
    public let autoUpdates: Bool
    /// The cask installs with a `.pkg`; Burnish opens those in Apple's Installer.
    public let installsPkg: Bool
    /// The cask runs a vendor installer app, or nests archives, so Burnish only opens the download page.
    public let needsManualInstall: Bool
    /// Homebrew says the app needs Rosetta: there's no Apple silicon build.
    public let requiresRosetta: Bool

    public var versionPair: VersionPair { VersionPair.fromCask(version) }
    public var isLatestVersion: Bool { version.lowercased() == "latest" }

    /// The channel part of a token: `beta` for `firefox@beta`.
    public var channel: String? {
        guard let at = token.firstIndex(of: "@") else { return nil }
        return String(token[token.index(after: at)...])
    }

    /// The token without its channel: `firefox` for `firefox@beta`.
    public var baseToken: String {
        token.firstIndex(of: "@").map { String(token[..<$0]) } ?? token
    }

    public static let prereleaseChannels: Set<String> = [
        "beta", "nightly", "dev", "devel", "develop", "development", "preview", "canary", "alpha", "rc",
        "insiders", "edge", "eap", "test", "pretest", "prerelease", "tip", "next", "ptb", "unstable", "snapshot",
    ]

    public var isPrereleaseChannel: Bool {
        if let channel, Self.prereleaseChannels.contains(channel.lowercased()) { return true }
        return versionPair.short.flatMap(Version.init)?.isPrerelease ?? false
    }

    /// Whether this Mac's macOS can run the cask's current version.
    public func supports(macOS major: Int) -> Bool {
        if let allowed = allowedMacOS, !allowed.isEmpty {
            return allowed.contains { Int($0.split(separator: ".").first ?? "") == major }
        }
        if let minimumMacOS, let minMajor = Int(minimumMacOS.split(separator: ".").first ?? "") {
            return major >= minMajor
        }
        return true
    }
}

// MARK: Decoding Homebrew's JSON

extension Cask {
    /// Builds a cask from one entry of `cask.json`, applying the variation for `platform`.
    init?(json: [String: Any], platform: Platform) {
        guard let token = json["token"] as? String else { return nil }
        var fields = json
        if let variations = json["variations"] as? [String: Any], let variation = variations[platform.variationKey] as? [String: Any] {
            for (key, value) in variation { fields[key] = value }
        }
        guard let version = fields["version"] as? String else { return nil }

        let artifacts = fields["artifacts"] as? [[String: Any]] ?? []
        var appNames: [String] = []
        var uninstallAppNames: [String] = []
        var quit: [[String]] = []
        var hints: [String] = []
        let installsPkg = artifacts.contains { $0["pkg"] != nil }
        let hasAppStanza = artifacts.contains { $0["app"] != nil }
        var manual = false

        for artifact in artifacts {
            if let apps = artifact["app"] as? [Any] {
                if let target = artifact["target"] as? String, target.hasSuffix(".app") {
                    appNames.append(target.lastPathComponent)
                } else if let target = apps.lazy.compactMap({ ($0 as? [String: Any])?["target"] as? String }).first {
                    appNames.append(target.lastPathComponent)
                }
                appNames += apps.compactMap { $0 as? String }.map(\.lastPathComponent)
            }
            if artifact["installer"] != nil { manual = true }
            for key in ["uninstall", "zap"] {
                guard let directives = artifact[key] as? [Any] else { continue }
                for case let directive as [String: Any] in directives {
                    if key == "uninstall", let q = directive["quit"] {
                        let ids = Self.strings(q)
                        if !ids.isEmpty { quit.append(ids) }
                    }
                    if let signals = directive["signal"] as? [[Any]] {
                        let ids = signals.compactMap { $0.last as? String }
                        if !ids.isEmpty { quit.append(ids) }
                    }
                    for hintKey in ["launchctl", "pkgutil", "quit", "login_item"] {
                        hints += Self.strings(directive[hintKey]).compactMap(Self.bundleID(fromComponent:))
                    }
                    for pathKey in ["trash", "delete", "rmdir"] {
                        for path in Self.strings(directive[pathKey]) {
                            hints += Self.bundleIDs(inPath: path)
                            if key == "uninstall", !hasAppStanza, path.hasPrefix("/Applications/"), path.hasSuffix(".app"), !path.contains("*") {
                                uninstallAppNames.append(path.lastPathComponent)
                            }
                        }
                    }
                }
            }
        }
        if let container = fields["container"] as? [String: Any], container["nested"] != nil { manual = true }

        let macos = (fields["depends_on"] as? [String: Any])?["macos"] as? [String: Any]
        let sha = fields["sha256"] as? String

        self.token = token
        self.names = Self.strings(fields["name"])
        self.homepage = (fields["homepage"] as? String).flatMap(URL.init(string:))
        let arch = (fields["depends_on"] as? [String: Any])?["arch"] as? [[String: Any]] ?? []
        self.requiresRosetta = (fields["caveats_rosetta"] as? Bool ?? false) || (!arch.isEmpty && arch.allSatisfy { $0["type"] as? String == "intel" })
        self.version = version
        self.sha256 = (sha == nil || sha == "no_check") ? nil : sha?.lowercased()
        self.url = (fields["url"] as? String).flatMap(URL.init(string:))
        self.appNames = Self.unique(appNames)
        self.uninstallAppNames = Self.unique(uninstallAppNames)
        self.quitBundleIDs = quit
        self.hintBundleIDs = Self.unique(hints.map { $0.lowercased() })
        self.minimumMacOS = (macos?[">="] as? [Any])?.first.map { "\($0)" }
        self.allowedMacOS = (macos?["=="] as? [Any])?.map { "\($0)" }
        self.deprecated = fields["deprecated"] as? Bool ?? false
        self.disabled = fields["disabled"] as? Bool ?? false
        self.deprecationReason = (fields["disable_reason"] as? String) ?? (fields["deprecation_reason"] as? String)
        self.autoUpdates = fields["auto_updates"] as? Bool ?? false
        self.installsPkg = installsPkg
        self.needsManualInstall = manual
    }

    static func strings(_ value: Any?) -> [String] {
        if let s = value as? String { return [s] }
        if let list = value as? [Any] { return list.compactMap { $0 as? String } }
        return []
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// `~/Library/Preferences/com.knollsoft.Rectangle.plist` → `com.knollsoft.Rectangle`
    static func bundleIDs(inPath path: String) -> [String] {
        path.split(separator: "/").compactMap { bundleID(fromComponent: String($0)) }
    }

    static let fileSuffixes = [
        ".plist", ".savedstate", ".binarycookies", ".sfl4", ".sfl3", ".sfl2", ".sfl", ".help", ".helper",
        ".daemon", ".agent", ".log", ".db", ".sqlite", ".pkg", ".app", ".appex", ".bundle", ".lock", ".json",
    ]

    static func bundleID(fromComponent component: String) -> String? {
        var s = component
        if let star = s.firstIndex(of: "*") { s = String(s[..<star]) }
        while s.hasSuffix(".") { s.removeLast() }
        var changed = true
        while changed {
            changed = false
            for suffix in fileSuffixes where s.lowercased().hasSuffix(suffix) {
                s.removeLast(suffix.count)
                changed = true
            }
        }
        var labels = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        // Team-ID prefix (`2BUA8C4S2C.com.1password`) and app groups (`group.com.x.y`).
        if let first = labels.first, first.count == 10, first.allSatisfy({ $0.isUppercase || $0.isNumber }) {
            labels.removeFirst()
        }
        if labels.first == "group" { labels.removeFirst() }
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
              labels.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }),
              let first = labels.first?.first, first.isLetter
        else { return nil }
        return labels.joined(separator: ".")
    }
}

extension String {
    var lastPathComponent: String { (self as NSString).lastPathComponent }
}
