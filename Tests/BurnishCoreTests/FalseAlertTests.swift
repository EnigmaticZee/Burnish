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
@Suite struct FalseAlertTests {
    enum Truth { case update, noAlert }

    struct Case {
        let name: String
        let id: String
        let short: String
        var build: String?
        var file: String?
        let truth: Truth
    }

    static let cases: [Case] = [
        // Installed at Homebrew's version.
        Case(name: "Google Chrome", id: "com.google.Chrome", short: "156.0.8078.48", build: "8078.48", truth: .noAlert),
        Case(name: "Firefox", id: "org.mozilla.firefox", short: "158.0.1", build: "15826.10.19", truth: .noAlert),
        Case(name: "Brave Browser", id: "com.brave.Browser", short: "157.1.98.60", build: "198.60", truth: .noAlert),
        Case(name: "Brave Origin", id: "com.brave.Origin", short: "157.1.98.60", build: "198.60", truth: .noAlert),
        Case(name: "Visual Studio Code", id: "com.microsoft.VSCode", short: "1.143.1", truth: .noAlert),
        Case(name: "iTerm2", id: "com.googlecode.iterm2", short: "3.7.6", file: "iTerm", truth: .noAlert),
        Case(name: "Slack", id: "com.tinyspeck.slackmacgap", short: "4.52.182", truth: .noAlert),
        Case(name: "1Password", id: "com.1password.1password", short: "8.12.42", truth: .noAlert),
        Case(name: "Rectangle", id: "com.knollsoft.Rectangle", short: "2.0.4", build: "104", truth: .noAlert),
        Case(name: "CleanMyMac", id: "com.macpaw.CleanMyMac5", short: "5.7.2", build: "50702.0.2610141002", file: "CleanMyMac_5", truth: .noAlert),
        Case(name: "Discord", id: "com.hnc.Discord", short: "0.0.419", truth: .noAlert),
        Case(name: "Figma", id: "com.figma.Desktop", short: "126.9.16", truth: .noAlert),
        Case(name: "Stremio", id: "com.stremio.stremio", short: "5.1.26", truth: .noAlert),
        Case(name: "Obsidian", id: "md.obsidian", short: "1.14.5", truth: .noAlert),
        Case(name: "Spotify", id: "com.spotify.client", short: "1.3.6.1921", truth: .noAlert),
        Case(name: "VLC", id: "org.videolan.vlc", short: "3.0.24", truth: .noAlert),
        Case(name: "Telegram", id: "ru.keepcoder.Telegram", short: "13.1.0", build: "283357", truth: .noAlert),
        Case(name: "BetterDisplay", id: "pro.betterdisplay.BetterDisplay", short: "5.1.1", truth: .noAlert),
        Case(name: "Wondershare UniConverter 18", id: "com.wondershare.UniConverter18", short: "18.0.0", truth: .noAlert),

        // Other channels: must match their own channel, never be "updated" to another.
        Case(name: "Firefox", id: "org.mozilla.firefox", short: "153.5.1", build: "15326.10.20", file: "Firefox ESR", truth: .noAlert),
        Case(name: "Firefox Developer Edition", id: "org.mozilla.firefoxdeveloperedition", short: "159.0b5", truth: .noAlert),
        Case(name: "Google Chrome Beta", id: "com.google.Chrome.beta", short: "157.0.8103.15", truth: .noAlert),
        Case(name: "Google Chrome Canary", id: "com.google.Chrome.canary", short: "158.0.8122.0", truth: .noAlert),
        Case(name: "Google Chrome Dev", id: "com.google.Chrome.dev", short: "158.0.8117.2", truth: .noAlert),
        Case(name: "Brave Browser Beta", id: "com.brave.Browser.beta", short: "157.1.99.44", build: "199.44", truth: .noAlert),
        Case(name: "Discord Canary", id: "com.hnc.DiscordCanary", short: "0.0.1423", truth: .noAlert),
        Case(name: "Discord PTB", id: "com.hnc.DiscordPTB", short: "0.0.268", truth: .noAlert),
        Case(name: "Figma Beta", id: "com.figma.FigmaBeta", short: "126.11.5", truth: .noAlert),

        // Ahead of Homebrew (betas, or Homebrew lagging): never a downgrade.
        Case(name: "iTerm2", id: "com.googlecode.iterm2", short: "3.7.7beta1", file: "iTerm Beta", truth: .noAlert),
        Case(name: "Slack", id: "com.tinyspeck.slackmacgap", short: "4.53.269", file: "Slack Beta", truth: .noAlert),
        Case(name: "VLC", id: "org.videolan.vlc", short: "3.0.25", file: "VLC Nightly", truth: .noAlert),
        Case(name: "Obsidian", id: "md.obsidian", short: "1.15.0", file: "Obsidian Insider", truth: .noAlert),
        Case(name: "Rectangle", id: "com.knollsoft.Rectangle", short: "2.1.0", build: "110", file: "Rectangle Next", truth: .noAlert),

        // Lookalikes: a name or file that resembles a Homebrew app, but a different app.
        Case(name: "Firefox", id: "com.example.firefox-reskin", short: "1.0", file: "Firefox Reskin", truth: .noAlert),
        Case(name: "Telegram Desktop", id: "org.telegram.desktop", short: "5.6.3", truth: .noAlert),
        Case(name: "Visual Studio Code - Insiders", id: "com.microsoft.VSCodeInsiders", short: "1.144.0", truth: .noAlert),
        Case(name: "Rectangle Pro", id: "com.knollsoft.Hookshot", short: "3.0.29", truth: .noAlert),
        Case(name: "Chrome Remote Desktop Host", id: "com.google.chrome.remote", short: "120.0.6099.3", truth: .noAlert),
        Case(name: "Spotify Mini Player", id: "com.example.spotify-mini", short: "2.0", truth: .noAlert),
        Case(name: "Discord Overlay", id: "com.example.discord-overlay", short: "1.4", truth: .noAlert),
        Case(name: "Slack Desktop Tools", id: "com.example.slack-tools", short: "0.9", truth: .noAlert),
        Case(name: "Brave Search", id: "com.example.brave-search", short: "1.0", truth: .noAlert),
        Case(name: "Acme Inventory", id: "com.acme.inventory", short: "2.3", truth: .noAlert),
        Case(name: "Obsidian Web Clipper", id: "com.example.obsidian-clipper", short: "0.11.4", truth: .noAlert),
        Case(name: "VLC Remote", id: "com.example.vlc-remote", short: "1.2", truth: .noAlert),

        // Genuinely out of date: these must be found.
        Case(name: "Firefox", id: "org.mozilla.firefox", short: "157.0.2", build: "15726.10.6", file: "Firefox Old", truth: .update),
        Case(name: "Discord", id: "com.hnc.Discord", short: "0.0.416", file: "Discord Old", truth: .update),
        Case(name: "Visual Studio Code", id: "com.microsoft.VSCode", short: "1.142.0", file: "Visual Studio Code Old", truth: .update),
        Case(name: "Telegram", id: "ru.keepcoder.Telegram", short: "13.0.0", build: "280000", file: "Telegram Old", truth: .update),
        Case(name: "VLC", id: "org.videolan.vlc", short: "3.0.21", file: "VLC Old", truth: .update),
    ]

