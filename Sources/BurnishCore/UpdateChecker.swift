import CaskIndex
import Foundation
import Inventory
import Net
import Store
import UpdateSources
import Versions
import os

public struct CheckOptions: Sendable {
    public var appStoreLookups: Bool
    public var ignoreRules: IgnoreRules
    public var userOverrides: MatchOverrides
    public var communityOverrides: MatchOverrides
    public var appRules: AppRules
    public var communityFeeds: [String: CommunityFeed]

    public init(appStoreLookups: Bool = true, ignoreRules: IgnoreRules = IgnoreRules(),
                userOverrides: MatchOverrides = .none, communityOverrides: MatchOverrides = .none, appRules: AppRules = AppRules(),
                communityFeeds: [String: CommunityFeed] = [:]) {
        self.appStoreLookups = appStoreLookups
        self.ignoreRules = ignoreRules
        self.userOverrides = userOverrides
        self.communityOverrides = communityOverrides
        self.appRules = appRules
        self.communityFeeds = communityFeeds
    }
}

/// Runs every source for every app and decides each status. Results stream out as each app
/// finishes; the list never waits for the slowest feed.
public actor UpdateChecker {
    /// The sources a check asks, built once and shared by every app.
    struct Sources: Sendable {
        let sparkle: SparkleSource
        let electron: ElectronSource
        let tauri: TauriSource
        let github: GitHubSource
    }

    private let client: HTTPClient
    private let caskStore: CaskDataStore
    private let system: SystemVersion
    private let platform: Platform
    private let sources: Sources
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
        sources = Sources(
            sparkle: SparkleSource(client: client, system: system, isARM: platform.isARM),
            electron: ElectronSource(client: client, isARM: platform.isARM),
            tauri: TauriSource(client: client, isARM: platform.isARM),
            github: GitHubSource(client: client)
        )
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
        if casks == nil { problems.append(String(localized: "Homebrew's app list couldn't be loaded")) }
        if let catalog = casks?.catalog { lastCatalog = catalog }
        let appStore = await storeLookup
        if case .failure(let error) = appStore {
            problems.append(String(localized: "App Store lookup failed: \(error.localizedDescription)"))
        }

        let matcher = casks.map { CaskMatcher(catalog: $0.catalog, user: options.userOverrides, community: options.communityOverrides) }
        let decision = DecisionOptions(appStoreLookups: options.appStoreLookups, ignoreRules: options.ignoreRules,
                                       appRules: options.appRules, appleSilicon: platform.isARM)
        let appRules = options.appRules
        let communityFeeds = options.communityFeeds
        let system = system
        let sources = sources

        let results = await withTaskGroup(of: AppCheckResult.self) { group in
            for app in apps {
                group.addTask {
                    var findings = SourceFindings()
                    if app.isAppStore {
                        switch appStore {
                        case .success(let found): findings.appStore = .found(found[app.bundleID])
                        case .failure: findings.appStore = .failed(String(localized: "App Store not reachable"))
                        }
                    } else if !app.isApple {
                        await Self.gather(&findings, app: app, rule: appRules.rule(for: app.bundleID), communityFeed: communityFeeds[app.bundleID],
                                          sources: sources, matcher: matcher)
                        findings.vendorUpdater = VendorUpdaters.updater(for: app)
                        // A Tauri app installs its own signed updates, so Update opens the app.
                        if findings.tauriSucceeded, findings.vendorUpdater == nil {
                            findings.vendorUpdater = VendorUpdater(name: app.name, shortName: String(localized: "Open"), path: app.url.path)
                        }
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
        _ findings: inout SourceFindings, app: InstalledApp, rule: AppRule, communityFeed: CommunityFeed?,
        sources: Sources, matcher: CaskMatcher?
    ) async {
        let preferences = SparkleSource.Preferences(maximumMajor: rule.stayOnMajor, includeBeta: rule.followBeta)
        if let feed = app.sparkleFeedURL {
            do {
                findings.sparkle = .found(try await sources.sparkle.check(feed: feed, preferences: preferences, installed: app.version))
            } catch {
                findings.sparkle = .failed(error.errorDescription ?? String(localized: "Feed not reachable"))
            }
        } else if let leads = app.sparkleFeedCandidates?.compactMap({ URL(string: $0) }), !leads.isEmpty {
            // An address compiled into the app is only a lead: the feed has to prove it's the app's own.
            let owner = SparkleSource.Owner(names: [app.name] + app.bundleNames, installed: app.version)
            if let found = await sources.sparkle.check(leads: leads, owner: owner, preferences: preferences) {
                var result = found.result
                result.release?.feedFoundInApp = true
                findings.sparkle = .found(result)
            }
        }
        if let config = app.electronUpdateConfig, !findings.sparkleSucceeded {
            do {
                findings.electron = .found(try await sources.electron.check(configFile: config))
            } catch {
                findings.electron = .failed(error.errorDescription ?? String(localized: "Feed not reachable"))
            }
        }
        if let endpoints = app.tauriUpdateEndpoints, !endpoints.isEmpty, !findings.sparkleSucceeded, !findings.electronSucceeded {
            do {
                findings.tauri = .found(try await sources.tauri.check(endpoints: endpoints, installed: app.version))
            } catch {
                findings.tauri = .failed(error.errorDescription ?? String(localized: "Feed not reachable"))
            }
        }
        guard let matcher, let match = matcher.match(app) else {
            await askCommunityFeed(&findings, app: app, feed: communityFeed, sources: sources)
            return
        }
        findings.match = match
        findings.cask = matcher.catalog.cask(match.token)
        // Following betas: Homebrew keeps them as a separate entry, such as `firefox@beta`.
        if rule.followBeta, !match.token.contains("@"), let beta = matcher.catalog.cask("\(match.token)@beta") {
            findings.cask = beta
        }
        // GitHub only matters when the developer feeds didn't already decide.
        if match.canRaiseAlert, !findings.sparkleSucceeded, !findings.electronSucceeded, !findings.tauriSucceeded,
           let cask = findings.cask, let repo = HomebrewSource.githubRepository(for: cask) {
            do {
                findings.github = GitHubSource.release(try await sources.github.latestRelease(of: repo), forCask: cask)
            } catch {
                // A repository with no releases is normal; a rate limit or an outage is worth a note.
                if error != .noRelease { findings.githubFailure = error.errorDescription }
            }
        }
        if !match.canRaiseAlert {
            await askCommunityFeed(&findings, app: app, feed: communityFeed, sources: sources)
        }
    }

    /// A feed a contributor listed, for an app that names none and that Homebrew can't match with
    /// confidence. Burnish reads it to spot updates; the install stays with the person.
    static func askCommunityFeed(_ findings: inout SourceFindings, app: InstalledApp, feed: CommunityFeed?, sources: Sources) async {
        guard let feed, app.sparkleFeedURL == nil, app.electronUpdateConfig == nil, !findings.tauriSucceeded else { return }
        if let url = feed.sparkle {
            do {
                var result = try await sources.sparkle.check(feed: url)
                result.release?.listedByCommunity = true
                result.release?.addedByUser = feed.addedByUser
                findings.sparkle = .found(result)
            } catch {
                findings.sparkle = .failed(error.errorDescription ?? String(localized: "Feed not reachable"))
            }
        } else if let parts = feed.github?.split(separator: "/"), parts.count == 2 {
            let repo = GitHubRepository(owner: String(parts[0]), name: String(parts[1]))
            do {
                let latest = try await sources.github.latestRelease(of: repo)
                guard let version = latest.versionString else { return }
                var release = Release(source: .github, version: VersionPair(short: version), basis: .shortVersion,
                                      downloadPage: latest.page, releaseNotes: latest.body.map { ReleaseNotes(text: $0, format: .markdown) },
                                      date: latest.publishedAt, needsManualInstall: true)
                release.listedByCommunity = true
                release.addedByUser = feed.addedByUser
                findings.community = .found(release)
            } catch {
                if error != .noRelease { findings.community = .failed(error.errorDescription ?? String(localized: "GitHub not reachable")) }
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

    var tauriSucceeded: Bool {
        if case .found = tauri { return true }
        return false
    }
}
