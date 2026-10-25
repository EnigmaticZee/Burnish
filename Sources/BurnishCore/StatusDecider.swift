import CaskIndex
import Foundation
import Inventory
import Store
import UpdateSources
import Versions

/// Everything the sources said about one app, gathered before deciding.
public struct SourceFindings: Sendable {
    public enum Outcome<Value: Sendable>: Sendable {
        case notApplicable
        case found(Value)
        case failed(String)
    }

    public var appStore: Outcome<Release?> = .notApplicable
    public var sparkle: Outcome<SparkleSource.Result> = .notApplicable
    public var electron: Outcome<Release> = .notApplicable
    public var tauri: Outcome<Release> = .notApplicable
    /// A GitHub repository a contributor listed for the app.
    public var community: Outcome<Release> = .notApplicable
    public var match: CaskMatch?
    public var cask: Cask?
    public var github: Release?
    /// Why GitHub couldn't be asked (rate limit, network). Homebrew's data still decides.
    public var githubFailure: String?
    /// The developer's own updater for this app, when it's installed.
    public var vendorUpdater: VendorUpdater?

    public init() {}
}

public struct DecisionOptions: Sendable {
    public var appStoreLookups = true
    public var ignoreRules = IgnoreRules()
    public var appRules = AppRules()
    /// Intel-only apps only matter on Apple silicon.
    public var appleSilicon = true

    public init(appStoreLookups: Bool = true, ignoreRules: IgnoreRules = IgnoreRules(), appRules: AppRules = AppRules(),
                appleSilicon: Bool = true) {
        self.appStoreLookups = appStoreLookups
        self.ignoreRules = ignoreRules
        self.appRules = appRules
        self.appleSilicon = appleSilicon
    }
}

/// The per-app detection flow: the developer's own feed first, Homebrew as the
/// fallback, and every path ending in an honest state. Pure, so it's tested without a network.
public enum StatusDecider {
    public static func decide(
        _ app: InstalledApp, findings: SourceFindings, options: DecisionOptions, system: SystemVersion, now: Date = Date()
    ) -> AppCheckResult {
        var result = rawDecision(app, findings: findings, options: options, system: system)
        result.checkedAt = now
        if let cask = findings.cask {
            result.cask = CaskSummary(cask)
            if cask.deprecated || cask.disabled { result.notes.append(String(localized: "No longer maintained in Homebrew")) }
        }
        result.match = findings.match
        result.vendorUpdater = findings.vendorUpdater
        if options.appleSilicon, app.isIntelOnly {
            result.notes.append(Self.rosettaNote(findings.cask))
        }

        // "Stay on 5.x": a newer major from a source that only lists the newest version isn't an update.
        if case let .outdated(candidate) = result.status, let cap = options.appRules.rule(for: app.bundleID).stayOnMajor,
           let major = Version(candidate.displayVersion)?.major, major > cap {
            result.status = .upToDate(note: String(localized: "Version \(candidate.displayVersion) is out; you chose to stay on \(cap).x"))
        }

        // Ignore rules wrap whatever was found, so the detail pane can still show it.
        if options.ignoreRules.ignoresApp(app.bundleID) {
            result.status = .ignored(.app, result.status.candidate)
        } else if case let .outdated(candidate) = result.status, let ignored = options.ignoreRules.versions[app.bundleID],
                  Self.sameVersion(ignored, candidate.displayVersion) {
            // "2.0" ignored from one source is still ignored when another source says "2.0.0".
            result.status = .ignored(.version(candidate.displayVersion), candidate)
        }
        return result
    }

    /// What an Intel-only app means on Apple silicon, and whether Homebrew knows a native version.
    static func rosettaNote(_ cask: Cask?) -> String {
        switch cask?.requiresRosetta {
        case false?: String(localized: "Intel only, running through Rosetta. An Apple silicon version is available.")
        case true?: String(localized: "Intel only, running through Rosetta, and there's no Apple silicon version yet.")
        case nil: String(localized: "Intel only, running through Rosetta, which Apple is retiring for most apps after macOS 27.")
        }
    }

    static func sameVersion(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard let x = Version(a), let y = Version(b) else { return false }
        return x == y
    }

