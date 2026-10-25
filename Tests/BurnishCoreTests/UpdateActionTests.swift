import CaskIndex
import Foundation
import Inventory
import Store
import Testing
import UpdateSources
import Versions
@testable import BurnishCore

func outdated(_ app: InstalledApp, release: Release, major: Bool = false) -> AppCheckResult {
    AppCheckResult(app: app, status: .outdated(UpdateCandidate(release: release, isMajorUpgrade: major)), decidedBy: release.source)
}

let downloadable = Release(source: .homebrew, version: VersionPair(short: "2.0"), basis: .shortVersion,
                           downloadURL: URL(string: "https://example.com/a.zip"), downloadPage: URL(string: "https://example.com"))

@Suite struct UpdateActionTests {
    @Test func signedDirectDownloadInstalls() {
        let r = outdated(makeApp("Tool", "com.x.tool", "1.0"), release: downloadable)
        #expect(r.action(homebrew: .showOnly) == .install)
        #expect(r.includedInUpdateAll(homebrew: .showOnly))
    }

    @Test func majorUpgradesAreNeverInUpdateAll() {
        let r = outdated(makeApp("Tool", "com.x.tool", "1.0"), release: downloadable, major: true)
        #expect(r.action(homebrew: .showOnly) == .install, "still updatable one at a time")
        #expect(!r.includedInUpdateAll(homebrew: .showOnly))
    }

    @Test func appStoreOpensTheStore() {
        let store = Release(source: .appStore, version: VersionPair(short: "2.0"), basis: .shortVersion, downloadPage: URL(string: "macappstore://apps.apple.com/app/id1"))
        let r = outdated(makeApp("Paste", "com.x.paste", "1.0", appStore: true), release: store)
        #expect(r.action(homebrew: .showOnly) == .openAppStore(URL(string: "macappstore://apps.apple.com/app/id1")))
        #expect(!r.includedInUpdateAll(homebrew: .showOnly))
    }

    @Test func homebrewManagedAppsFollowTheSetting() {
        var app = makeApp("Code", "com.microsoft.VSCode", "1.0")
        app.caskroomToken = "visual-studio-code"
        let r = outdated(app, release: downloadable)
        #expect(r.action(homebrew: .showOnly) == .managedByHomebrew(token: "visual-studio-code"))
        #expect(!r.includedInUpdateAll(homebrew: .showOnly))
        #expect(r.action(homebrew: .upgradeWithBrew) == .brewUpgrade(token: "visual-studio-code"))
        #expect(r.includedInUpdateAll(homebrew: .upgradeWithBrew))
    }

    @Test func unsignedAppsOnlyGetTheDownloadPage() {
        let app = InstalledApp(bundleID: "local.x", name: "Mine", url: URL(fileURLWithPath: "/Applications/Mine.app"),
                               version: VersionPair(short: "1.0"), signature: CodeSignature(kind: .adHoc))
        let r = outdated(app, release: downloadable)
        guard case .openDownloadPage = r.action(homebrew: .showOnly) else { Issue.record("expected download page"); return }
        #expect(!r.includedInUpdateAll(homebrew: .showOnly))
    }

    @Test func informationalAndManualUpdatesOpenThePage() {
        var info = downloadable
        info.isInformational = true
        guard case .openDownloadPage = outdated(makeApp("Tool", "com.x.tool", "1.0"), release: info).action(homebrew: .showOnly) else {
            Issue.record("expected download page"); return
        }
        var manual = downloadable
        manual.downloadURL = nil
        guard case .openDownloadPage = outdated(makeApp("Tool", "com.x.tool", "1.0"), release: manual).action(homebrew: .showOnly) else {
            Issue.record("expected download page"); return
        }
    }

    @Test func noActionWhenNotOutdated() {
        let r = AppCheckResult(app: makeApp("Tool", "com.x.tool", "1.0"), status: .upToDate(note: nil))
        #expect(r.action(homebrew: .showOnly) == .none)
    }

    @Test func wrongMatchReportCarriesOnlyTheAppFacts() throws {
        var r = outdated(makeApp("Tool", "com.x.tool", "1.0", build: "10"), release: downloadable)
        r.match = CaskMatch(token: "tool", confidence: .high, evidence: [.bundleIDQuit])
        let url = WrongMatchReport.url(for: r)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(url.absoluteString.hasPrefix("https://github.com/EnigmaticZee/Burnish/issues/new"))
        let body = try #require(components.queryItems?.first { $0.name == "body" }?.value)
        #expect(body.contains("com.x.tool"))
        #expect(body.contains("`tool`"))
        #expect(!body.contains("/Applications"), "no file paths or other personal data")
    }
}