    static func app(_ c: Case) -> InstalledApp {
        InstalledApp(
            bundleID: c.id, name: c.name, bundleNames: [c.name], url: URL(fileURLWithPath: "/Applications/\(c.file ?? c.name).app"),
            version: VersionPair(short: c.short, build: c.build),
            signature: CodeSignature(kind: .developerID, teamID: "TEAM000001")
        )
    }

    /// The matcher tests' 51-cask cut of Homebrew's list, shared rather than copied.
    static func homebrewFixture() throws -> Data {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: tests.appendingPathComponent("CaskIndexTests/Fixtures/casks.json"))
    }

    @Test func fiftyAppsNoFalseAlerts() async throws {
        #expect(Self.cases.count == 50)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("burnish-truth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = MockHTTPClient()
        client.respond(to: CaskDataStore.sourceURL.absoluteString, body: try Self.homebrewFixture())
        let platform = Platform(isARM: true, macOSMajor: 27)
        let checker = UpdateChecker(client: client, caskStore: CaskDataStore(directory: dir, client: client, platform: platform),
                                    system: SystemVersion("27.0"), platform: platform, storefront: nil)

        let apps = Self.cases.map(Self.app)
        let report = await checker.check(apps, options: CheckOptions(appStoreLookups: false))
        let byPath = Dictionary(uniqueKeysWithValues: report.results.map { ($0.app.url.path, $0) })

        var falseAlerts: [String] = []
        var missed: [String] = []
        for c in Self.cases {
            let result = try #require(byPath["/Applications/\(c.file ?? c.name).app"])
            switch (c.truth, result.status.isOutdated) {
            case (.noAlert, true):
                falseAlerts.append("\(c.file ?? c.name) \(c.short) → \(result.status.candidate?.displayVersion ?? "?") via \(result.match?.token ?? "-")")
            case (.update, false):
                missed.append("\(c.file ?? c.name) \(c.short): \(result.status)")
            default:
                break
            }
        }
        #expect(falseAlerts.isEmpty, "false alerts: \(falseAlerts)")
        #expect(missed.isEmpty, "missed updates: \(missed)")
        // Silence would pass the test above too, so the known apps must actually be recognised.
        #expect(report.results.filter { $0.status.tab == .upToDate }.count >= 30, "known apps recognised, not shrugged off")
    }
}
