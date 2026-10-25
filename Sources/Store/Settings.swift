import Foundation

public enum CheckFrequency: String, Sendable, Codable, CaseIterable, Identifiable {
    case twiceDaily, daily, weekly, manual

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .twiceDaily: String(localized: "Twice a day")
        case .daily: String(localized: "Once a day")
        case .weekly: String(localized: "Once a week")
        case .manual: String(localized: "Only when I ask")
        }
    }

    public var interval: TimeInterval? {
        switch self {
        case .twiceDaily: 12 * 3600
        case .daily: 24 * 3600
        case .weekly: 7 * 24 * 3600
        case .manual: nil
        }
    }
}

/// What to do with apps installed by `brew install --cask`.
public enum HomebrewHandling: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Show their status; leave updating to `brew upgrade`.
    case showOnly
    /// Leave them out of Burnish entirely.
    case hide
    /// Run `brew upgrade --cask <token>` when asked to update.
    case upgradeWithBrew

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .showOnly: String(localized: "Show, don't update")
        case .hide: String(localized: "Hide")
        case .upgradeWithBrew: String(localized: "Update with brew upgrade")
        }
    }
}

/// How long a new version has to be out before Burnish installs it on its own.
public enum AutoUpdateWait: String, Sendable, Codable, CaseIterable, Identifiable {
    case none, oneDay, threeDays, oneWeek

    public var id: String { rawValue }

    public var days: Int {
        switch self {
        case .none: 0
        case .oneDay: 1
        case .threeDays: 3
        case .oneWeek: 7
        }
    }

    public var label: String {
        switch self {
        case .none: String(localized: "Don't wait")
        case .oneDay: String(localized: "1 day")
        case .threeDays: String(localized: "3 days")
        case .oneWeek: String(localized: "1 week")
        }
    }
}

/// Settings. Missing keys fall back to defaults, so old files keep working.
public struct Settings: Sendable, Codable, Equatable {
    public var checkFrequency: CheckFrequency = .daily
    public var notificationsEnabled = true
    public var launchAtLogin = false
    public var scanUserApplications = true
    public var homebrewHandling: HomebrewHandling = .showOnly
    /// Sends installed App Store bundle IDs to Apple's lookup. Off for people who'd rather not.
    public var appStoreLookups = true
    /// Fetch the community match fixes from Burnish's GitHub repository.
    public var communityOverrides = true
    /// Install minor updates on their own, for apps that aren't open, after `autoUpdateWait`.
    public var autoUpdate = false
    public var autoUpdateWait: AutoUpdateWait = .threeDays
    public var hasCompletedOnboarding = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        checkFrequency = (try? c.decodeIfPresent(CheckFrequency.self, forKey: .checkFrequency)) ?? d.checkFrequency
        notificationsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)) ?? d.notificationsEnabled
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? d.launchAtLogin
        scanUserApplications = (try? c.decodeIfPresent(Bool.self, forKey: .scanUserApplications)) ?? d.scanUserApplications
        homebrewHandling = (try? c.decodeIfPresent(HomebrewHandling.self, forKey: .homebrewHandling)) ?? d.homebrewHandling
        appStoreLookups = (try? c.decodeIfPresent(Bool.self, forKey: .appStoreLookups)) ?? d.appStoreLookups
        communityOverrides = (try? c.decodeIfPresent(Bool.self, forKey: .communityOverrides)) ?? d.communityOverrides
        autoUpdate = (try? c.decodeIfPresent(Bool.self, forKey: .autoUpdate)) ?? d.autoUpdate
        autoUpdateWait = (try? c.decodeIfPresent(AutoUpdateWait.self, forKey: .autoUpdateWait)) ?? d.autoUpdateWait
        hasCompletedOnboarding = (try? c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)) ?? d.hasCompletedOnboarding
    }
}

/// Ignore rules. Keyed by bundle ID so they survive moving or renaming the app.
public struct IgnoreRules: Sendable, Codable, Equatable {
    /// Apps ignored forever.
    public var apps: Set<String> = []
    /// Bundle ID → the one version to skip. A newer version shows again.
    public var versions: [String: String] = [:]

    public init(apps: Set<String> = [], versions: [String: String] = [:]) {
        self.apps = apps
        self.versions = versions
    }

    public func ignoresApp(_ bundleID: String) -> Bool { apps.contains(bundleID) }

    public func ignoresVersion(_ version: String, of bundleID: String) -> Bool {
        versions[bundleID] == version
    }
}

/// Small bits of state that aren't settings.
public struct AppState: Sendable, Codable, Equatable {
    public var lastCheck: Date?
    /// At most one notification a day.
    public var lastNotification: Date?
    /// Notifications are requested on the first update found, not at launch.
    public var askedForNotifications = false

    public init() {}
}
