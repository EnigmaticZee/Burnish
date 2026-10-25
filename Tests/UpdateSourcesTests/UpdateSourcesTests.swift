import CaskIndex
import Foundation
import Inventory
import Net
import NetTesting
import Testing
import Versions
@testable import UpdateSources

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct SparkleTests {
    let client = MockHTTPClient()
    let feed = URL(string: "https://example.com/appcast.xml")!

    func source(os: String = "14.5", arm: Bool = true) -> SparkleSource {
        SparkleSource(client: client, system: SystemVersion(os), isARM: arm, language: "en")
    }

    @Test func picksNewestItemThisMacCanRun() async throws {
        client.respond(to: feed.absoluteString, body: try fixture("appcast-sparkle2.xml"))
        let result = try await source().check(feed: feed)
        let release = try #require(result.release)
        // 3.0b1 is on the beta channel, 2.2.0 needs macOS 99, the Windows build is skipped.
        #expect(release.version == VersionPair(short: "2.1.0", build: "210"))
        #expect(release.basis == .bundleVersion)
        #expect(release.downloadURL?.absoluteString == "https://example.com/downloads/Example-2.1.0.zip")
        #expect(release.edSignature == "c2lnbmF0dXJl", "the delta's signature must not leak into the full item")
        #expect(release.length == 1234)
        #expect(release.minimumOS == "13.0")
        #expect(release.downloadPage?.absoluteString == "https://example.com/releases/2.1.0")
        #expect(release.date != nil)
        #expect(release.releaseNotes?.format == .html)
        #expect(result.newerButIncompatible == "Version 2.2.0 needs macOS 99.0 or later")

        let doc = try #require(ReleaseNotesDocument.from(release.releaseNotes!))
        #expect(!doc.plainText.contains("alert"))
        #expect(doc.plainText.contains("Faster sync"))
    }

    @Test func comparesAgainstBundleVersion() async throws {
        client.respond(to: feed.absoluteString, body: try fixture("appcast-sparkle2.xml"))
        let release = try #require(try await source().check(feed: feed).release)
        #expect(release.compare(with: VersionPair(short: "2.0.0", build: "200")) == .newer(major: false))
        #expect(release.compare(with: VersionPair(short: "2.1.0", build: "210")) == .same)
        #expect(release.compare(with: VersionPair(short: "2.1.1", build: "211")) == .older)
    }

    @Test func olderMacGetsOlderItem() async throws {
        client.respond(to: feed.absoluteString, body: try fixture("appcast-sparkle2.xml"))
        let release = try #require(try await source(os: "12.7").check(feed: feed).release)
        #expect(release.version.short == "2.0.0")
        #expect(release.releaseNotes?.link?.absoluteString == "https://example.com/notes/2.0.0.html")
    }

    @Test func sparkleOneFeedKeepsVersionsOnEnclosure() async throws {
        let old = URL(string: "https://old.example.com/appcast.xml")!
        client.respond(to: old.absoluteString, body: try fixture("appcast-sparkle1.xml"))
        let release = try #require(try await source().check(feed: old).release)
        #expect(release.version == VersionPair(short: "1.4.2", build: "142"))
        #expect(release.edSignature == nil)
        #expect(release.date != nil)
    }

    @Test func informationalUpdateHasNothingToInstall() async throws {
        let url = URL(string: "https://example.com/info.xml")!
        client.respond(to: url.absoluteString, body: try fixture("appcast-informational.xml"))
        let release = try #require(try await source().check(feed: url).release)
        #expect(release.isInformational)
        #expect(release.isCritical)
        #expect(release.downloadURL == nil)
        #expect(release.downloadPage?.absoluteString == "https://example.com/buy")
    }

    @Test func failures() async throws {
        await #expect(throws: SparkleSource.Failure.notHTTPS) {
            try await source().check(feed: URL(string: "http://example.com/appcast.xml")!)
        }
        await #expect(throws: SparkleSource.Failure.self) {
            try await source().check(feed: URL(string: "https://example.com/missing.xml")!)
        }
        client.respond(to: "https://example.com/garbage.xml", text: "<html><body>not a feed")
        await #expect(throws: SparkleSource.Failure.self) {
            try await source().check(feed: URL(string: "https://example.com/garbage.xml")!)
        }
        client.respond(to: "https://example.com/slow.xml") { _, _ in throw HTTPError.timedOut }
        await #expect(throws: SparkleSource.Failure.unreachable("Timed out")) {
            try await source().check(feed: URL(string: "https://example.com/slow.xml")!)
        }
    }
}

