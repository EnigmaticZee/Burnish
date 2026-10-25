import Foundation
import Versions

/// Where Burnish learned about a version. Order matters: the developer's own feed wins.
public enum SourceKind: String, Sendable, Codable, CaseIterable, Comparable {
    case appStore
    case sparkle
    case electron
    case tauri
    case homebrew
    case github

    public var label: String {
        switch self {
        case .appStore: String(localized: "App Store")
        case .sparkle: String(localized: "Developer feed")
        case .electron: String(localized: "Developer feed")
        case .tauri: String(localized: "Developer feed")
        case .homebrew: String(localized: "Homebrew")
        case .github: String(localized: "GitHub")
        }
    }

    public static func < (a: SourceKind, b: SourceKind) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// The newest release a source offers that this Mac can run.
public struct Release: Sendable, Hashable, Codable {
    public var source: SourceKind
    public var version: VersionPair
    public var basis: Basis
    public var downloadURL: URL?
    /// Where a person can download it by hand: the fallback for every refused install.
    public var downloadPage: URL?
    public var releaseNotes: ReleaseNotes?
    public var minimumOS: String?
    public var date: Date?
    /// Hex SHA-256 from Homebrew or a GitHub asset digest.
    public var sha256: String?
    /// Base64 SHA-512 from electron-builder's `latest-mac.yml`.
    public var sha512: String?
    /// Base64 Ed25519 signature from a Sparkle appcast.
    public var edSignature: String?
    public var length: Int64?
    /// Sparkle "informational" updates point at a web page and have nothing to install.
    public var isInformational: Bool
    public var isCritical: Bool
    /// The download is (or contains) an installer package; Burnish opens it in Apple's Installer.
    public var installsPkg: Bool
    /// Homebrew says this needs a vendor installer; Burnish only opens the download page.
    public var needsManualInstall: Bool
    public var appStoreID: Int?
    public var caskToken: String?
    /// Sparkle's `minimumAutoupdateVersion`: below this build the developer wants a manual
    /// (often paid) upgrade, so Burnish treats it as a major upgrade and doesn't install it.
    public var minimumAutoupdateVersion: String?
    /// Found through a feed a contributor listed, not one the app or Homebrew names. Burnish
    /// reads it to spot updates and leaves the install to the person (install rule 1).
    public var listedByCommunity: Bool?
    /// Versions between the installed one and this, newest first, when the feed lists them.
    public var missed: [MissedRelease]?

    /// `ComparisonBasis` as a Codable value.
    public enum Basis: String, Sendable, Codable {
        case shortVersion, bundleVersion
        public var comparison: ComparisonBasis { self == .shortVersion ? .shortVersion : .bundleVersion }
    }

    public init(
        source: SourceKind, version: VersionPair, basis: Basis, downloadURL: URL? = nil, downloadPage: URL? = nil,
        releaseNotes: ReleaseNotes? = nil, minimumOS: String? = nil, date: Date? = nil, sha256: String? = nil,
        sha512: String? = nil, edSignature: String? = nil, length: Int64? = nil, isInformational: Bool = false,
        isCritical: Bool = false, installsPkg: Bool = false, needsManualInstall: Bool = false,
        appStoreID: Int? = nil, caskToken: String? = nil, minimumAutoupdateVersion: String? = nil
    ) {
        self.source = source
        self.version = version
        self.basis = basis
        self.downloadURL = downloadURL
        self.downloadPage = downloadPage
        self.releaseNotes = releaseNotes
        self.minimumOS = minimumOS
        self.date = date
        self.sha256 = sha256
        self.sha512 = sha512
        self.edSignature = edSignature
        self.length = length
        self.isInformational = isInformational
        self.isCritical = isCritical
        self.installsPkg = installsPkg
        self.needsManualInstall = needsManualInstall
        self.appStoreID = appStoreID
        self.caskToken = caskToken
        self.minimumAutoupdateVersion = minimumAutoupdateVersion
    }

    /// Sparkle's rule: an installed build below `minimumAutoupdateVersion` must be upgraded by hand.
    public func wantsManualUpgrade(from installed: VersionPair) -> Bool {
        guard let minimum = minimumAutoupdateVersion.flatMap(Version.init),
              let current = (installed.build ?? installed.short).flatMap(Version.init) else { return false }
        return current < minimum
    }

    public func compare(with installed: VersionPair) -> UpdateVerdict {
        UpdateComparator.compare(installed: installed, available: version, basis: basis.comparison)
    }
}

/// Release notes as the source gave them. Rendered through `ReleaseNotesDocument`, never as raw HTML.
public struct ReleaseNotes: Sendable, Hashable, Codable {
    public enum Format: String, Sendable, Codable { case html, plainText, markdown }

    public var text: String?
    public var format: Format
    /// A page to fetch on demand (Sparkle `releaseNotesLink`) or open in the browser.
    public var link: URL?

    public init(text: String?, format: Format, link: URL? = nil) {
        self.text = text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.format = format
        self.link = link
    }

}

/// A version the person skipped, for "what you missed".
public struct MissedRelease: Sendable, Hashable, Codable, Identifiable {
    public var id: String { version }
    public let version: String
    public let date: Date?
    public let notes: ReleaseNotes?

    public init(version: String, date: Date?, notes: ReleaseNotes?) {
        self.version = version
        self.date = date
        self.notes = notes
    }
}

/// The macOS version this Mac runs, for minimum-system checks.
public struct SystemVersion: Sendable, Hashable {
    public let version: Version

    public init(_ string: String) { version = Version(string) ?? Version("14.0")! }

    public static var current: SystemVersion {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return SystemVersion("\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
    }

    public var major: Int { version.major ?? 14 }

    /// True when `minimum` (such as `12.7.6`) is at or below this Mac's version. Unreadable values pass.
    public func satisfies(minimum: String?) -> Bool {
        guard let minimum, let required = Version(minimum) else { return true }
        return version >= required
    }

    public func satisfies(maximum: String?) -> Bool {
        guard let maximum, let limit = Version(maximum) else { return true }
        return version <= limit
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
