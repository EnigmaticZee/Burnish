import CaskIndex
import Foundation
import Inventory
import UpdateSources
import Versions

/// A newer release, plus whether it looks like a paid major upgrade.
public struct UpdateCandidate: Sendable, Hashable, Codable {
    public let release: Release
    public let isMajorUpgrade: Bool

    public init(release: Release, isMajorUpgrade: Bool) {
        self.release = release
        self.isMajorUpgrade = isMajorUpgrade
    }

    public var source: SourceKind { release.source }
    public var version: VersionPair { release.version }
    public var displayVersion: String { release.version.display }
}

public enum IgnoreKind: Sendable, Hashable, Codable {
    case app
    case version(String)
}

/// The honest outcome for one app. Only `.outdated` ever says "Update available".
public enum CheckStatus: Sendable, Hashable, Codable {
    case upToDate(note: String?)
    case outdated(UpdateCandidate)
    case needsConfirmation(CaskMatch)
    case cantCheck(reason: String)
    case ignored(IgnoreKind, UpdateCandidate?)

    public var candidate: UpdateCandidate? {
        switch self {
        case let .outdated(c): c
        case let .ignored(_, c): c
        default: nil
        }
    }

    public var isOutdated: Bool { if case .outdated = self { true } else { false } }

    public var tab: StatusTab {
        switch self {
        case .upToDate: .upToDate
        case .outdated: .updates
        case .needsConfirmation: .needsConfirmation
        case .cantCheck: .cantCheck
        case .ignored: .ignored
        }
    }
}

/// The main window's five tabs.
public enum StatusTab: String, Sendable, CaseIterable, Codable, Identifiable {
    case updates, upToDate, needsConfirmation, cantCheck, ignored

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .updates: String(localized: "Updates")
        case .upToDate: String(localized: "Up to date")
        case .needsConfirmation: String(localized: "Needs confirmation")
        case .cantCheck: String(localized: "Can't check")
        case .ignored: String(localized: "Ignored")
        }
    }

    public var symbol: String {
        switch self {
        case .updates: "arrow.down.circle"
        case .upToDate: "checkmark.circle"
        case .needsConfirmation: "questionmark.circle"
        case .cantCheck: "minus.circle"
        case .ignored: "eye.slash"
        }
    }
}

/// Facts about the matched cask that the detail pane shows.
public struct CaskSummary: Sendable, Hashable, Codable {
    public let token: String
    public let name: String?
    public let homepage: URL?
    public let version: String
    public let isDeprecated: Bool
    public let isDisabled: Bool
    public let reason: String?

    public init(_ cask: Cask) {
        token = cask.token
        name = cask.names.first
        homepage = cask.homepage
        version = cask.version
        isDeprecated = cask.deprecated
        isDisabled = cask.disabled
        reason = cask.deprecationReason
    }

    public var isUnmaintained: Bool { isDeprecated || isDisabled }
}

public struct AppCheckResult: Sendable, Hashable, Codable, Identifiable {
    public var id: String { app.id }

    public var app: InstalledApp
    public var status: CheckStatus
    /// Which source decided the status.
    public var decidedBy: SourceKind?
    public var match: CaskMatch?
    public var cask: CaskSummary?
    /// Short, plain notes for the detail pane ("Feed not reachable; used Homebrew's data").
    public var notes: [String]
    public var checkedAt: Date

    public init(app: InstalledApp, status: CheckStatus, decidedBy: SourceKind? = nil, match: CaskMatch? = nil,
                cask: CaskSummary? = nil, notes: [String] = [], checkedAt: Date = Date()) {
        self.app = app
        self.status = status
        self.decidedBy = decidedBy
        self.match = match
        self.cask = cask
        self.notes = notes
        self.checkedAt = checkedAt
    }

    public var homepage: URL? { cask?.homepage ?? status.candidate?.release.downloadPage }

    /// Where a person can get the update by hand.
    public var downloadPage: URL? { status.candidate?.release.downloadPage ?? cask?.homepage }
}

public struct CheckReport: Sendable, Codable {
    public var results: [AppCheckResult]
    public var startedAt: Date
    public var finishedAt: Date
    /// When the Homebrew data was last confirmed current.
    public var caskDataDate: Date?
    /// True when the cask list came from the offline cache.
    public var isOffline: Bool
    public var problems: [String]

    public init(results: [AppCheckResult], startedAt: Date, finishedAt: Date, caskDataDate: Date?, isOffline: Bool, problems: [String]) {
        self.results = results
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.caskDataDate = caskDataDate
        self.isOffline = isOffline
        self.problems = problems
    }

}
