import CaskIndex
import Foundation
import Inventory
import NetTesting
import UpdateSources
import Testing
import Versions
@testable import BurnishCore

/// The promise that matters most: a wrong "Update available" costs more than a missed one. Fifty
/// installed apps whose right answer is known, checked end to end against a real cut of Homebrew's
/// data. Up-to-date apps, other channels (ESR, Beta, Canary), betas ahead of Homebrew and
/// lookalike apps must never raise an update; a handful of genuinely old copies must.
///
/// Installed versions follow the sample rather than being typed in, so the sample can be re-cut
/// from today's Homebrew list (a monthly job does) and the right answers still hold.
@Suite struct FalseAlertTests {
    enum Truth { case update, noAlert }

    /// How an app's installed version relates to the sample.
    enum Pin {
        /// Exactly the version Homebrew lists for this cask. Brave reports Chromium's major version
        /// in front of its own, so it gets a prefix.
        case atHomebrew(String, prefix: String? = nil)
        /// One step newer than Homebrew's: a beta or a release Homebrew hasn't caught up with.
        case ahead(String, suffix: String? = nil)
        /// One step older than Homebrew's.
        case behind(String)
        /// An app the sample doesn't list; the version is whatever it is.
        case fixed(String, build: String? = nil)
    }

    struct Case {
        let name: String
        let id: String
        let pin: Pin
        var file: String?
        let truth: Truth
    }

