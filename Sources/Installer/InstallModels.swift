import Foundation
import Inventory
import UpdateSources

/// What the installer is doing, for the row's progress line (the "Installing" state).
public enum InstallPhase: Sendable, Equatable {
    case downloading(received: Int64, total: Int64?)
    case verifying
    case waitingForQuit
    case replacing
    case relaunching
}

extension InstallPhase {
    /// "Downloading 42%", "Verifying", … for progress lines.
    public var label: String {
        switch self {
        case let .downloading(received, total):
            if let total, total > 0 {
                return String(localized: "Downloading \(Int(Double(received) / Double(total) * 100))%")
            }
            return received > 0 ? String(localized: "Downloading \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file))") : String(localized: "Downloading")
        case .verifying: return String(localized: "Verifying")
        case .waitingForQuit: return String(localized: "Waiting for the app to quit")
        case .replacing: return String(localized: "Replacing")
        case .relaunching: return String(localized: "Relaunching")
        }
    }

    public var fraction: Double? {
        if case let .downloading(received, total?) = self, total > 0 { return min(Double(received) / Double(total), 1) }
        return nil
    }
}

public enum InstallOutcome: Sendable, Equatable {
    /// Done. The old version is in the Trash at `oldCopy`.
    case installed(oldCopy: URL?, relaunched: Bool)
    /// A `.pkg` was verified and opened in Apple's Installer, which the person drives (rule 5).
    case openedInInstaller(URL)
    /// A safety check failed. The installed app wasn't touched.
    case refused(InstallRefusal)
    case cancelled
}

/// Why an install didn't happen, in words a person can act on, plus the page to get it by hand.
public struct InstallRefusal: Error, Sendable, Equatable, LocalizedError {
    public enum Rule: String, Sendable, Codable {
        /// Rule 1: the download didn't come from the app's feed or Homebrew over HTTPS.
        case trustedOrigin
        /// Rule 2: Sparkle EdDSA signature.
        case publisherSignature
        /// Rule 3: SHA-256 / SHA-512.
        case checksum
        /// Rule 4: valid signature, Gatekeeper, same bundle ID and Team ID.
        case sameDeveloper
        /// Rule 4: the installed copy has no developer signature.
        case unsignedInstalledApp
        /// Rule 5: installer packages only open in Apple's Installer.
        case package
        /// Rule 7/8: moving files failed or needed a permission.
        case replace
        /// An administrator was needed and the prompt didn't succeed.
        case permission
        /// macOS's App Management permission is off, so no app can be replaced.
        case appManagement
        /// The source has nothing Burnish can install by itself.
        case manualOnly
        case download
        case unpack
        case notNewer
        /// The app on disk isn't the one Burnish checked.
        case changedSinceCheck
    }

    public let rule: Rule
    public let message: String
    public let downloadPage: URL?

    public init(_ rule: Rule, _ message: String, downloadPage: URL?) {
        self.rule = rule
        self.message = message
        self.downloadPage = downloadPage
    }

    public var errorDescription: String? { message }
}

public struct InstallRequest: Sendable {
    public let app: InstalledApp
    public let release: Release
    /// `.app` names the cask says it installs, to find the right bundle in a download.
    public let expectedAppNames: [String]

    public init(app: InstalledApp, release: Release, expectedAppNames: [String] = []) {
        self.app = app
        self.release = release
        self.expectedAppNames = expectedAppNames
    }

    var downloadPage: URL? { release.downloadPage }
}

// MARK: Seams, so every safety rule is testable in a temporary folder

/// Gatekeeper's assessment of a downloaded app (rule 4).
public protocol GatekeeperAssessing: Sendable {
    func assess(_ app: URL) async -> Bool
}

/// Full code-signature validation of a downloaded app (rule 4).
public protocol SignatureValidating: Sendable {
    /// Throws unless the app's signature is valid, Apple-anchored and belongs to `teamID`.
    func validate(_ app: URL, teamID: String) throws
}

/// Who signed an installer package (rule 5: opened in Installer only if it's the same developer).
public protocol PackageSignatureReading: Sendable {
    func teamID(ofPackage url: URL) async -> String?
}

public protocol RunningAppControlling: Sendable {
    /// Process IDs of running copies launched from exactly this bundle.
    func running(_ app: URL) async -> [pid_t]
    /// Asks politely (the same as choosing Quit). Never force-quits.
    func requestQuit(_ pid: pid_t) async
    func isRunning(_ pid: pid_t) async -> Bool
    func relaunch(_ app: URL) async
}

/// Moves the old version to the Trash. Tests use a folder instead of the real Trash.
public protocol Trashing: Sendable {
    func trash(_ url: URL) throws -> URL?
}

/// Moving the new copy into place, with an admin-prompt fallback (rule 8).
public protocol FileOperating: Sendable {
    func isWritable(_ directory: URL) -> Bool
    func move(_ source: URL, to destination: URL) throws
    /// Replace `old` with `new` as an administrator, keeping the old copy at `trashTarget`, and
    /// re-check the copied app against `requirement` as root before keeping it.
    func privilegedReplace(old: URL, new: URL, trashTarget: URL, requirement: String, appName: String) async throws
}

/// Opens a verified `.pkg` in Apple's Installer.
public protocol PackageOpening: Sendable {
    func open(_ package: URL) async
}

public enum QuitDecision: Sendable {
    case tryAgain
    case cancel
}
