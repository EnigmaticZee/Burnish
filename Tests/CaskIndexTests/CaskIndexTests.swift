import Foundation
import Inventory
import Net
import NetTesting
import Testing
import Versions
@testable import CaskIndex

let arm27 = Platform(isARM: true, macOSMajor: 27)

func fixtureData() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "casks", withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func fixtureCatalog(platform: Platform = arm27) throws -> CaskCatalog {
    CaskCatalog(casks: try CaskDataStore.parse(fixtureData(), platform: platform))
}

func app(
    _ file: String, _ bundleID: String, _ short: String?, build: String? = nil,
    names: [String] = [], caskroom: String? = nil
) -> InstalledApp {
    InstalledApp(
        bundleID: bundleID,
        name: String(file.dropLast(4)),
        bundleNames: names,
        url: URL(fileURLWithPath: "/Applications/\(file)"),
        version: VersionPair(short: short, build: build),
        signature: CodeSignature(kind: .developerID, teamID: "TEAM000001"),
        caskroomToken: caskroom
    )
}

@Suite struct ParsingTests {
    @Test func parsesTheFixture() throws {
        let catalog = try fixtureCatalog()
        #expect(catalog.count > 40)
        #expect(catalog.cask("font-0xproto") == nil, "fonts install no app and are dropped")

        let chrome = try #require(catalog.cask("google-chrome"))
        #expect(chrome.names == ["Google Chrome"])
        #expect(chrome.appNames == ["Google Chrome.app"])
        #expect(chrome.sha256 == nil, "no_check means no checksum")
        #expect(chrome.autoUpdates)
        #expect(chrome.hintBundleIDs.contains("com.google.chrome"))
        #expect(chrome.minimumMacOS == "13")
        #expect(chrome.supports(macOS: 14))
        #expect(!chrome.supports(macOS: 12))

        let firefox = try #require(catalog.cask("firefox"))
        #expect(firefox.sha256?.count == 64)
        #expect(firefox.quitBundleIDs == [["org.mozilla.firefox"]])

        let adguard = try #require(catalog.cask("adguard"))
        #expect(adguard.installsPkg)
        #expect(adguard.appNames.isEmpty)

        let logi = try #require(catalog.cask("logi-options+"))
        #expect(logi.uninstallAppNames.contains("logioptionsplus.app"))
        #expect(logi.quitBundleIDs.first?.contains("com.logi.optionsplus") == true)

        let telegram = try #require(catalog.cask("telegram"))
        #expect(telegram.versionPair == VersionPair(short: "13.1.0", build: "283357"))

        #expect(catalog.casks.contains { $0.needsManualInstall }, "fixture has a nested-container or installer cask")
        #expect(catalog.casks.contains { $0.isLatestVersion })
        #expect(catalog.cask("firefox@cn")?.disabled == true)
        #expect(catalog.casks.contains { $0.deprecated && !$0.disabled })
    }

    @Test func variationsResolveForIntel() throws {
        let arm = try #require(try fixtureCatalog(platform: arm27).cask("slack"))
        let intel = try #require(try fixtureCatalog(platform: Platform(isARM: false, macOSMajor: 27)).cask("slack"))
        #expect(arm.url?.absoluteString.contains("/arm64/") == true)
        #expect(intel.url?.absoluteString.contains("/x64/") == true)
        #expect(arm.sha256 != intel.sha256)
    }

    @Test func platformNames() {
        #expect(Platform(isARM: true, macOSMajor: 14).variationKey == "arm64_sonoma")
        #expect(Platform(isARM: false, macOSMajor: 15).variationKey == "sequoia")
        #expect(Platform(isARM: true, macOSMajor: 26).variationKey == "arm64_tahoe")
        #expect(Platform(isARM: true, macOSMajor: 31).codename == "golden_gate")
    }

    @Test(arguments: [
        ("com.knollsoft.Rectangle.plist", "com.knollsoft.Rectangle"),
        ("com.google.Chrome.savedState", "com.google.Chrome"),
        ("com.tinyspeck.slackmacgap.binarycookies", "com.tinyspeck.slackmacgap"),
        ("2BUA8C4S2C.com.1password", "com.1password"),
        ("group.com.x.shared", "com.x.shared"),
        ("com.apple.LSSharedFileList.ApplicationRecentDocuments", "com.apple.LSSharedFileList.ApplicationRecentDocuments"),
        ("org.mozilla.firefox*", "org.mozilla.firefox"),
        ("com.adguard.mac*", "com.adguard.mac"),
        ("md.obsidian.plist", "md.obsidian"),
        ("Rectangle", nil),
        ("Application Support", nil),
        ("firefox_*", nil),
        ("1.2.3", nil),
    ] as [(String, String?)])
    func bundleIDsFromPaths(_ component: String, _ expected: String?) {
        #expect(Cask.bundleID(fromComponent: component) == expected)
    }
}

