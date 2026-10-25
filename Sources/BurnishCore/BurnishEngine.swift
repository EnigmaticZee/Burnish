import CaskIndex
import Foundation
import Installer
import Inventory
import Net
import Store
import UpdateSources

/// Burnish's moving parts wired together. The app and the CLI each make one.
public final class BurnishEngine: Sendable {
    public static let bundleID = "io.github.enigmaticzee.Burnish"
    public static let lastReportKey = StoreKey<CheckReport>("last-report.json")

    public let client: HTTPClient
    public let store: StateStore
    public let caskStore: CaskDataStore
    public let checker: UpdateChecker
    public let community: CommunityOverrides

    public init(directory: URL = StateStore.defaultDirectory, client: HTTPClient = URLSessionHTTPClient(), system: SystemVersion = .current) {
        self.client = client
        store = StateStore(directory: directory)
        caskStore = CaskDataStore(directory: directory.appendingPathComponent("Homebrew", isDirectory: true), client: client)
        checker = UpdateChecker(client: client, caskStore: caskStore, system: system)
        community = CommunityOverrides(client: client, store: store)
    }

    public var downloadsDirectory: URL { store.directory.appendingPathComponent("Downloads", isDirectory: true) }

    public func roots(for settings: Settings) -> [URL] {
        var roots = [AppInventory.systemApplications]
        if settings.scanUserApplications { roots.append(AppInventory.userApplications) }
        return roots
    }

    /// Scans the app folders. Burnish updates itself with Sparkle, so it leaves itself out.
    public func scan(settings: Settings) -> InventoryResult {
        AppInventory(excludedBundleIDs: [Self.bundleID]).scan(roots: roots(for: settings))
    }

    /// Scan, check every app, remember the report.
    public func runCheck(onResult: @escaping @Sendable (AppCheckResult) async -> Void = { _ in }) async -> CheckReport {
        let settings = await store.load(.settings, default: Settings())
        var apps = scan(settings: settings).apps
        if settings.homebrewHandling == .hide { apps.removeAll(where: \.isManagedByHomebrew) }
        let report = await check(apps, settings: settings, onResult: onResult)
        await store.save(report, Self.lastReportKey)
        await store.update(.appState, default: AppState()) { $0.lastCheck = report.finishedAt }
        return report
    }

    public func check(_ apps: [InstalledApp], settings: Settings, onResult: @escaping @Sendable (AppCheckResult) async -> Void = { _ in }) async -> CheckReport {
        let options = CheckOptions(
            appStoreLookups: settings.appStoreLookups,
            ignoreRules: await store.load(.ignoreRules, default: IgnoreRules()),
            userOverrides: await store.load(.userOverrides, default: MatchOverrides()),
            communityOverrides: settings.communityOverrides ? await community.load() : .none,
            appRules: await store.load(.appRules, default: AppRules())
        )
        let report = await checker.check(apps, options: options, onResult: onResult)
        let found = report.results.filter(\.status.isOutdated).compactMap { result in
            result.status.candidate.map { (result.app.bundleID, $0) }
        }
        if !found.isEmpty {
            await store.update(.history, default: UpdateHistory()) { history in
                for (bundleID, candidate) in found {
                    history.noteFound(version: candidate.displayVersion, source: candidate.source.rawValue, for: bundleID)
                }
            }
        }
        return report
    }

    public func lastReport() async -> CheckReport? {
        await store.load(Self.lastReportKey)
    }

    /// Re-checks one app after an install, an ignore change or a match correction.
    public func recheck(_ app: InstalledApp, settings: Settings) async -> AppCheckResult? {
        let fresh = AppInventory(excludedBundleIDs: [Self.bundleID]).readApp(at: app.url).map { found -> InstalledApp in
            var copy = found
            copy.caskroomToken = app.caskroomToken
            return copy
        }
        guard let fresh else { return nil }
        return await check([fresh], settings: settings).results.first
    }

    /// The cask list for the "pick a different cask" sheet.
    public func catalog() async -> CaskCatalog? {
        if let catalog = await checker.catalog { return catalog }
        return try? await caskStore.load().catalog
    }

