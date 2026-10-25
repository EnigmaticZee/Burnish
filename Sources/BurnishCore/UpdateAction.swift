import CaskIndex
import Foundation
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
        var components = URLComponents(url: Net.repository.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "title", value: "Wrong match: \(result.app.bundleID)"),
            URLQueryItem(name: "labels", value: "wrong-match"),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url!
    }
}