@Suite struct MatcherTests {
    let matcher: CaskMatcher
    init() throws { matcher = CaskMatcher(catalog: try fixtureCatalog()) }

    @Test func bundleIDAndFileNameIsHigh() throws {
        let m = try #require(matcher.match(app("Google Chrome.app", "com.google.Chrome", "155.0.8059.86", names: ["Chrome", "Google Chrome"])))
        #expect(m.token == "google-chrome")
        #expect(m.confidence == .high)
        #expect(m.canRaiseAlert)
    }

    @Test func quitListOfAnotherAppDoesNotWin() throws {
        // wondershare-uniconverter quits com.google.Chrome before installing.
        let m = try #require(matcher.match(app("Google Chrome.app", "com.google.Chrome", "155.0", names: ["Google Chrome"])))
        #expect(m.token != "wondershare-uniconverter")
    }

    @Test func renamedAppMatchesByBundleID() throws {
        let m = try #require(matcher.match(app("Chrome 2.app", "com.google.Chrome", "155.0", names: ["Google Chrome"])))
        #expect(m.token == "google-chrome")
        #expect(m.confidence == .high)
    }

    @Test func stableChannelForStableInstall() throws {
        let m = try #require(matcher.match(app("Firefox.app", "org.mozilla.firefox", "158.0.1", build: "15826.10.19", names: ["Firefox"])))
        #expect(m.token == "firefox")
        #expect(!m.channelUnsure)
        #expect(m.alternatives.contains("firefox@beta"))
    }

    @Test func betaChannelForBetaInstall() throws {
        let m = try #require(matcher.match(app("Firefox.app", "org.mozilla.firefox", "159.0b5", names: ["Firefox"])))
        #expect(m.token == "firefox@beta")
    }

    @Test func esrChannelForEsrInstall() throws {
        let m = try #require(matcher.match(app("Firefox.app", "org.mozilla.firefox", "153.5.1", names: ["Firefox"])))
        #expect(m.token == "firefox@esr")
    }

    @Test func sameBundleIDDifferentAppName() throws {
        // brave-browser and brave-origin both clean up com.brave.Browser; only one installs Brave Browser.app.
        let m = try #require(matcher.match(app("Brave Browser.app", "com.brave.Browser", "155.1.97.57", names: ["Brave Browser"])))
        #expect(m.token == "brave-browser")
        #expect(m.confidence == .high)
    }

    @Test func pkgCaskMatchesThroughUninstallPaths() throws {
        let m = try #require(matcher.match(app("logioptionsplus.app", "com.logi.optionsplus", "2.9.994631", names: ["Logi Options+"])))
        #expect(m.token == "logi-options+")
        #expect(m.confidence == .high)
    }

    @Test func pkgCaskQuitHeadAndName() throws {
        let m = try #require(matcher.match(app("Adguard.app", "com.adguard.mac.adguard", "2.20.1", build: "2627", names: ["AdGuard"])))
        #expect(m.token == "adguard")
        #expect(m.confidence == .high)
    }

    @Test func forkWithSameNamesLosesToExactVersion() throws {
        let m = try #require(matcher.match(app("qbittorrent.app", "org.qbittorrent.qBittorrent", "5.2.3", names: ["qBittorrent"])))
        #expect(m.token == "qbittorrent")
    }

    @Test func exactVersionPicksChannel() throws {
        let m = try #require(matcher.match(app("Stremio.app", "com.westbridge.stremio5-mac", "5.1.30", names: ["Stremio"])))
        #expect(m.token == "stremio@beta")
        #expect(m.confidence == .medium)
    }

    @Test func nameOnlyIsLow() throws {
        let m = try #require(matcher.match(app("Obsidian Notes.app", "com.example.notes", "1.0", names: ["Obsidian"])))
        #expect(m.token == "obsidian")
        #expect(m.confidence == .low)
        #expect(!m.canRaiseAlert)
    }

    @Test func unknownAppHasNoMatch() {
        #expect(matcher.match(app("Nuvio.app", "com.nuvio.media.desktop", "1.1.32")) == nil)
    }

