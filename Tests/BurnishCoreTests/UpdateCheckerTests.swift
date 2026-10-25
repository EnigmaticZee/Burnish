import CaskIndex
import Foundation
import Inventory
import Net
import NetTesting
import Store
import Testing
import UpdateSources
import Versions
@testable import BurnishCore

final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AppCheckResult] = []
    func add(_ r: AppCheckResult) { lock.withLock { items.append(r) } }
    var all: [AppCheckResult] { lock.withLock { items } }
}

@Suite struct UpdateCheckerTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("burnish-checker-\(UUID().uuidString)")

    func casksFixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "casks", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func checksEverySourceAndStreamsResults() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = MockHTTPClient()
        client.respond(to: CaskDataStore.sourceURL.absoluteString, headers: ["ETag": "\"x\""], body: try casksFixture())
        client.respond(to: "https://example.com/appcast.xml", text: """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <sparkle:version>2629</sparkle:version><sparkle:shortVersionString>2.20.2</sparkle:shortVersionString>
        <enclosure url="https://example.com/AdGuard.dmg" length="1" type="application/octet-stream"/>
        </item></channel></rss>
        """)
        client.respond(to: "https://example.com/dead.xml", status: 500, text: "")
        // Any App Store lookup URL answers with PasteNow 2.35.
        let lookup = """
        {"resultCount":1,"results":[{"bundleId":"app.pastenow.PasteNow","version":"2.35","trackId":1552536109}]}
        """
        for entity in ["desktopSoftware", "software"] {
            let url = AppStoreSource(client: client, country: nil).url(for: ["app.pastenow.PasteNow"], entity: entity)
            client.respond(to: url.absoluteString, text: lookup)
        }

        let platform = Platform(isARM: true, macOSMajor: 27)
        let checker = UpdateChecker(client: client, caskStore: CaskDataStore(directory: dir, client: client, platform: platform),
                                    system: SystemVersion("27.0"), platform: platform, storefront: nil)
        var adguard = makeApp("Adguard", "com.adguard.mac.adguard", "2.20.1", build: "2627", feed: "https://example.com/appcast.xml")
        adguard = InstalledApp(bundleID: adguard.bundleID, name: "Adguard", bundleNames: ["AdGuard"], url: adguard.url, version: adguard.version,
                               signature: adguard.signature, sparkleFeedURL: adguard.sparkleFeedURL)
        let apps = [
            adguard,
            makeApp("Google Chrome", "com.google.Chrome", "155.0.8059.86", build: "8059.86"),
            makeApp("Firefox", "org.mozilla.firefox", "158.0.1", build: "15826.10.19"),
            makeApp("Discord", "com.hnc.Discord", "0.0.416", feed: "https://example.com/dead.xml"),
            makeApp("PasteNow", "app.pastenow.PasteNow", "2.34", build: "765", appStore: true),
            makeApp("Nuvio", "com.nuvio.media.desktop", "1.1.32"),
            makeApp("Final Cut Pro", "com.apple.FinalCut", "12.3"),
        ]
        let streamed = Collected()
        let report = await checker.check(apps, options: CheckOptions(appStoreLookups: true)) { streamed.add($0) }

        #expect(streamed.all.count == apps.count, "every result streams out as it finishes")
        #expect(!report.isOffline)
        #expect(report.problems.isEmpty, "\(report.problems)")
        let byName = Dictionary(uniqueKeysWithValues: report.results.map { ($0.app.name, $0) })

        #expect(byName["Adguard"]?.decidedBy == .sparkle)
        #expect(byName["Adguard"]?.status.candidate?.displayVersion == "2.20.2")
        #expect(byName["Google Chrome"]?.decidedBy == .homebrew)
        #expect(byName["Google Chrome"]?.status.isOutdated == true)
        guard case .upToDate = byName["Firefox"]?.status else { Issue.record("Firefox should be up to date"); return }
        // A dead feed falls back to Homebrew and says so.
        #expect(byName["Discord"]?.decidedBy == .homebrew)
        #expect(byName["Discord"]?.notes.contains { $0.contains("Feed not reachable") } == true)
        #expect(byName["PasteNow"]?.status.candidate?.displayVersion == "2.35")
        #expect(byName["Nuvio"]?.status == .cantCheck(reason: "No update source found"))
        #expect(byName["Final Cut Pro"]?.status == .cantCheck(reason: "Updated by Apple through Software Update"))
        #expect(report.results.map(\.app.name) == report.results.map(\.app.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    @Test func noAppStoreRequestWhenTurnedOff() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = MockHTTPClient()
        client.respond(to: CaskDataStore.sourceURL.absoluteString, body: try casksFixture())
        let platform = Platform(isARM: true, macOSMajor: 27)
        let checker = UpdateChecker(client: client, caskStore: CaskDataStore(directory: dir, client: client, platform: platform),
                                    system: SystemVersion("27.0"), platform: platform, storefront: nil)
        let report = await checker.check([makeApp("PasteNow", "app.pastenow.PasteNow", "2.34", appStore: true)],
                                         options: CheckOptions(appStoreLookups: false))
        #expect(!client.requests.contains { $0.host == "itunes.apple.com" }, "no bundle IDs sent to Apple")
        #expect(report.results.first?.status == .cantCheck(reason: "App Store checks are turned off in Settings"))
    }

    @Test func offlineWithoutAnyCaskDataStillChecksFeeds() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = MockHTTPClient()
        client.respond(to: CaskDataStore.sourceURL.absoluteString) { _, _ in throw HTTPError.offline }
        let platform = Platform(isARM: true, macOSMajor: 27)
        let checker = UpdateChecker(client: client, caskStore: CaskDataStore(directory: dir, client: client, platform: platform),
                                    system: SystemVersion("27.0"), platform: platform, storefront: nil)
        let report = await checker.check([makeApp("Google Chrome", "com.google.Chrome", "155.0")], options: CheckOptions())
        #expect(report.isOffline)
        #expect(!report.problems.isEmpty)
        #expect(report.results.first?.status == .cantCheck(reason: "No update source found"))
    }
}