@Suite struct AppStoreTests {
    @Test func parsesLookupAndIgnoresUnaskedApps() throws {
        let releases = try AppStoreSource.parse(try fixture("appstore-lookup.json"), asked: ["app.pastenow.PasteNow", "com.apple.dt.Xcode"])
        #expect(releases.count == 2)
        let paste = try #require(releases["app.pastenow.PasteNow"])
        #expect(paste.version.short == "2.35")
        #expect(paste.appStoreID == 1552536109)
        #expect(paste.downloadPage?.absoluteString == "macappstore://apps.apple.com/app/id1552536109")
        #expect(paste.releaseNotes?.format == .plainText)
        #expect(paste.compare(with: VersionPair(short: "2.34", build: "765")) == .newer(major: false))
        let doc = try #require(ReleaseNotesDocument.from(paste.releaseNotes!))
        #expect(doc.blocks.count == 3)
    }

    @Test func batchesOf200() {
        let ids = (0..<450).map { "com.example.app\($0)" }
        let batches = AppStoreSource.batches(of: ids)
        #expect(batches.map(\.count) == [200, 200, 50])
    }

    @Test func lookupURL() {
        let source = AppStoreSource(client: MockHTTPClient(), country: "CA")
        let url = source.url(for: ["a.b.c", "d.e.f"], entity: "desktopSoftware").absoluteString
        #expect(url.hasPrefix("https://itunes.apple.com/lookup?"))
        #expect(url.contains("bundleId=a.b.c,d.e.f"))
        #expect(url.contains("country=ca"))
    }
}

@Suite struct ElectronTests {
    @Test func feedsFromConfig() throws {
        let generic = try ElectronSource.feed(fromConfig: "provider: generic\nurl: https://downloads.example.com/updates\nchannel: latest\n")
        #expect(generic.manifest.absoluteString == "https://downloads.example.com/updates/latest-mac.yml")

        let github = try ElectronSource.feed(fromConfig: "owner: obsidianmd\nrepo: obsidian-releases\nprovider: github\nupdaterCacheDirName: obsidian-updater\n")
        #expect(github.manifest.absoluteString == "https://github.com/obsidianmd/obsidian-releases/releases/latest/download/latest-mac.yml")

        let beta = try ElectronSource.feed(fromConfig: "provider: generic\nurl: 'https://x.example.com/u/'\nchannel: beta\n")
        #expect(beta.manifest.absoluteString == "https://x.example.com/u/beta-mac.yml")

        let s3 = try ElectronSource.feed(fromConfig: "provider: s3\nbucket: my-app\nregion: us-west-2\npath: /releases\n")
        #expect(s3.manifest.absoluteString == "https://my-app.s3.us-west-2.amazonaws.com/releases/latest-mac.yml")

        #expect(throws: ElectronSource.Failure.self) { try ElectronSource.feed(fromConfig: "provider: keygen\naccount: x\n") }
        #expect(throws: ElectronSource.Failure.self) { try ElectronSource.feed(fromConfig: "provider: generic\nurl: http://insecure.example.com\n") }
    }