    @Test func userOverridesWin() throws {
        let nuvio = app("Nuvio.app", "com.nuvio.media.desktop", "1.1.32")
        let chosen = CaskMatcher(catalog: matcher.catalog, user: MatchOverrides(chosen: ["com.nuvio.media.desktop": "vlc"]))
        #expect(chosen.match(nuvio)?.token == "vlc")
        #expect(chosen.match(nuvio)?.confidence == .confirmed)

        let firefox = app("Firefox.app", "org.mozilla.firefox", "158.0.1", names: ["Firefox"])
        let rejected = CaskMatcher(catalog: matcher.catalog, user: MatchOverrides(rejected: ["org.mozilla.firefox": ["firefox"]]))
        #expect(rejected.match(firefox)?.token != "firefox")

        let none = CaskMatcher(catalog: matcher.catalog, user: MatchOverrides(noCask: ["org.mozilla.firefox"]))
        #expect(none.match(firefox) == nil)
    }

    @Test func communityOverridesBelowUser() throws {
        let nuvio = app("Nuvio.app", "com.nuvio.media.desktop", "1.1.32")
        let community = MatchOverrides(chosen: ["com.nuvio.media.desktop": "vlc"])
        #expect(CaskMatcher(catalog: matcher.catalog, community: community).match(nuvio)?.evidence == [.communityChoice])
        let user = MatchOverrides(rejected: ["com.nuvio.media.desktop": ["vlc"]])
        #expect(CaskMatcher(catalog: matcher.catalog, user: user, community: community).match(nuvio) == nil)
    }

    @Test func caskroomTokenIsConfirmed() throws {
        let m = try #require(matcher.match(app("Visual Studio Code.app", "com.microsoft.VSCode", "1.143.0", caskroom: "visual-studio-code")))
        #expect(m.token == "visual-studio-code")
        #expect(m.confidence == .confirmed)
    }

    @Test func tiedChannelsAreFlagged() throws {
        func cask(_ token: String, version: String) -> Cask {
            var json: [String: Any] = [
                "token": token, "name": ["Twin"], "version": version, "sha256": "no_check",
                "url": "https://example.com/twin.zip",
                "artifacts": [["app": ["Twin.app"], "target": "/Applications/Twin.app"], ["uninstall": [["quit": "com.example.twin"]]]],
            ]
            json["homepage"] = "https://example.com"
            return Cask(json: json, platform: arm27)!
        }
        let catalog = CaskCatalog(casks: [cask("twin", version: "2.0"), cask("twin-pro", version: "3.0")])
        let m = try #require(CaskMatcher(catalog: catalog).match(app("Twin.app", "com.example.twin", "1.0", names: ["Twin"])))
        #expect(m.channelUnsure)
        #expect(!m.canRaiseAlert)
    }

    @Test func search() throws {
        let catalog = matcher.catalog
        #expect(catalog.search("firefox").first?.token == "firefox")
        #expect(catalog.search("Google Chrome").first?.token == "google-chrome")
        #expect(catalog.search("").isEmpty)
    }
}

@Suite struct DataStoreTests {
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    func makeStore(_ client: HTTPClient, clock: Clock) throws -> (CaskDataStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("burnish-casks-\(UUID().uuidString)")
        return (CaskDataStore(directory: dir, client: client, platform: arm27, now: { clock.now }), dir)
    }

    @Test func fetchesThenUsesCacheThenRevalidatesWithETag() async throws {
        let client = MockHTTPClient()
        let body = try fixtureData()
        let url = CaskDataStore.sourceURL.absoluteString
        client.respond(to: url) { requested, headers in
            if headers["If-None-Match"] == "\"v1\"" { return HTTPResponse(status: 304) }
            return HTTPResponse(status: 200, headers: ["ETag": "\"v1\""], body: body)
        }
        let clock = Clock()
        let (store, dir) = try makeStore(client, clock: clock)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try await store.load()
        #expect(first.catalog.cask("firefox") != nil)
        #expect(!first.isOffline)
        #expect(client.requests.count == 1)

        clock.now += 3600
        _ = try await store.load()
        #expect(client.requests.count == 1, "fresh data is not refetched")

        // A new process: memory is gone, the compact index on disk is used.
        let (reopened, _) = (CaskDataStore(directory: dir, client: client, platform: arm27, now: { clock.now }), dir)
        #expect(try await reopened.load().catalog.cask("slack") != nil)
        #expect(client.requests.count == 1)

        clock.now += 25 * 3600
        let revalidated = try await store.load()
        #expect(client.requests.count == 2)
        #expect(revalidated.dataDate == clock.now)
        #expect(revalidated.catalog.cask("firefox") != nil)
    }

