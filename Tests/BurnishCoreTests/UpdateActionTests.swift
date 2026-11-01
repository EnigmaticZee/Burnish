import CaskIndex
import Foundation
import Installer
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

    @Test func updatesGroupByWhoInstallsThem() {
        let tool = makeApp("Tool", "com.x.tool", "1.0")
        #expect(outdated(tool, release: downloadable).updateGroup(homebrew: .showOnly) == .oneClick)
        #expect(outdated(tool, release: downloadable, major: true).updateGroup(homebrew: .showOnly) == .majorUpgrade)
        let store = Release(source: .appStore, version: VersionPair(short: "2.0"), basis: .shortVersion)
        #expect(outdated(makeApp("Paste", "com.x.paste", "1.0", appStore: true), release: store).updateGroup(homebrew: .showOnly) == .elsewhere)
        var page = downloadable
        page.downloadURL = nil
        #expect(outdated(tool, release: page).updateGroup(homebrew: .showOnly) == .download)
        var brewed = tool
        brewed.caskroomToken = "tool"
        #expect(outdated(brewed, release: downloadable).updateGroup(homebrew: .showOnly) == .elsewhere)
        #expect(outdated(brewed, release: downloadable).updateGroup(homebrew: .upgradeWithBrew) == .oneClick)
        #expect(AppCheckResult(app: tool, status: .upToDate(note: nil), decidedBy: nil).updateGroup(homebrew: .showOnly) == nil)
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

    @Test func installReportCarriesTheFileFactsButNotTheDownloadLink() throws {
        var release = downloadable
        release.downloadURL = URL(string: "https://cdn.example.com/private/path/Tool-2.0.dmg?token=abc")
        let r = outdated(makeApp("Tool", "com.x.tool", "1.0"), release: release)
        let refusal = InstallRefusal(.unpack, "The download couldn't be opened (tar)", downloadPage: nil,
                                     evidence: "Tool-2.0.dmg · 12 bytes · starts fd377a58 · read as tarXz")
        let url = InstallReport.url(for: r, refusal: refusal, burnish: "0.4.1-beta (37)", system: "macOS 27.0.1, Apple silicon")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let value = { (name: String) in components.queryItems?.first { $0.name == name }?.value ?? "" }
        #expect(value("labels") == "install")
        #expect(value("title").contains("com.x.tool"))
        let body = value("body")
        #expect(body.contains("starts fd377a58") && body.contains("unpack: The download couldn't be opened (tar)"))
        #expect(body.contains("cdn.example.com") && body.contains("Tool-2.0.dmg") && body.contains("0.4.1-beta (37)"))
        #expect(!body.contains("private/path") && !body.contains("token=abc"), "the download link stays out of a public issue")
    }

    @Test func feedsCanBeAddedForAppsTheCommunityCanHelpWith() throws {
        let r = AppCheckResult(app: makeApp("Tool", "com.x.tool", "1.0", build: "10"), status: .cantCheck(reason: "No update feed found"))
        #expect(r.canAddFeed)
        let feed = CommunityFeed(sparkle: URL(string: "https://example.com/appcast.xml"))
        let components = try #require(URLComponents(url: FeedSuggestion.url(for: r, feed: feed), resolvingAgainstBaseURL: false))
        let body = try #require(components.queryItems?.first { $0.name == "body" }?.value)
        #expect(body.contains("\"com.x.tool\": { \"sparkle\": \"https://example.com/appcast.xml\" }"), "ready to paste into the community file")
        #expect(!body.contains("/Applications"), "no file paths or other personal data")

        let apple = AppCheckResult(app: makeApp("Final Cut Pro", "com.apple.FinalCut", "12.0"), status: .cantCheck(reason: "Updated by Apple"))
        #expect(!apple.canAddFeed, "Apple's apps update through Apple")
        let fine = AppCheckResult(app: makeApp("Tool", "com.x.tool", "1.0"), status: .upToDate(note: nil))
        #expect(!fine.canAddFeed)
    }

    @Test func aFeedThePersonAddedIsReadButNeverInstalledFrom() {
        var release = downloadable
        release.addedByUser = true
        let r = outdated(makeApp("Tool", "com.x.tool", "1.0"), release: release)
        guard case .openDownloadPage = r.action(homebrew: .showOnly) else { Issue.record("expected the download page"); return }
        #expect(r.hallmarks(homebrew: .showOnly).first?.title == "A feed you added")
    }
}