    @Test func manifestPicksArchZipAndResolvesURL() throws {
        let text = String(decoding: try fixture("latest-mac.yml"), as: UTF8.self)
        let feed = try ElectronSource.feed(fromConfig: "provider: generic\nurl: https://releases.example.com/mac")
        let arm = try ElectronSource(client: MockHTTPClient(), isARM: true).release(fromManifest: text, feed: feed)
        #expect(arm.version.short == "1.9.10")
        #expect(arm.downloadURL?.absoluteString == "https://releases.example.com/mac/Obsidian-1.9.10-arm64-mac.zip")
        #expect(arm.sha512 == "YXJtLXppcA==")
        #expect(arm.length == 100000000)
        #expect(arm.date != nil)
        let armNotes = try #require(arm.releaseNotes)
        let notes = try #require(ReleaseNotesDocument.from(armNotes))
        #expect(notes.plainText.contains("Faster startup"))

        let intel = try ElectronSource(client: MockHTTPClient(), isARM: false).release(fromManifest: text, feed: feed)
        #expect(intel.downloadURL?.lastPathComponent == "Obsidian-1.9.10-mac.zip")
    }

    @Test func githubProviderUsesVTag() throws {
        let text = String(decoding: try fixture("latest-mac.yml"), as: UTF8.self)
        let feed = try ElectronSource.feed(fromConfig: "provider: github\nowner: o\nrepo: r\n")
        let release = try ElectronSource(client: MockHTTPClient(), isARM: true).release(fromManifest: text, feed: feed)
        #expect(release.downloadURL?.absoluteString == "https://github.com/o/r/releases/download/v1.9.10/Obsidian-1.9.10-arm64-mac.zip")
        #expect(release.downloadPage?.absoluteString == "https://github.com/o/r/releases")
    }

    @Test func checkReadsConfigFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("app-update.yml")
        try "provider: generic\nurl: https://releases.example.com/mac\n".write(to: config, atomically: true, encoding: .utf8)
        let client = MockHTTPClient()
        client.respond(to: "https://releases.example.com/mac/latest-mac.yml", body: try fixture("latest-mac.yml"))
        let release = try await ElectronSource(client: client, isARM: true).check(configFile: config)
        #expect(release.source == .electron)
        #expect(release.compare(with: VersionPair(short: "1.9.7")) == .newer(major: false))
    }

    @Test func yaml() {
        let doc = MiniYAML.parse("""
        # comment
        version: "2.0.0"
        url: https://example.com/a:b
        notes: >
          folded
          text
        files:
          - url: a.zip
            sha512: x
          - url: b.dmg
        tags:
          - one
        """)
        #expect(doc["version"]?.string == "2.0.0")
        #expect(doc["url"]?.string == "https://example.com/a:b")
        #expect(doc["notes"]?.string == "folded text")
        #expect(doc["files"]?.list?.count == 2)
        #expect(doc["files"]?.list?.first?["sha512"] == "x")
        #expect(doc["tags"]?.list?.first?[""] == "one")
    }
}

@Suite struct GitHubTests {
    let repo = GitHubRepository(owner: "rxhanson", name: "Rectangle")
    let api = "https://api.github.com/repos/rxhanson/Rectangle/releases/latest"