    @Test func offlineUsesLastCopy() async throws {
        let client = MockHTTPClient()
        let body = try fixtureData()
        client.respond(to: CaskDataStore.sourceURL.absoluteString, status: 200, headers: ["ETag": "x"], body: body)
        let clock = Clock()
        let (store, dir) = try makeStore(client, clock: clock)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try await store.load()

        client.respond(to: CaskDataStore.sourceURL.absoluteString) { _, _ in throw HTTPError.offline }
        clock.now += 30 * 3600
        let offline = try await store.load()
        #expect(offline.isOffline)
        #expect(offline.dataDate == first.dataDate)
        #expect(offline.catalog.cask("firefox") != nil)
    }

    @Test func offlineWithNoCopyFails() async throws {
        let client = MockHTTPClient()
        client.respond(to: CaskDataStore.sourceURL.absoluteString) { _, _ in throw HTTPError.offline }
        let (store, dir) = try makeStore(client, clock: Clock())
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: CaskDataStore.Failure.self) { try await store.load() }
    }
}

@Suite struct MatcherRegressionTests {
    func cask(_ token: String, apps: [String], names: [String], quit: Any? = nil, pkg: Bool = false, version: String = "2.0") -> Cask {
        var artifacts: [[String: Any]] = apps.map { ["app": [$0], "target": "/Applications/\($0)"] }
        if pkg { artifacts.append(["pkg": ["Thing.pkg"]]) }
        if let quit { artifacts.append(["uninstall": [["quit": quit]]]) }
        let json: [String: Any] = ["token": token, "name": names, "version": version, "sha256": "no_check",
                                   "url": "https://example.com/x.zip", "artifacts": artifacts]
        return Cask(json: json, platform: arm27)!
    }

    @Test func namesMatchButQuitIDsBelongToAnotherApp() throws {
        let catalog = CaskCatalog(casks: [cask("twin", apps: ["Twin.app"], names: ["Twin"], quit: "com.other.twin")])
        let m = try #require(CaskMatcher(catalog: catalog).match(app("Twin.app", "com.example.twin", "1.0", names: ["Twin"])))
        #expect(m.confidence == .low, "contradicting bundle ID drops to low")
        #expect(!m.canRaiseAlert)
    }

    @Test func pluginPackageThatAlsoQuitsTheHostIsNotAMatch() throws {
        let plugin = cask("host-plugin", apps: [], names: ["Host Plugin"], quit: ["com.vendor.plugin", "com.vendor.host"], pkg: true)
        let catalog = CaskCatalog(casks: [plugin])
        let m = CaskMatcher(catalog: catalog).match(app("Host.app", "com.vendor.host", "5.0", names: ["Host"]))
        #expect(m == nil || m?.canRaiseAlert == false)
    }

    @Test func rejectingAHomebrewInstalledMatchWorks() throws {
        let catalog = try fixtureCatalog()
        let brewed = app("iTerm.app", "com.googlecode.iterm2", "3.7.5", names: ["iTerm2"], caskroom: "iterm2@beta")
        let user = MatchOverrides(rejected: ["com.googlecode.iterm2": ["iterm2@beta"]])
        let m = try #require(CaskMatcher(catalog: catalog, user: user).match(brewed))
        #expect(m.token != "iterm2@beta")
        #expect(m.confidence != .confirmed)
    }
}

@Suite struct CaskroomTieTests {
    let scan = CaskroomScan(
        installed: ["iterm2@beta": ["iTerm.app"], "iterm2": ["iTerm.app"]],
        versions: ["iterm2": ["3.7.5"], "iterm2@beta": ["3.7.7beta1"]]
    )

    @Test func versionPicksTheChannel() {
        #expect(scan.token(forAppNamed: "iTerm.app", version: "3.7.5") == "iterm2")
        #expect(scan.token(forAppNamed: "iTerm.app", version: "3.7.7beta1") == "iterm2@beta")
    }

    @Test func withoutAVersionTheStableTokenWinsEveryTime() {
        for _ in 0..<20 { #expect(scan.token(forAppNamed: "iTerm.app") == "iterm2") }
    }
}
