import CaskIndex
import Foundation
import Installer
import Inventory
import Net
import Store
import UpdateSources
import Versions

/// What the Update button does for a result.
public enum UpdateAction: Sendable, Equatable {
    /// Burnish downloads, verifies and replaces the app.
    case install
    /// App Store apps update in the App Store.
    case openAppStore(URL?)
    /// The source has nothing Burnish can install safely; open the developer's page.
    case openDownloadPage(URL?, reason: String)
    /// `brew upgrade --cask`, when turned on in Settings.
    case brewUpgrade(token: String)
    /// The developer's own updater (Microsoft AutoUpdate, Creative Cloud, Setapp, Toolbox).
    case openUpdater(VendorUpdater)
    /// Shown, but left to `brew upgrade --cask`.
    case managedByHomebrew(token: String)
    case none

    public var buttonTitle: String {
        switch self {
        case .install, .brewUpgrade: String(localized: "Update")
        case .openAppStore: String(localized: "App Store")
        case .openDownloadPage: String(localized: "Download")
        case .managedByHomebrew: String(localized: "Homebrew")
        case .openUpdater(let updater): updater.shortName
        case .none: ""
        }
    }

    /// Update All only runs updates Burnish can do by itself.
    public var isAutomatic: Bool {
        switch self {
        case .install, .brewUpgrade: true
        default: false
        }
    }
}

extension AppCheckResult {
    public func action(homebrew: HomebrewHandling) -> UpdateAction {
        guard case let .outdated(candidate) = status else { return .none }
        let release = candidate.release
        if app.isAppStore { return .openAppStore(release.downloadPage) }
        if let token = app.caskroomToken {
            return homebrew == .upgradeWithBrew ? .brewUpgrade(token: token) : .managedByHomebrew(token: token)
        }
        if let vendorUpdater { return .openUpdater(vendorUpdater) }
        if release.addedByUser == true {
            return .openDownloadPage(downloadPage, reason: String(localized: "Found through a feed you added, so the install is yours to do"))
        }
        if release.listedByCommunity == true {
            return .openDownloadPage(downloadPage, reason: String(localized: "Found through a community-listed feed, so the install is yours to do"))
        }
        if !app.signature.canBeAutoUpdated {
            return .openDownloadPage(downloadPage, reason: String(localized: "Burnish only replaces apps signed by their developer"))
        }
        if release.isInformational || release.needsManualInstall || release.downloadURL == nil {
            return .openDownloadPage(downloadPage, reason: String(localized: "This update comes from the developer's page"))
        }
        if release.wantsManualUpgrade(from: app.version) {
            return .openDownloadPage(downloadPage, reason: String(localized: "The developer asks for this upgrade to be downloaded by hand"))
        }
        return .install
    }

    /// Major upgrades may be paid and are never part of Update All.
    public func includedInUpdateAll(homebrew: HomebrewHandling) -> Bool {
        guard case let .outdated(candidate) = status, !candidate.isMajorUpgrade else { return false }
        return action(homebrew: homebrew).isAutomatic
    }
}

/// Where an update sits in the Updates list, so what one click installs never mixes with what
/// you have to fetch yourself.
public enum UpdateGroup: Int, Sendable, CaseIterable, Identifiable, Comparable {
    /// Burnish installs it, and Update All includes it.
    case oneClick
    /// One click too, but possibly paid, so never part of Update All.
    case majorUpgrade
    /// The App Store, Homebrew or the developer's own updater installs it.
    case elsewhere
    /// Only the developer's download page will do.
    case download

    public var id: Int { rawValue }

    public static func < (a: UpdateGroup, b: UpdateGroup) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .oneClick: String(localized: "Ready to install")
        case .majorUpgrade: String(localized: "Major upgrades")
        case .elsewhere: String(localized: "Updated elsewhere")
        case .download: String(localized: "Download yourself")
        }
    }

    public var note: String {
        switch self {
        case .oneClick: String(localized: "Burnish checks and installs these itself; Update All does them together.")
        case .majorUpgrade: String(localized: "One click each, but they may be paid, so Update All leaves them to you.")
        case .elsewhere: String(localized: "The App Store, Homebrew or the developer's own updater installs these.")
        case .download: String(localized: "Burnish can't install these safely, so it opens the developer's page.")
        }
    }
}

