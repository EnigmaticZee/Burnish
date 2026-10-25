import CaskIndex
import Foundation
import Inventory
import Net
import Store
import UpdateSources
import os

public struct CheckOptions: Sendable {
    public var appStoreLookups: Bool
    public var ignoreRules: IgnoreRules
    public var userOverrides: MatchOverrides
    public var communityOverrides: MatchOverrides

    public init(appStoreLookups: Bool = true, ignoreRules: IgnoreRules = IgnoreRules(),
                userOverrides: MatchOverrides = .none, communityOverrides: MatchOverrides = .none) {
        self.appStoreLookups = appStoreLookups
        self.ignoreRules = ignoreRules
        self.userOverrides = userOverrides
        self.communityOverrides = communityOverrides
    }
}

/// Runs every source for every app and decides each status. Results stream out as each app
/// finishes; the list never waits for the slowest feed.
public actor UpdateChecker {
    private let client: HTTPClient
    private let caskStore: CaskDataStore
    private let system: SystemVersion
    private let platform: Platform
    private let github: GitHubSource
    private let storefront: String?
    private var lastCatalog: CaskCatalog?
    private let log = Logger(subsystem: "io.github.enigmaticzee.Burnish", category: "check")

    public init(client: HTTPClient, caskStore: CaskDataStore, system: SystemVersion = .current, platform: Platform = .current,
                storefront: String? = Locale.current.region?.identifier) {
        self.client = client
        self.storefront = storefront
        self.caskStore = caskStore
        self.system = system
        self.platform = platform
        github = GitHubSource(client: client)
    }

    public var catalog: CaskCatalog? { lastCatalog }

    public func releaseCatalog() { lastCatalog = nil }

    public func check(
        _ apps: [InstalledApp], options: CheckOptions,
        onResult: @escaping @Sendable (AppCheckResult) async -> Void = { _ in }
    ) async -> CheckReport {
        let started = Date()
        var problems: [String] = []

        // Homebrew's data and the App Store lookup are shared by every app, so fetch them first.
        async let loadedCasks: CaskDataStore.Loaded? = {
            do { return try await caskStore.load() } catch {
                return nil
            }
        }()
        let appStoreApps = apps.filter(\.isAppStore)
        let storefront = storefront
        let client = client
        async let storeLookup: Result<[String: Release], Error> = {
            guard options.appStoreLookups, !appStoreApps.isEmpty else { return .success([:]) }
            do { return .success(try await AppStoreSource(client: client, country: storefront).lookup(appStoreApps)) } catch { return .failure(error) }
        }()

        let casks = await loadedCasks
        if casks == nil { problems.append("Homebrew's app list couldn't be loaded") }
        if let catalog = casks?.catalog { lastCatalog = catalog }
        let appStore = await storeLookup
        if case .failure(let error) = appStore {
            problems.append("App Store lookup failed: \(error.localizedDescription)")
        }

        let matcher = casks.map { CaskMatcher(catalog: $0.catalog, user: options.userOverrides, community: options.communityOverrides) }
        let decision = DecisionOptions(appStoreLookups: options.appStoreLookups, ignoreRules: options.ignoreRules)
        let system = system
        let platform = platform
        let github = github

        let results = await withTaskGroup(of: AppCheckResult.self) { group in
            for app in apps {
                group.addTask {
                    var findings = SourceFindings()
                    if app.isAppStore {
                        switch appStore {
                        case .success(let found): findings.appStore = .found(found[app.bundleID])
                        case .failure: findings.appStore = .failed("App Store not reachable")
                        }
                    } else if !app.isApple {
                        await Self.gather(&findings, app: app, client: client, system: system, platform: platform, matcher: matcher, github: github)
                    }
                    let result = StatusDecider.decide(app, findings: findings, options: decision, system: system)
                    await onResult(result)
                    return result
                }
            }
            var all: [AppCheckResult] = []
            for await result in group { all.append(result) }
            return all
        }

        let sorted = results.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
        log.info("Checked \(apps.count) apps in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
        return CheckReport(
            results: sorted, startedAt: started, finishedAt: Date(),
            caskDataDate: casks?.dataDate, isOffline: casks?.isOffline ?? true, problems: problems
        )
    }

    static func gather(
        _ findings: inout SourceFindings, app: InstalledApp, client: HTTPClient, system: SystemVersion,
        platform: Platform, matcher: CaskMatcher?, github: GitHubSource
    ) async {
        if let feed = app.sparkleFeedURL {
            do {
                findings.sparkle = .found(try await SparkleSource(client: client, system: system, isARM: platform.isARM).check(feed: feed))
            } catch {
                findings.sparkle = .failed(error.errorDescription ?? "Feed not reachable")
            }
        }
        if let config = app.electronUpdateConfig, !findings.sparkleSucceeded {
            do {
                findings.electron = .found(try await ElectronSource(client: client, isARM: platform.isARM).check(configFile: config))
            } catch {
                findings.electron = .failed(error.errorDescription ?? "Feed not reachable")
            }
        }
        guard let matcher, let match = matcher.match(app) else { return }
        findings.match = match
        findings.cask = matcher.catalog.cask(match.token)
        // GitHub only matters when the developer feeds didn't already decide.
        if match.canRaiseAlert, !findings.sparkleSucceeded, !findings.electronSucceeded,
           let cask = findings.cask, let repo = HomebrewSource.githubRepository(for: cask) {
            if let latest = try? await github.latestRelease(of: repo) {
                findings.github = GitHubSource.release(latest, forCask: cask)
            }
        }
    }
}

extension SourceFindings {
    var sparkleSucceeded: Bool {
        if case .found(let r) = sparkle, r.release != nil { return true }
        return false
    }

    var electronSucceeded: Bool {
        if case .found = electron { return true }
        return false
    }
}