    static let cases: [Case] = [
        // Installed at Homebrew's version.
        Case(name: "Google Chrome", id: "com.google.Chrome", pin: .atHomebrew("google-chrome"), truth: .noAlert),
        Case(name: "Firefox", id: "org.mozilla.firefox", pin: .atHomebrew("firefox"), truth: .noAlert),
        Case(name: "Brave Browser", id: "com.brave.Browser", pin: .atHomebrew("brave-browser", prefix: "157."), truth: .noAlert),
        Case(name: "Brave Origin", id: "com.brave.Origin", pin: .atHomebrew("brave-origin", prefix: "157."), truth: .noAlert),
        Case(name: "Visual Studio Code", id: "com.microsoft.VSCode", pin: .atHomebrew("visual-studio-code"), truth: .noAlert),
        Case(name: "iTerm2", id: "com.googlecode.iterm2", pin: .atHomebrew("iterm2"), file: "iTerm", truth: .noAlert),
        Case(name: "Slack", id: "com.tinyspeck.slackmacgap", pin: .atHomebrew("slack"), truth: .noAlert),
        Case(name: "1Password", id: "com.1password.1password", pin: .atHomebrew("1password"), truth: .noAlert),
        Case(name: "Rectangle", id: "com.knollsoft.Rectangle", pin: .atHomebrew("rectangle"), truth: .noAlert),
        Case(name: "CleanMyMac", id: "com.macpaw.CleanMyMac5", pin: .atHomebrew("cleanmymac"), file: "CleanMyMac_5", truth: .noAlert),
        Case(name: "Discord", id: "com.hnc.Discord", pin: .atHomebrew("discord"), truth: .noAlert),
        Case(name: "Figma", id: "com.figma.Desktop", pin: .atHomebrew("figma"), truth: .noAlert),
        Case(name: "Stremio", id: "com.stremio.stremio", pin: .atHomebrew("stremio"), truth: .noAlert),
        Case(name: "Obsidian", id: "md.obsidian", pin: .atHomebrew("obsidian"), truth: .noAlert),
        Case(name: "Spotify", id: "com.spotify.client", pin: .atHomebrew("spotify"), truth: .noAlert),
        Case(name: "VLC", id: "org.videolan.vlc", pin: .atHomebrew("vlc"), truth: .noAlert),
        Case(name: "Telegram", id: "ru.keepcoder.Telegram", pin: .atHomebrew("telegram"), truth: .noAlert),
        // Kept out of the sample on purpose (scripts/make-cask-fixture.py): an app Homebrew has no entry for.
        Case(name: "BetterDisplay", id: "pro.betterdisplay.BetterDisplay", pin: .fixed("5.1.1"), truth: .noAlert),
        Case(name: "Wondershare UniConverter 18", id: "com.wondershare.UniConverter18", pin: .atHomebrew("wondershare-uniconverter"), truth: .noAlert),

        // Other channels: must match their own channel, never be "updated" to another.
        Case(name: "Firefox", id: "org.mozilla.firefox", pin: .atHomebrew("firefox@esr"), file: "Firefox ESR", truth: .noAlert),
        Case(name: "Firefox Developer Edition", id: "org.mozilla.firefoxdeveloperedition", pin: .atHomebrew("firefox@developer-edition"), truth: .noAlert),
        Case(name: "Google Chrome Beta", id: "com.google.Chrome.beta", pin: .atHomebrew("google-chrome@beta"), truth: .noAlert),
        Case(name: "Google Chrome Canary", id: "com.google.Chrome.canary", pin: .atHomebrew("google-chrome@canary"), truth: .noAlert),
        Case(name: "Google Chrome Dev", id: "com.google.Chrome.dev", pin: .atHomebrew("google-chrome@dev"), truth: .noAlert),
        Case(name: "Brave Browser Beta", id: "com.brave.Browser.beta", pin: .atHomebrew("brave-browser@beta", prefix: "157."), truth: .noAlert),
        Case(name: "Discord Canary", id: "com.hnc.DiscordCanary", pin: .atHomebrew("discord@canary"), truth: .noAlert),
        Case(name: "Discord PTB", id: "com.hnc.DiscordPTB", pin: .atHomebrew("discord@ptb"), truth: .noAlert),
        Case(name: "Figma Beta", id: "com.figma.FigmaBeta", pin: .atHomebrew("figma@beta"), truth: .noAlert),

        // Ahead of Homebrew (betas, or Homebrew lagging): never a downgrade.
        Case(name: "iTerm2", id: "com.googlecode.iterm2", pin: .ahead("iterm2", suffix: "beta1"), file: "iTerm Beta", truth: .noAlert),
        Case(name: "Slack", id: "com.tinyspeck.slackmacgap", pin: .ahead("slack"), file: "Slack Beta", truth: .noAlert),
        Case(name: "VLC", id: "org.videolan.vlc", pin: .ahead("vlc"), file: "VLC Nightly", truth: .noAlert),
        Case(name: "Obsidian", id: "md.obsidian", pin: .ahead("obsidian"), file: "Obsidian Insider", truth: .noAlert),
        Case(name: "Rectangle", id: "com.knollsoft.Rectangle", pin: .ahead("rectangle"), file: "Rectangle Next", truth: .noAlert),

        // Lookalikes: a name or file that resembles a Homebrew app, but a different app.
        Case(name: "Firefox", id: "com.example.firefox-reskin", pin: .fixed("1.0"), file: "Firefox Reskin", truth: .noAlert),
        Case(name: "Telegram Desktop", id: "org.telegram.desktop", pin: .fixed("5.6.3"), truth: .noAlert),
        Case(name: "Visual Studio Code - Insiders", id: "com.microsoft.VSCodeInsiders", pin: .fixed("1.144.0"), truth: .noAlert),
        Case(name: "Rectangle Pro", id: "com.knollsoft.Hookshot", pin: .fixed("3.0.29"), truth: .noAlert),
        Case(name: "Chrome Remote Desktop Host", id: "com.google.chrome.remote", pin: .fixed("120.0.6099.3"), truth: .noAlert),
        Case(name: "Spotify Mini Player", id: "com.example.spotify-mini", pin: .fixed("2.0"), truth: .noAlert),
        Case(name: "Discord Overlay", id: "com.example.discord-overlay", pin: .fixed("1.4"), truth: .noAlert),
        Case(name: "Slack Desktop Tools", id: "com.example.slack-tools", pin: .fixed("0.9"), truth: .noAlert),
        Case(name: "Brave Search", id: "com.example.brave-search", pin: .fixed("1.0"), truth: .noAlert),
        Case(name: "Acme Inventory", id: "com.acme.inventory", pin: .fixed("2.3"), truth: .noAlert),
        Case(name: "Obsidian Web Clipper", id: "com.example.obsidian-clipper", pin: .fixed("0.11.4"), truth: .noAlert),
        Case(name: "VLC Remote", id: "com.example.vlc-remote", pin: .fixed("1.2"), truth: .noAlert),

        // Genuinely out of date: these must be found.
        Case(name: "Firefox", id: "org.mozilla.firefox", pin: .behind("firefox"), file: "Firefox Old", truth: .update),
        Case(name: "Discord", id: "com.hnc.Discord", pin: .behind("discord"), file: "Discord Old", truth: .update),
        Case(name: "Visual Studio Code", id: "com.microsoft.VSCode", pin: .behind("visual-studio-code"), file: "Visual Studio Code Old", truth: .update),
        Case(name: "Telegram", id: "ru.keepcoder.Telegram", pin: .behind("telegram"), file: "Telegram Old", truth: .update),
        Case(name: "VLC", id: "org.videolan.vlc", pin: .behind("vlc"), file: "VLC Old", truth: .update),
    ]