extension AppCheckResult {
    public func updateGroup(homebrew: HomebrewHandling) -> UpdateGroup? {
        guard case let .outdated(candidate) = status else { return nil }
        switch action(homebrew: homebrew) {
        case .install, .brewUpgrade: return candidate.isMajorUpgrade ? .majorUpgrade : .oneClick
        case .openAppStore, .openUpdater, .managedByHomebrew: return .elsewhere
        case .openDownloadPage: return .download
        case .none: return nil
        }
    }
}

/// A new issue in Burnish's repository with the title, label and body filled in. The base address
/// is a constant and `URLComponents` percent-encodes the values, so neither unwrap can fail.
private func issueURL(title: String, label: String, body: String) -> URL {
    var components = URLComponents(url: Net.repository.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
        URLQueryItem(name: "title", value: title),
        URLQueryItem(name: "labels", value: label),
        URLQueryItem(name: "body", value: body),
    ]
    return components.url!
}

/// A prefilled GitHub issue with the bundle ID, versions and chosen cask, and nothing else.
public enum WrongMatchReport {
    public static func url(for result: AppCheckResult) -> URL {
        var body = """
        **Bundle ID:** `\(result.app.bundleID)`
        **Installed version:** \(result.app.version.short ?? "-") (\(result.app.version.build ?? "-"))
        """
        if let match = result.match {
            body += "\n**Matched cask:** `\(match.token)` (\(match.confidence))"
        }
        if let candidate = result.status.candidate {
            body += "\n**Version Burnish offered:** \(candidate.displayVersion) from \(candidate.source.label)"
        }
        body += "\n\n**What's wrong:** <!-- for example: it's actually the `foo` cask, or this app isn't in Homebrew -->\n"
        return issueURL(title: "Wrong match: \(result.app.bundleID)", label: "wrong-match", body: body)
    }
}

/// A ready-made GitHub issue for a download Burnish couldn't open: the app and the version offered,
/// where the file came from and what it looked like. The download link itself stays out, and so
/// does anything about the person or their other apps.
public enum InstallReport {
    public static func url(for result: AppCheckResult, refusal: InstallRefusal, burnish: String, system: String) -> URL {
        var body = """
        **App:** \(result.app.name) (`\(result.app.bundleID)`)
        **Installed version:** \(result.app.version.short ?? "-") (\(result.app.version.build ?? "-"))
        """
        if let candidate = result.status.candidate {
            body += "\n**Offered:** \(candidate.displayVersion) from \(candidate.source.label)"
            if let token = result.match?.token { body += " (cask `\(token)`)" }
            if let download = candidate.release.downloadURL {
                body += "\n**Download:** `\(download.lastPathComponent)` from \(download.host ?? "-")"
            }
        }
        body += "\n**Refused at:** \(refusal.rule.rawValue): \(refusal.message)"
        if let evidence = refusal.evidence { body += "\n**The file:** \(evidence)" }
        body += "\n**Burnish:** \(burnish) · \(system)\n"
        return issueURL(title: "Install: \(result.app.name) couldn't be opened (\(result.app.bundleID))", label: "install", body: body)
    }
}

/// A ready-made GitHub issue offering a feed the person added for everyone, as the line the
/// community file needs, with the app's name, bundle ID and version and nothing else.
public enum FeedSuggestion {
    public static func url(for result: AppCheckResult, feed: CommunityFeed) -> URL {
        let entry = feed.sparkle.map { "{ \"sparkle\": \"\($0.absoluteString)\" }" } ?? "{ \"github\": \"\(feed.github ?? "")\" }"
        let body = """
        **App:** \(result.app.name)
        **Installed version:** \(result.app.version.short ?? "-") (\(result.app.version.build ?? "-"))

        For `feeds` in `overrides/community-overrides.json`:

        ```json
        "\(result.app.bundleID)": \(entry)
        ```

        **How I know it's this app's feed:** <!-- for example: the developer's site links to it, or the app's release notes match -->
        """
        return issueURL(title: "Feed: \(result.app.name) (\(result.app.bundleID))", label: "feed", body: body)
    }
}

extension AppCheckResult {
    /// Apps Burnish can't check that a feed could help with. Apple's apps and App Store apps
    /// update through Apple, so there's nothing to add for them.
    public var canAddFeed: Bool {
        guard case .cantCheck = status else { return false }
        return !app.isApple && !app.isAppStore
    }
}
