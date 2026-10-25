import CaskIndex
import Foundation
import Inventory
import Store
import Testing
import UpdateSources
import Versions
@testable import BurnishCore

let macOS27 = SystemVersion("27.0.1")
let arm = Platform(isARM: true, macOSMajor: 27)

func makeApp(
    _ name: String, _ id: String, _ short: String?, build: String? = nil, appStore: Bool = false,
    feed: String? = nil, edKey: String? = nil
) -> InstalledApp {
    InstalledApp(
        bundleID: id, name: name, bundleNames: [name], url: URL(fileURLWithPath: "/Applications/\(name).app"),
        version: VersionPair(short: short, build: build),
        signature: CodeSignature(kind: appStore ? .appStore : .developerID, teamID: "TEAM000001"),
        isAppStore: appStore, sparkleFeedURL: feed.flatMap(URL.init(string:)), sparklePublicEDKey: edKey
    )
}

func makeCask(_ token: String, version: String, app: String, quit: String? = nil, minimumMacOS: String? = nil,
              url: String = "https://example.com/download.zip", disabled: Bool = false) -> Cask {
    var artifacts: [[String: Any]] = [["app": [app], "target": "/Applications/\(app)"]]
    if let quit { artifacts.append(["uninstall": [["quit": quit]]]) }
    var json: [String: Any] = [
        "token": token, "name": [String(app.dropLast(4))], "version": version, "sha256": "no_check",
        "url": url, "homepage": "https://example.com", "artifacts": artifacts, "disabled": disabled,
    ]
    if let minimumMacOS { json["depends_on"] = ["macos": [">=": [minimumMacOS]]] }
    let data = try! JSONSerialization.data(withJSONObject: [json])
    return try! CaskDataStore.parse(data, platform: arm)[0]
}

func findings(cask: Cask, for app: InstalledApp) -> SourceFindings {
    var f = SourceFindings()
    let matcher = CaskMatcher(catalog: CaskCatalog(casks: [cask], platform: arm))
    f.match = matcher.match(app)
    f.cask = f.match.flatMap { matcher.catalog.cask($0.token) }
    return f
}

@Suite struct StatusDeciderTests {
    @Test func caskUpdate() {
        let app = makeApp("Rectangle", "com.knollsoft.Rectangle", "2.0.3")
        let cask = makeCask("rectangle", version: "2.0.4", app: "Rectangle.app", quit: "com.knollsoft.Rectangle")
        let result = StatusDecider.decide(app, findings: findings(cask: cask, for: app), options: DecisionOptions(), system: macOS27)
        guard case let .outdated(candidate) = result.status else { Issue.record("expected outdated, got \(result.status)"); return }
        #expect(candidate.displayVersion == "2.0.4")
        #expect(candidate.source == .homebrew)
        #expect(!candidate.isMajorUpgrade)
        #expect(result.match?.confidence == .high)
        #expect(result.cask?.token == "rectangle")
    }

    @Test func majorUpgradeIsFlagged() {
        let app = makeApp("Tool", "com.x.tool", "5.4")
        let cask = makeCask("tool", version: "6.0", app: "Tool.app", quit: "com.x.tool")
        let result = StatusDecider.decide(app, findings: findings(cask: cask, for: app), options: DecisionOptions(), system: macOS27)
        #expect(result.status.candidate?.isMajorUpgrade == true)
    }

    @Test func latestIsCantCompare() {
        let app = makeApp("Tool", "com.x.tool", "5.4")
        let cask = makeCask("tool", version: "latest", app: "Tool.app", quit: "com.x.tool")
        let result = StatusDecider.decide(app, findings: findings(cask: cask, for: app), options: DecisionOptions(), system: macOS27)
        guard case let .cantCheck(reason) = result.status else { Issue.record("expected cantCheck"); return }
        #expect(reason.contains("latest"))
    }

    @Test func lowMatchNeedsConfirmation() {
        let app = makeApp("Tool", "com.other.tool", "5.4")
        var cask = makeCask("tool", version: "6.0", app: "Toolkit.app")
        cask = makeCask("tool", version: "6.0", app: "Toolkit.app")
        var f = findings(cask: cask, for: app)
        // Name only ("Tool" == token "tool") with a different file name: low.
        #expect(f.match?.confidence == .low)
        f.cask = cask
        let result = StatusDecider.decide(app, findings: f, options: DecisionOptions(), system: macOS27)
        guard case .needsConfirmation = result.status else { Issue.record("expected needsConfirmation, got \(result.status)"); return }
    }

    @Test func noSourceIsCantCheck() {
        let app = makeApp("Nuvio", "com.nuvio.media.desktop", "1.1.32")
        let result = StatusDecider.decide(app, findings: SourceFindings(), options: DecisionOptions(), system: macOS27)
        #expect(result.status == .cantCheck(reason: "No update source found"))
    }

