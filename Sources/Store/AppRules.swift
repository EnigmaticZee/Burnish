import Foundation

/// Choices for one app that win over the global settings, keyed by bundle ID so they survive
/// moving or renaming the app.
public struct AppRules: Codable, Sendable, Equatable {
    public var byApp: [String: AppRule] = [:]

    public init() {}

    public func rule(for bundleID: String) -> AppRule { byApp[bundleID] ?? AppRule() }

    public mutating func set(_ rule: AppRule, for bundleID: String) {
        byApp[bundleID] = rule.isDefault ? nil : rule
    }
}

public struct AppRule: Codable, Sendable, Equatable {
    public enum Updates: String, Codable, Sendable, CaseIterable {
        /// Whatever Settings says about automatic updates.
        case followSettings
        /// Install minor updates on its own, even when automatic updates are off.
        case automatic
        /// Never install on its own; just say there's an update.
        case notifyOnly

        public var label: String {
            switch self {
            case .followSettings: String(localized: "Follow Settings")
            case .automatic: String(localized: "Install automatically")
            case .notifyOnly: String(localized: "Just tell me")
            }
        }
    }

    public var updates: Updates = .followSettings
    /// Stay on this major version: 5 means 5.x and nothing newer.
    public var stayOnMajor: Int?
    /// Take beta releases too, where the app's feed or Homebrew offers them.
    public var followBeta = false

    public init(updates: Updates = .followSettings, stayOnMajor: Int? = nil, followBeta: Bool = false) {
        self.updates = updates
        self.stayOnMajor = stayOnMajor
        self.followBeta = followBeta
    }

    public var isDefault: Bool { self == AppRule() }
}

extension StoreKey {
    public static var appRules: StoreKey<AppRules> { StoreKey<AppRules>("app-rules.json") }
}

/// An update feed for an app that doesn't say where it updates from, listed by a contributor in
/// the repository's community file: a Sparkle appcast or a GitHub repository ("owner/name").
public struct CommunityFeed: Codable, Sendable, Equatable {
    public var sparkle: URL?
    public var github: String?
    /// Typed into Burnish by the person, for their own Mac, rather than listed in the repository.
    public var addedByUser: Bool?

    public init(sparkle: URL? = nil, github: String? = nil, addedByUser: Bool? = nil) {
        self.sparkle = sparkle
        self.github = github
        self.addedByUser = addedByUser
    }

    /// Where it points, for a label: the appcast's host or the repository.
    public var label: String { sparkle?.host ?? github ?? "" }
}

/// Feeds the person added themselves for apps Burnish can't check, keyed by bundle ID. Read like
/// community feeds: to spot updates, never to install from.
public struct UserFeeds: Codable, Sendable, Equatable {
    public var byApp: [String: CommunityFeed] = [:]

    public init() {}
}

extension StoreKey {
    public static var userFeeds: StoreKey<UserFeeds> { StoreKey<UserFeeds>("user-feeds.json") }
}