    /// The installed version a case gets against this sample.
    static func version(_ pin: Pin, casks: [String: Cask]) throws -> VersionPair {
        switch pin {
        case let .fixed(short, build):
            return VersionPair(short: short, build: build)
        case let .atHomebrew(token, prefix):
            let pair = try #require(casks[token], "\(token) is in the sample").versionPair
            guard let prefix, let short = pair.short else { return pair }
            // Brave's cask says 1.98.63.0; the app says 157.1.98.63.
            let trimmed = short.hasSuffix(".0") ? String(short.dropLast(2)) : short
            return VersionPair(short: prefix + trimmed, build: pair.build)
        case let .ahead(token, suffix):
            let cask = try #require(casks[token], "\(token) is in the sample")
            let short = try #require(cask.versionPair.short)
            return VersionPair(short: step(short, by: 1) + (suffix ?? ""))
        case let .behind(token):
            let cask = try #require(casks[token], "\(token) is in the sample")
            let short = try #require(cask.versionPair.short)
            return VersionPair(short: step(short, by: -1))
        }
    }

    /// Moves the last numeric component (the last non-zero one when going down) by `delta`.
    static func step(_ short: String, by delta: Int) -> String {
        var parts = short.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for i in parts.indices.reversed() {
            if let n = Int(parts[i]), delta > 0 || n > 0 {
                parts[i] = String(n + delta)
                return parts.joined(separator: ".")
            }
        }
        return short
    }

    static func app(_ c: Case, version: VersionPair) -> InstalledApp {
        InstalledApp(
            bundleID: c.id, name: c.name, bundleNames: [c.name], url: URL(fileURLWithPath: "/Applications/\(c.file ?? c.name).app"),
            version: version, signature: CodeSignature(kind: .developerID, teamID: "TEAM000001")
        )
    }

    /// The matcher tests' cut of Homebrew's list, shared rather than copied.
    static func homebrewFixture() throws -> Data {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: tests.appendingPathComponent("CaskIndexTests/Fixtures/casks.json"))
    }

    @Test func versionsStepUpAndDown() {
        #expect(Self.step("3.7.6", by: 1) == "3.7.7")
        #expect(Self.step("159.0", by: -1) == "158.0")
        #expect(Self.step("13.1.0", by: -1) == "13.0.0")
        #expect(Self.step("0.0.420", by: -1) == "0.0.419")
    }

    @Test func fiftyAppsNoFalseAlerts() async throws {
        #expect(Self.cases.count == 50)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("burnish-truth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try Self.homebrewFixture()
        let platform = Platform(isARM: true, macOSMajor: 27)
        let casks = Dictionary(uniqueKeysWithValues: try CaskDataStore.parse(fixture, platform: platform).map { ($0.token, $0) })
        let client = MockHTTPClient()
        client.respond(to: CaskDataStore.sourceURL.absoluteString, body: fixture)
        let checker = UpdateChecker(client: client, caskStore: CaskDataStore(directory: dir, client: client, platform: platform),
                                    system: SystemVersion("27.0"), platform: platform, storefront: nil)

        let versions = try Self.cases.map { try Self.version($0.pin, casks: casks) }
        let apps = zip(Self.cases, versions).map { Self.app($0, version: $1) }
        let report = await checker.check(apps, options: CheckOptions(appStoreLookups: false))
        let byPath = Dictionary(uniqueKeysWithValues: report.results.map { ($0.app.url.path, $0) })

        var falseAlerts: [String] = []
        var missed: [String] = []
        for (c, version) in zip(Self.cases, versions) {
            let result = try #require(byPath["/Applications/\(c.file ?? c.name).app"])
            switch (c.truth, result.status.isOutdated) {
            case (.noAlert, true):
                falseAlerts.append("\(c.file ?? c.name) \(version.display) → \(result.status.candidate?.displayVersion ?? "?") via \(result.match?.token ?? "-")")
            case (.update, false):
                missed.append("\(c.file ?? c.name) \(version.display): \(result.status)")
            default:
                break
            }
        }
        #expect(falseAlerts.isEmpty, "false alerts: \(falseAlerts)")
        #expect(missed.isEmpty, "missed updates: \(missed)")
        // Silence would pass the test above too, so the known apps must actually be recognised.
        let recognised = report.results.filter { $0.status.tab == .upToDate }.count
        #expect(recognised >= 30, "known apps recognised, not shrugged off")

        // The accuracy ledger: CI publishes this run's numbers with each release, for the website.
        if let path = ProcessInfo.processInfo.environment["BURNISH_LEDGER"] {
            let expected = Self.cases.filter { $0.truth == .update }.count
            let ledger: [String: Int] = ["apps": Self.cases.count, "falseAlerts": falseAlerts.count,
                                         "updatesExpected": expected, "updatesFound": expected - missed.count, "recognised": recognised]
            try JSONSerialization.data(withJSONObject: ledger, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }
}