    @Test func sparkleWinsOverCask() {
        let app = makeApp("Adguard", "com.adguard.mac.adguard", "2.20.1", build: "2627", feed: "https://static.adtidy.org/appcast.xml")
        var f = findings(cask: makeCask("adguard", version: "2.20.9", app: "Adguard.app", quit: "com.adguard.mac.adguard"), for: app)
        f.sparkle = .found(.init(release: Release(source: .sparkle, version: VersionPair(short: "2.20.2", build: "2629"), basis: .bundleVersion)))
        let result = StatusDecider.decide(app, findings: f, options: DecisionOptions(), system: macOS27)
        #expect(result.status.candidate?.displayVersion == "2.20.2")
        #expect(result.decidedBy == .sparkle)
    }

    @Test func failedFeedFallsBackToCaskWithNote() {
        let app = makeApp("Adguard", "com.adguard.mac.adguard", "2.20.1", build: "2627", feed: "https://static.adtidy.org/appcast.xml")
        var f = findings(cask: makeCask("adguard", version: "2.20.2", app: "Adguard.app", quit: "com.adguard.mac.adguard"), for: app)
        f.sparkle = .failed("Feed not reachable (timed out)")
        let result = StatusDecider.decide(app, findings: f, options: DecisionOptions(), system: macOS27)
        #expect(result.decidedBy == .homebrew)
        #expect(result.status.isOutdated)
        #expect(result.notes.contains("Feed not reachable (timed out)"))
    }

    @Test func failedFeedWithoutCaskIsCantCheckWithReason() {
        let app = makeApp("Paws Off", "local.pawsoff", "2.0.10", build: "69", feed: "https://github.com/x/y/appcast.xml")
        var f = SourceFindings()
        f.sparkle = .failed("Feed not reachable (HTTP 404)")
        let result = StatusDecider.decide(app, findings: f, options: DecisionOptions(), system: macOS27)
        #expect(result.status == .cantCheck(reason: "Feed not reachable (HTTP 404)"))
    }

    @Test func installedBetaIsUpToDate() {
        let app = makeApp("Tool", "com.x.tool", "3.0b2")
        let cask = makeCask("tool", version: "2.9", app: "Tool.app", quit: "com.x.tool")
        let result = StatusDecider.decide(app, findings: findings(cask: cask, for: app), options: DecisionOptions(), system: macOS27)
        guard case .upToDate = result.status else { Issue.record("expected upToDate, got \(result.status)"); return }
    }

    @Test func tooNewForThisMac() {
        let app = makeApp("Tool", "com.x.tool", "1.0")
        let cask = makeCask("tool", version: "2.0", app: "Tool.app", quit: "com.x.tool", minimumMacOS: "28")
        let result = StatusDecider.decide(app, findings: findings(cask: cask, for: app), options: DecisionOptions(), system: macOS27)
        #expect(result.status == .upToDate(note: "Version 2.0 needs macOS 28 or later"))
    }

    @Test func appStore() {
        let app = makeApp("PasteNow", "app.pastenow.PasteNow", "2.34", build: "765", appStore: true)
        var f = SourceFindings()
        f.appStore = .found(Release(source: .appStore, version: VersionPair(short: "2.35"), basis: .shortVersion))
        #expect(StatusDecider.decide(app, findings: f, options: DecisionOptions(), system: macOS27).status.isOutdated)

        f.appStore = .found(Release(source: .appStore, version: VersionPair(short: "2.33"), basis: .shortVersion))
        guard case .upToDate = StatusDecider.decide(app, findings: f, options: DecisionOptions(), system: macOS27).status else {
            Issue.record("App Store lag must not read as a downgrade"); return
        }

        f.appStore = .found(nil)
        #expect(StatusDecider.decide(app, findings: f, options: DecisionOptions(), system: macOS27).status
            == .cantCheck(reason: "Not found in the App Store for your region"))

