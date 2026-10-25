import Foundation
import Versions

/// One app found on disk, with everything Burnish needs to find its update source.
public struct InstalledApp: Sendable, Hashable, Codable, Identifiable {
    public var id: String { url.path }

    public let bundleID: String
    /// What Finder shows: the file name without `.app`.
    public let name: String
    /// `CFBundleName` and `CFBundleDisplayName`, used as matching hints.
    public let bundleNames: [String]
    public let url: URL
    public let version: VersionPair
    public let signature: CodeSignature
    public let isAppStore: Bool
    /// An iPhone or iPad app running on a Mac with Apple silicon.
    public let isWrappedIOSApp: Bool
    public let sparkleFeedURL: URL?
    public let sparklePublicEDKey: String?
    /// Set when the app sits in Homebrew's Caskroom (installed by `brew install --cask`).
    public var caskroomToken: String?
    /// `Contents/Resources/app-update.yml` for apps built with electron-builder.
    public let electronUpdateConfig: URL?
    /// Updater endpoints compiled into a Tauri app's executable.
    public let tauriUpdateEndpoints: [String]?
    /// Processors the executable has code for (`arm64`, `x86_64`), when it could be read.
    public let architectures: [String]?
    public let minimumSystemVersion: String?
    public let modificationDate: Date?

    public init(
        bundleID: String, name: String, bundleNames: [String] = [], url: URL, version: VersionPair,
        signature: CodeSignature = .unsigned, isAppStore: Bool = false, isWrappedIOSApp: Bool = false,
        sparkleFeedURL: URL? = nil, sparklePublicEDKey: String? = nil, caskroomToken: String? = nil,
        electronUpdateConfig: URL? = nil, tauriUpdateEndpoints: [String]? = nil, architectures: [String]? = nil,
        minimumSystemVersion: String? = nil, modificationDate: Date? = nil
    ) {
        self.bundleID = bundleID
        self.name = name
        self.bundleNames = bundleNames
        self.url = url
        self.version = version
        self.signature = signature
        self.isAppStore = isAppStore
        self.isWrappedIOSApp = isWrappedIOSApp
        self.sparkleFeedURL = sparkleFeedURL
        self.sparklePublicEDKey = sparklePublicEDKey
        self.caskroomToken = caskroomToken
        self.electronUpdateConfig = electronUpdateConfig
        self.tauriUpdateEndpoints = tauriUpdateEndpoints
        self.architectures = architectures
        self.minimumSystemVersion = minimumSystemVersion
        self.modificationDate = modificationDate
    }

    /// `Google Chrome.app`
    public var fileName: String { url.lastPathComponent }
    public var shortVersion: String { version.short ?? version.build ?? "" }
    public var buildVersion: String? { version.build }
    public var teamID: String? { signature.teamID }

    /// Has Intel code and no Apple silicon code, so it runs through Rosetta on Apple silicon.
    public var isIntelOnly: Bool {
        guard let architectures, !architectures.isEmpty else { return false }
        return !architectures.contains("arm64") && architectures.contains("x86_64")
    }
    public var isManagedByHomebrew: Bool { caskroomToken != nil }
    /// Apple's own apps outside the App Store are updated by Software Update.
    public var isApple: Bool { bundleID.hasPrefix("com.apple.") }
}

/// What the code signature says about who made the app. Read without full validation;
/// the installer validates the new copy before using any of this.
public struct CodeSignature: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        case unsigned
        case adHoc
        /// Signed by Apple as part of macOS.
        case apple
        /// Re-signed by the Mac App Store.
        case appStore
        case developerID
        /// An "Apple Development" certificate: runs only on the developer's Macs.
        case development
        case other
    }

    public let kind: Kind
    public let teamID: String?
    public let identifier: String?
    /// The leaf certificate's name, such as "Developer ID Application: Google LLC (EQHXZ8M8AV)".
    public let authority: String?

    public init(kind: Kind, teamID: String? = nil, identifier: String? = nil, authority: String? = nil) {
        self.kind = kind
        self.teamID = teamID
        self.identifier = identifier
        self.authority = authority
    }

    public static let unsigned = CodeSignature(kind: .unsigned)

    /// Rule 4: an installed app without a Team ID is never auto-updated.
    public var canBeAutoUpdated: Bool {
        guard let teamID, !teamID.isEmpty else { return false }
        return kind == .developerID || kind == .other
    }
}