    func rectangleCask() throws -> Cask {
        let json: [String: Any] = [
            "token": "rectangle", "name": ["Rectangle"], "version": "2.0.4",
            "sha256": "9f820a2e56bd2c27cdda4fb4556de3cbcfcbac052d9eeb2179d49e2dae277abc",
            "url": "https://github.com/rxhanson/Rectangle/releases/download/v2.0.4/Rectangle2.0.4.dmg",
            "homepage": "https://rectangleapp.com/",
            "artifacts": [["app": ["Rectangle.app"], "target": "/Applications/Rectangle.app"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: [json])
        return try #require(try CaskDataStore.parse(data, platform: Platform(isARM: true, macOSMajor: 27)).first)
    }

    @Test func repositoryFromCaskURL() throws {
        #expect(HomebrewSource.githubRepository(for: try rectangleCask()) == repo)
        #expect(GitHubRepository(releaseAssetURL: URL(string: "https://example.com/owner/repo/releases/download/x")!) == nil)
        #expect(GitHubRepository(releaseAssetURL: URL(string: "https://github.com/owner/repo/archive/x.zip")!) == nil)
    }

    @Test func latestReleaseAndAssetForCask() async throws {
        let client = MockHTTPClient()
        client.respond(to: api, headers: ["ETag": "\"abc\""], body: try fixture("github-release.json"))
        let source = GitHubSource(client: client)
        let latest = try await source.latestRelease(of: repo)
        #expect(latest.versionString == "2.0.5")

        let release = try #require(GitHubSource.release(latest, forCask: try rectangleCask()))
        #expect(release.source == .github)
        #expect(release.downloadURL?.lastPathComponent == "Rectangle2.0.5.dmg")
        #expect(release.sha256 == "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")
        #expect(release.compare(with: VersionPair(short: "2.0.4")) == .newer(major: false))
        let releaseNotes = try #require(release.releaseNotes)
        let notes = try #require(ReleaseNotesDocument.from(releaseNotes))
        #expect(notes.blocks.first == .heading(level: 3, [.init(text: "Fixes")]))
    }

    @Test func conditionalRequestReusesCache() async throws {
        let client = MockHTTPClient()
        let body = try fixture("github-release.json")
        client.respond(to: api) { url, headers in
            headers["If-None-Match"] == "\"abc\""
                ? HTTPResponse(status: 304)
                : HTTPResponse(status: 200, headers: ["ETag": "\"abc\""], body: body)
        }
        let source = GitHubSource(client: client)
        _ = try await source.latestRelease(of: repo)
        let again = try await source.latestRelease(of: repo)
        #expect(again.tag == "v2.0.5")
        #expect(client.requests.count == 2)
    }

    @Test func rateLimitAndMissing() async throws {
        let client = MockHTTPClient()
        client.respond(to: api, status: 403, text: "{}")
        await #expect(throws: GitHubSource.Failure.rateLimited) { try await GitHubSource(client: client).latestRelease(of: repo) }
        client.respond(to: api, status: 404, text: "{}")
        await #expect(throws: GitHubSource.Failure.noRelease) { try await GitHubSource(client: client).latestRelease(of: repo) }
    }

    @Test(arguments: [("v2.0.4", "2.0.4"), ("2.0.4", "2.0.4"), ("release-1.2", "1.2"), ("app/v3.1.0", "3.1.0"), ("nightly", nil), ("#12", nil)] as [(String, String?)])
    func tags(_ tag: String, _ expected: String?) {
        #expect(GitHubRelease.version(fromTag: tag) == expected)
    }
}

@Suite struct ReleaseNotesTests {
    @Test func sanitisesHTML() {
        let doc = ReleaseNotesDocument.html("""
        <html><head><title>x</title><style>body{color:red}</style></head><body>
        <h1>Version 2</h1>
        <p>Hello&nbsp;<b>bold</b> and <i>italic</i> &amp; <a href="https://example.com/more">more</a>.</p>
        <p onclick="evil()">Click <a href="javascript:alert(1)">here</a></p>
        <img src="https://tracker.example.com/pixel.gif">
        <iframe src="https://evil.example.com"></iframe>
        <script>document.write('x')</script>
        <ol><li>First</li><li>Second<ul><li>Nested</li></ul></li></ol>
        <pre>let x = 1
        let y = 2</pre>
        <!-- comment <b>hidden</b> -->
        </body></html>
        """)
        let text = doc.plainText
        #expect(!text.contains("color:red"))
        #expect(!text.contains("document.write"))
        #expect(!text.contains("hidden"))
        #expect(!text.contains("javascript"))
        #expect(doc.blocks.first == .heading(level: 1, [.init(text: "Version 2")]))
        guard case let .paragraph(runs) = doc.blocks[1] else { Issue.record("expected paragraph"); return }
        #expect(runs.map(\.text).joined() == "Hello bold and italic & more.")
        #expect(runs.contains { $0.bold && $0.text == "bold" })
        #expect(runs.contains { $0.italic && $0.text == "italic" })
        #expect(runs.contains { $0.link?.absoluteString == "https://example.com/more" })
        guard case let .paragraph(click) = doc.blocks[2] else { Issue.record("expected paragraph"); return }
        #expect(click.allSatisfy { $0.link == nil }, "javascript: links are dropped")
        #expect(doc.blocks.contains(.listItem(ordered: 1, depth: 0, [.init(text: "First")])))
        #expect(doc.blocks.contains(.listItem(ordered: nil, depth: 1, [.init(text: "Nested")])))
        #expect(doc.blocks.contains { if case .code(let c) = $0 { c.contains("let y = 2") } else { false } })
    }

    @Test func entities() {
        #expect(ReleaseNotesDocument.decodeEntities("a &lt;b&gt; &#169; &#x2014; &bogus; &") == "a <b> © — &bogus; &")
    }

    @Test func markdown() {
        let doc = ReleaseNotesDocument.markdown("""
        ## New
        - **Bold** item
        - [Link](https://example.com) and `code`

        1. one
        2. two

        ```
        raw <b>text</b>
        ```
        Paragraph line one
        line two
        """)
        #expect(doc.blocks.first == .heading(level: 2, [.init(text: "New")]))
        #expect(doc.blocks.contains(.listItem(ordered: 2, depth: 0, [.init(text: "two")])))
        #expect(doc.blocks.contains(.code("raw <b>text</b>")))
        #expect(doc.blocks.last == .paragraph([.init(text: "Paragraph line one line two")]))
        guard case let .listItem(_, _, runs) = doc.blocks[1] else { Issue.record("expected item"); return }
        #expect(runs.first == .init(text: "Bold", bold: true))
    }
}

@Suite struct GitHubGuardTests {
    func cask(url: String) throws -> Cask {
        let json: [String: Any] = ["token": "tool", "name": ["Tool"], "version": "1.2.0", "sha256": "no_check", "url": url,
                                   "artifacts": [["app": ["Tool.app"], "target": "/Applications/Tool.app"]]]
        return try #require(try CaskDataStore.parse(try JSONSerialization.data(withJSONObject: [json]), platform: Platform(isARM: true, macOSMajor: 27)).first)
    }

    func release(tag: String, assets: [String] = []) -> GitHubRelease {
        GitHubRelease(tag: tag, body: "notes", page: URL(string: "https://github.com/o/r/releases/tag/\(tag)"), publishedAt: nil,
                      assets: assets.map { .init(name: $0, url: URL(string: "https://github.com/o/r/releases/download/\(tag)/\($0)")!, size: 1, digest: nil) })
    }

    @Test func anotherProductsTagIsIgnored() throws {
        let c = try cask(url: "https://github.com/o/r/releases/download/v1.2.0/Tool-1.2.0.dmg")
        #expect(GitHubSource.release(release(tag: "cli-v3.0.0"), forCask: c) == nil)
        #expect(GitHubSource.release(release(tag: "v1.3.0", assets: ["Tool-1.3.0.dmg"]), forCask: c)?.downloadURL != nil)
    }

    @Test func prereleaseTagsAreIgnored() throws {
        let c = try cask(url: "https://github.com/o/r/releases/download/v1.2.0/Tool-1.2.0.dmg")
        #expect(GitHubSource.release(release(tag: "v1.3.0-beta.1"), forCask: c) == nil)
    }

    @Test func noMacAssetMeansNoDownload() throws {
        let c = try cask(url: "https://github.com/o/r/releases/download/v1.2.0/Tool-1.2.0.dmg")
        #expect(GitHubSource.release(release(tag: "v1.3.0", assets: ["Tool-1.3.0-windows.exe"]), forCask: c)?.downloadURL == nil)
    }
}

@Suite struct SparkleRules {
    func item(_ short: String, _ build: String, channel: String? = nil) -> AppcastItem {
        var item = AppcastItem()
        item.shortVersion = short
        item.version = build
        item.channel = channel
        item.enclosure = .init(url: URL(string: "https://example.com/\(short).zip"))
        return item
    }

    @Test func staysOnTheChosenMajorAndSaysWhatsAbove() throws {
        let source = SparkleSource(client: MockHTTPClient(), system: SystemVersion("27.0"), isARM: true)
        let items = [item("6.0", "600"), item("5.9", "590"), item("5.8", "580")]
        let result = try source.select(from: items, preferences: .init(maximumMajor: 5))
        #expect(result.release?.version.short == "5.9", "the newest 5.x")
        #expect(result.newerButIncompatible == "Version 6.0 is out; you chose to stay on 5.x")
        #expect(try source.select(from: items).release?.version.short == "6.0")
    }

    @Test func betasOnlyWhenAsked() throws {
        let source = SparkleSource(client: MockHTTPClient(), system: SystemVersion("27.0"), isARM: true)
        let items = [item("2.1b1", "211", channel: "beta"), item("2.0", "200")]
        #expect(try source.select(from: items).release?.version.short == "2.0")
        #expect(try source.select(from: items, preferences: .init(includeBeta: true)).release?.version.short == "2.1b1")
    }
}

@Suite struct QuickReadDigest {
    @Test func sortsLinesByHeadingAndWords() throws {
        let doc = ReleaseNotesDocument.markdown("""
        ## New
        - Dark mode for the editor
        - Export to PDF
        ## Bug Fixes
        - Fixed a crash when opening large files
        - Sync no longer stalls on slow networks
        - Typo in the About window
        ## Security
        - Patched CVE-2026-1234 in the image parser
        """)
        let digest = try #require(ReleaseDigest.make(doc))
        #expect(digest.counts[.new] == 2)
        #expect(digest.counts[.fix] == 3, "the typo line counts as a fix by its heading")
        #expect(digest.counts[.security] == 1)
        #expect(digest.highlights.map(\.kind) == [.security, .new, .fix], "security first, at most three")
        #expect(digest.highlights.first?.text == "Patched CVE-2026-1234 in the image parser")
        #expect(digest.headline == "1 security fixes, 2 shiny new things, and 3 squashed bugs" || digest.headline.contains("2 shiny new things"))
    }

    @Test func noSummaryWhenThereIsNothingToSort() {
        #expect(ReleaseDigest.make(ReleaseNotesDocument.plainText("Thanks for using our app!")) == nil)
        #expect(ReleaseDigest.make(ReleaseNotesDocument.markdown("- Fixed one thing")) == nil, "one line isn't worth summarising")
    }

    @Test func longLinesAreShortenedAtAWord() {
        let long = String(repeating: "word ", count: 40)
        let short = ReleaseDigest.shortened(long)
        #expect(short.count <= 101 && short.hasSuffix("…"))
    }
}

@Suite struct WhatYouMissed {
    func item(_ short: String, _ build: String, notes: String) -> AppcastItem {
        var item = AppcastItem()
        item.shortVersion = short
        item.version = build
        item.descriptions = ["": "<p>\(notes)</p>"]
        item.enclosure = .init(url: URL(string: "https://example.com/\(short).zip"))
        return item
    }

    @Test func listsTheVersionsInBetweenNewestFirst() throws {
        let source = SparkleSource(client: MockHTTPClient(), system: SystemVersion("27.0"), isARM: true, language: nil)
        let items = [item("1.3", "130", notes: "Three"), item("1.2", "120", notes: "Two"), item("1.1", "110", notes: "One"), item("1.0", "100", notes: "Zero")]
        let result = try source.select(from: items, installed: VersionPair(short: "1.0", build: "100"))
        #expect(result.release?.version.short == "1.3")
        #expect(result.release?.missed?.map(\.version) == ["1.2", "1.1"], "the installed version and the newest aren't repeated")
        #expect(result.release?.missed?.first?.notes?.text?.contains("Two") == true)
        #expect(try source.select(from: items, installed: VersionPair(short: "1.2", build: "120")).release?.missed == nil, "one version behind")
    }
}