        let off = DecisionOptions(appStoreLookups: false)
        #expect(StatusDecider.decide(app, findings: f, options: off, system: macOS27).status
            == .cantCheck(reason: "App Store checks are turned off in Settings"))
    }

    @Test func appleAppsAreLeftToApple() {
        let app = makeApp("Final Cut Pro", "com.apple.FinalCut", "12.3")
        #expect(StatusDecider.decide(app, findings: SourceFindings(), options: DecisionOptions(), system: macOS27).status
            == .cantCheck(reason: "Updated by Apple through Software Update"))
    }

    @Test func ignoreRules() {
        let app = makeApp("Rectangle", "com.knollsoft.Rectangle", "2.0.3")
        let cask = makeCask("rectangle", version: "2.0.4", app: "Rectangle.app", quit: "com.knollsoft.Rectangle")
        let f = findings(cask: cask, for: app)

        let version = DecisionOptions(ignoreRules: IgnoreRules(versions: ["com.knollsoft.Rectangle": "2.0.4"]))
        guard case .ignored(.version("2.0.4"), let c?) = StatusDecider.decide(app, findings: f, options: version, system: macOS27).status else {
            Issue.record("expected ignored version"); return
        }
        #expect(c.displayVersion == "2.0.4")

        // A newer version than the ignored one shows again.
        let older = DecisionOptions(ignoreRules: IgnoreRules(versions: ["com.knollsoft.Rectangle": "2.0.3.9"]))
        #expect(StatusDecider.decide(app, findings: f, options: older, system: macOS27).status.isOutdated)

        let whole = DecisionOptions(ignoreRules: IgnoreRules(apps: ["com.knollsoft.Rectangle"]))
        guard case .ignored(.app, _) = StatusDecider.decide(app, findings: f, options: whole, system: macOS27).status else {
            Issue.record("expected ignored app"); return
        }
    }

    @Test func unmaintainedCaskIsNoted() {
        let app = makeApp("Tool", "com.x.tool", "1.0")
        let cask = makeCask("tool", version: "1.0", app: "Tool.app", quit: "com.x.tool", disabled: true)
        let result = StatusDecider.decide(app, findings: findings(cask: cask, for: app), options: DecisionOptions(), system: macOS27)
        #expect(result.notes.contains("No longer maintained in Homebrew"))
        #expect(result.cask?.isUnmaintained == true)
    }

    @Test func githubNewerThanCaskWins() {
        let app = makeApp("Rectangle", "com.knollsoft.Rectangle", "2.0.4")
        let cask = makeCask("rectangle", version: "2.0.4", app: "Rectangle.app", quit: "com.knollsoft.Rectangle",
                            url: "https://github.com/rxhanson/Rectangle/releases/download/v2.0.4/Rectangle2.0.4.dmg")
        var f = findings(cask: cask, for: app)
        f.github = Release(source: .github, version: VersionPair(short: "2.0.5"), basis: .shortVersion,
                           downloadURL: URL(string: "https://github.com/rxhanson/Rectangle/releases/download/v2.0.5/Rectangle2.0.5.dmg"),
                           releaseNotes: ReleaseNotes(text: "Fixes", format: .markdown))
        let result = StatusDecider.decide(app, findings: f, options: DecisionOptions(), system: macOS27)
        #expect(result.status.candidate?.source == .github)
        #expect(result.status.candidate?.displayVersion == "2.0.5")
    }
}

@Suite struct DeciderRegressionTests {
    @Test func appStoreReleaseThisMacCantRunIsNotAnUpdate() {
        let app = makeApp("Xcode", "com.apple.dt.Xcode", "27.1", appStore: true)
        var f = SourceFindings()
        f.appStore = .found(Release(source: .appStore, version: VersionPair(short: "28.0"), basis: .shortVersion, minimumOS: "28.0"))
        let result = StatusDecider.decide(app, findings: f, options: DecisionOptions(), system: macOS27)
        #expect(result.status == .upToDate(note: "Version 28.0 needs macOS 28.0 or later"))
    }

    @Test func ignoredVersionMatchesAcrossSpellings() {
        let app = makeApp("Rectangle", "com.knollsoft.Rectangle", "1.9")
        let cask = makeCask("rectangle", version: "2.0.0", app: "Rectangle.app", quit: "com.knollsoft.Rectangle")
        let options = DecisionOptions(ignoreRules: IgnoreRules(versions: ["com.knollsoft.Rectangle": "2.0"]))
        guard case .ignored(.version, _) = StatusDecider.decide(app, findings: findings(cask: cask, for: app), options: options, system: macOS27).status else {
            Issue.record("2.0 and 2.0.0 are the same version"); return
        }
    }

    @Test func githubWithoutAMacDownloadDoesNotReplaceHomebrew() {
        let app = makeApp("Rectangle", "com.knollsoft.Rectangle", "2.0.3")
        let cask = makeCask("rectangle", version: "2.0.4", app: "Rectangle.app", quit: "com.knollsoft.Rectangle",
                            url: "https://github.com/rxhanson/Rectangle/releases/download/v2.0.4/Rectangle2.0.4.dmg")
        var f = findings(cask: cask, for: app)
        f.github = Release(source: .github, version: VersionPair(short: "2.0.9"), basis: .shortVersion)
        let result = StatusDecider.decide(app, findings: f, options: DecisionOptions(), system: macOS27)
        #expect(result.status.candidate?.source == .homebrew)
        #expect(result.status.candidate?.displayVersion == "2.0.4")
    }

    @Test func sparkleManualUpgradeIsMarkedMajorAndNotInstalled() {
        let app = makeApp("Tool", "com.x.tool", "4.9", build: "490", feed: "https://example.com/appcast.xml")
        var f = SourceFindings()
        f.sparkle = .found(.init(release: Release(source: .sparkle, version: VersionPair(short: "4.10", build: "500"), basis: .bundleVersion,
                                                  downloadURL: URL(string: "https://example.com/t.zip"), minimumAutoupdateVersion: "500")))
        let result = StatusDecider.decide(app, findings: f, options: DecisionOptions(), system: macOS27)
        #expect(result.status.candidate?.isMajorUpgrade == true)
        guard case .openDownloadPage = result.action(homebrew: .showOnly) else { Issue.record("expected download page"); return }
    }
}