    static func rawDecision(_ app: InstalledApp, findings: SourceFindings, options: DecisionOptions, system: SystemVersion) -> AppCheckResult {
        var notes: [String] = []

        // 1. Mac App Store: the receipt decides, and only the App Store updates it.
        if app.isAppStore {
            guard options.appStoreLookups else {
                return AppCheckResult(app: app, status: .cantCheck(reason: String(localized: "App Store checks are turned off in Settings")))
            }
            switch findings.appStore {
            case .found(let release?):
                return verdict(app, release: release, notes: notes, system: system)
            case .found(nil):
                return AppCheckResult(app: app, status: .cantCheck(reason: String(localized: "Not found in the App Store for your region")), decidedBy: .appStore)
            case .failed(let why):
                return AppCheckResult(app: app, status: .cantCheck(reason: why), decidedBy: .appStore)
            case .notApplicable:
                return AppCheckResult(app: app, status: .cantCheck(reason: String(localized: "App Store not checked")))
            }
        }

        // Apple's own apps outside the App Store come with macOS updates.
        if app.isApple {
            return AppCheckResult(app: app, status: .cantCheck(reason: String(localized: "Updated by Apple through Software Update")))
        }

        // 2. The developer's Sparkle feed.
        switch findings.sparkle {
        case .found(let feed):
            if let release = feed.release {
                let result = verdict(app, release: release, notes: notes, system: system, incompatibleNote: feed.newerButIncompatible)
                if case let .cantCheck(reason) = result.status {
                    notes.append(String(localized: "Developer feed: \(reason)"))
                } else {
                    return result
                }
            } else {
                return AppCheckResult(app: app, status: .upToDate(note: feed.newerButIncompatible), decidedBy: .sparkle)
            }
        case .failed(let why):
            notes.append(why)
        case .notApplicable:
            if app.sparkleFeedURL == nil, app.sparklePublicEDKey != nil {
                notes.append(String(localized: "This app sets its update feed while running, so Burnish uses Homebrew's data"))
            }
        }

        // 3. electron-builder feed.
        switch findings.electron {
        case .found(let release):
            let result = verdict(app, release: release, notes: notes, system: system)
            if case let .cantCheck(reason) = result.status {
                notes.append(String(localized: "Developer feed: \(reason)"))
            } else {
                return result
            }
        case .failed(let why):
            notes.append(why)
        case .notApplicable:
            break
        }

        // 3b. Tauri updater endpoints, read from the app's executable.
        switch findings.tauri {
        case .found(let release):
            let result = verdict(app, release: release, notes: notes, system: system)
            if case let .cantCheck(reason) = result.status {
                notes.append(String(localized: "Developer feed: \(reason)"))
            } else {
                return result
            }
        case .failed(let why):
            notes.append(why)
        case .notApplicable:
            break
        }

        // 3c. A feed listed in the community file.
        switch findings.community {
        case .found(let release):
            let result = verdict(app, release: release, notes: notes, system: system)
            if case .cantCheck = result.status {} else { return result }
        case .failed(let why):
            notes.append(why)
        case .notApplicable:
            break
        }

        // 4. Homebrew's cask data, matched by confidence.
        guard let match = findings.match, let cask = findings.cask else {
            let reason = notes.first
                ?? findings.vendorUpdater.map { String(localized: "Updates come through \($0.name)") }
                ?? String(localized: "No update source found")
            return AppCheckResult(app: app, status: .cantCheck(reason: reason), notes: Array(notes.dropFirst()))
        }
        guard match.canRaiseAlert else {
            return AppCheckResult(app: app, status: .needsConfirmation(match), decidedBy: .homebrew, notes: notes)
        }
        if cask.isLatestVersion {
            return AppCheckResult(app: app, status: .cantCheck(reason: String(localized: "Can't compare: Homebrew lists this app's version as \"latest\"")),
                                  decidedBy: .homebrew, notes: notes)
        }
        var release = HomebrewSource.release(for: cask)
        if let failure = findings.githubFailure { notes.append(failure) }
        if let github = findings.github, let gv = github.version.short.flatMap(Version.init),
           let cv = release.version.short.flatMap(Version.init) {
            if gv > cv, UpdateComparator.isCompatible(gv, cv), github.downloadURL != nil {
                // The developer's GitHub release is newer than Homebrew's copy of it.
                release = github
            } else if gv == cv, github.releaseNotes != nil {
                release.releaseNotes = github.releaseNotes
            }
        }
        if !cask.supports(macOS: system.major) {
            let needs = cask.minimumMacOS.map { String(localized: "macOS \($0) or later") } ?? String(localized: "a different macOS version")
            let shown = release.version.display
            switch release.compare(with: app.version) {
            case .newer:
                return AppCheckResult(app: app, status: .upToDate(note: String(localized: "Version \(shown) needs \(needs)")), decidedBy: release.source, notes: notes)
            default:
                break
            }
        }
        return verdict(app, release: release, notes: notes, system: system)
    }

    static func verdict(_ app: InstalledApp, release: Release, notes: [String], system: SystemVersion, incompatibleNote: String? = nil) -> AppCheckResult {
        let status: CheckStatus
        switch release.compare(with: app.version) {
        case .newer where !system.satisfies(minimum: release.minimumOS):
            // The App Store and Electron feeds list releases this Mac can't run.
            status = .upToDate(note: String(localized: "Version \(release.version.display) needs macOS \(release.minimumOS ?? "") or later"))
        case .newer(let major):
            // A manual upgrade is often a paid one, so it's kept out of Update All like a major one.
            status = .outdated(UpdateCandidate(release: release, isMajorUpgrade: major || release.wantsManualUpgrade(from: app.version)))
        case .same:
            status = .upToDate(note: incompatibleNote)
        case .older:
            // A beta build, or a source that lags: never a downgrade.
            status = .upToDate(note: incompatibleNote ?? String(localized: "The installed version is newer than \(release.source.label)'s \(release.version.display)"))
        case .cantCompare(let why):
            status = .cantCheck(reason: why.text)
        }
        return AppCheckResult(app: app, status: status, decidedBy: release.source, notes: notes)
    }
}

extension CantCompareReason {
    /// What the Can't check row says.
    var text: String {
        switch self {
        case .noVersion(fromFeed: false): String(localized: "The source gave no version")
        case .noVersion(fromFeed: true): String(localized: "The feed gave no version")
        case .latest: String(localized: "The source has no version number (\"latest\")")
        case .unreadable(let version): String(localized: "Unreadable version \"\(version)\"")
        case .installedUnreadable: String(localized: "The installed version isn't readable")
        case let .formatsDiffer(installed, available, fromFeed: false):
            String(localized: "Version formats don't line up (installed \(installed), source \(available))")
        case let .formatsDiffer(installed, available, fromFeed: true):
            String(localized: "Build numbers don't line up (installed \(installed), feed \(available))")
        case .buildNewerVersionOlder: String(localized: "The feed's build is newer but its version is older")
        }
    }
}