@Suite struct CommunityOverridesTests {
    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    @Test func fetchesCachesAndRevalidates() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("burnish-community-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = MockHTTPClient()
        let body = Data(#"{"schema":1,"overrides":{"com.x.app":"x-app","com.y.none":null}}"#.utf8)
        client.respond(to: CommunityOverrides.sourceURL.absoluteString) { url, headers in
            headers["If-None-Match"] == "\"e1\"" ? HTTPResponse(status: 304)
                : HTTPResponse(status: 200, headers: ["ETag": "\"e1\""], body: body)
        }
        let clock = Clock()
        let community = CommunityOverrides(client: client, store: StateStore(directory: dir), now: { clock.now })

        let first = await community.load()
        #expect(first.chosen == ["com.x.app": "x-app"])
        #expect(first.noCask == ["com.y.none"])
        _ = await community.load()
        #expect(client.requests.count == 1, "at most once a day")

        clock.now += 25 * 3600
        let again = await community.load()
        #expect(client.requests.count == 2)
        #expect(again == first)

        client.respond(to: CommunityOverrides.sourceURL.absoluteString) { _, _ in throw HTTPError.offline }
        clock.now += 25 * 3600
        #expect(await community.load() == first, "offline uses the last copy")
    }

    @Test func unknownSchemaIsIgnored() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("burnish-community-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = MockHTTPClient()
        client.respond(to: CommunityOverrides.sourceURL.absoluteString, text: #"{"schema":2,"overrides":{"a.b.c":"evil"}}"#)
        #expect(await CommunityOverrides(client: client, store: StateStore(directory: dir)).load() == .none)
    }
}

@Suite struct CommunityFeeds {
    @Test func readsSafeFeedsAndDropsTheRest() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("burnish-feeds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = MockHTTPClient()
        client.respond(to: CommunityOverrides.sourceURL.absoluteString, text: """
        {"schema":1,"overrides":{},"feeds":{
          "com.a.sparkle":{"sparkle":"https://a.example.com/appcast.xml"},
          "com.b.github":{"github":"owner/repo"},
          "com.c.http":{"sparkle":"http://insecure.example.com/appcast.xml"},
          "com.d.bad":{"github":"not-a-repo"}}}
        """)
        let feeds = await CommunityOverrides(client: client, store: StateStore(directory: dir)).feeds()
        #expect(Set(feeds.keys) == ["com.a.sparkle", "com.b.github"])
    }

    @Test func aListedFeedSpotsTheUpdateButLeavesTheInstallToYou() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("burnish-feeds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = MockHTTPClient()
        client.respond(to: CaskDataStore.sourceURL.absoluteString, text: "[]")
        client.respond(to: "https://feeds.example.com/appcast.xml", text: """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <sparkle:version>300</sparkle:version><sparkle:shortVersionString>3.0</sparkle:shortVersionString>
        <enclosure url="https://feeds.example.com/Niche-3.0.zip" length="1" type="application/octet-stream"/>
        </item></channel></rss>
        """)
        let platform = Platform(isARM: true, macOSMajor: 27)
        let checker = UpdateChecker(client: client, caskStore: CaskDataStore(directory: dir, client: client, platform: platform),
                                    system: SystemVersion("27.0"), platform: platform, storefront: nil)
        let app = makeApp("Niche", "com.example.niche", "2.0", build: "200")
        let feeds = ["com.example.niche": CommunityFeed(sparkle: URL(string: "https://feeds.example.com/appcast.xml"))]
        let report = await checker.check([app], options: CheckOptions(communityFeeds: feeds))
        let result = try #require(report.results.first)
        #expect(result.status.candidate?.displayVersion == "3.0")
        #expect(result.status.candidate?.release.listedByCommunity == true)
        guard case .openDownloadPage = result.action(homebrew: .showOnly) else { Issue.record("must not install from a community feed"); return }
        #expect(result.hallmarks(homebrew: .showOnly).first?.state == .notAvailable)
    }
}