    /// Lets go of the parsed cask list between checks to keep idle memory low.
    public func releaseCaches() async {
        await caskStore.releaseMemory()
        await checker.releaseCatalog()
    }

    // MARK: Installing

    public func install(
        _ result: AppCheckResult,
        automatic: Bool = false,
        progress: @escaping @Sendable (InstallPhase) -> Void,
        askToQuit: @escaping @Sendable (String) async -> QuitDecision
    ) async -> InstallOutcome {
        guard let candidate = result.status.candidate else {
            return .refused(InstallRefusal(.manualOnly, String(localized: "There's no update to install"), downloadPage: result.downloadPage))
        }
        var release = candidate.release
        if release.downloadPage == nil { release.downloadPage = result.downloadPage }
        let expected = await catalog()?.cask(result.match?.token ?? "")?.appNames ?? []
        let installer = AppInstaller(environment: .live(client: client, workDirectory: downloadsDirectory))
        let outcome = await installer.install(
            InstallRequest(app: result.app, release: release, expectedAppNames: expected),
            progress: progress, askToQuit: askToQuit
        )
        let version = candidate.displayVersion
        switch outcome {
        case .installed(let oldCopy, _):
            await record(.updated(from: result.app.version.display, to: version, previousCopy: oldCopy?.path,
                                  automatic: automatic, checks: result.installChecks(release).map(\.rawValue)), for: result)
        case .openedInInstaller:
            await record(.handedOff(version: version, to: "installer"), for: result)
        case .refused(let refusal):
            await record(.refused(version: version, reason: refusal.message), for: result)
        case .cancelled:
            break
        }
        return outcome
    }

    /// Puts back the version Burnish replaced in its latest update of this app, then skips the
    /// version it rolled back from, so Update All doesn't put it straight back.
    public func restore(
        _ result: AppCheckResult,
        progress: @escaping @Sendable (InstallPhase) -> Void,
        askToQuit: @escaping @Sendable (String) async -> QuitDecision
    ) async -> InstallOutcome {
        let history = await store.load(.history, default: UpdateHistory())
        guard case let .updated(from, to, previousCopy?, _, _)? = history.latestUpdate(for: result.app.bundleID)?.kind else {
            return .refused(InstallRefusal(.previousCopy, String(localized: "There's no earlier version to put back"), downloadPage: nil))
        }
        let installer = AppInstaller(environment: .live(client: client, workDirectory: downloadsDirectory))
        let outcome = await installer.restore(RestoreRequest(app: result.app, previousCopy: URL(fileURLWithPath: previousCopy)),
                                              progress: progress, askToQuit: askToQuit)
        if case .installed(let newerCopy, _) = outcome {
            await record(.restored(to: from, from: to, replacedCopy: newerCopy?.path), for: result)
            await store.update(.ignoreRules, default: IgnoreRules()) { $0.versions[result.app.bundleID] = to }
        }
        return outcome
    }

    public func brewUpgrade(_ result: AppCheckResult, token: String) async throws(BrewUpgrader.Failure) {
        try await BrewUpgrader().upgrade(token: token)
        if let version = result.status.candidate?.displayVersion {
            await record(.handedOff(version: version, to: "homebrew"), for: result)
        }
    }

    public func history() async -> UpdateHistory {
        await store.load(.history, default: UpdateHistory())
    }

    private func record(_ kind: HistoryEvent.Kind, for result: AppCheckResult) async {
        await store.update(.history, default: UpdateHistory()) { $0.record(kind, for: result.app.bundleID) }
    }

    /// Fetches a Sparkle `releaseNotesLink` (the app's own feed host) and sanitises it.
    public func releaseNotes(at url: URL) async -> ReleaseNotesDocument? {
        guard url.scheme == "https", let response = try? await client.get(url, headers: [:], timeout: 10), response.isSuccess,
              response.body.count < 1_000_000 else { return nil }
        let text = String(decoding: response.body, as: UTF8.self)
        let type = response.header("Content-Type")?.lowercased() ?? ""
        let doc = type.contains("text/plain") ? ReleaseNotesDocument.plainText(text) : ReleaseNotesDocument.html(text)
        return doc.isEmpty ? nil : doc
    }
}
