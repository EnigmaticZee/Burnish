#if DEBUG
import AppKit
import BurnishCore
import CaskIndex
import Inventory
import Store
import SwiftUI
import UpdateSources
import Versions
import WidgetUI

/// Debug builds only: `Burnish --render-previews <folder>` draws each screen offscreen to PNG
/// (light and dark) from the last saved report, then quits. Used to check layout without
/// screenshots of the real desktop. Add `--demo` to use the sample apps below instead of this
/// Mac's report (the README art uses that, so nobody's app list ends up on GitHub).
@MainActor
enum PreviewRenderer {
    static func runIfRequested(model: AppModel) -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--render-previews"), flag + 1 < args.count else { return false }
        let folder = URL(fileURLWithPath: args[flag + 1])
        let demo = args.contains("--demo")
        Task {
            if demo {
                model.loadDemo(DemoData.results(), history: DemoData.history(), lastCheck: Date().addingTimeInterval(-7 * 60))
            } else {
                await model.loadSnapshot()
            }
            renderMenuBarIcons(to: folder)
            renderWidgets(model: model, to: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for dark in [false, true] {
                let suffix = dark ? "-dark" : ""
                render(PopoverView().environment(model), width: 360, height: nil, dark: dark, to: folder.appendingPathComponent("popover\(suffix).png"))
                model.selectedTab = .updates
                model.selectedID = model.outdated.first?.id
                render(MainWindow().environment(model), width: 1040, height: 660, dark: dark, to: folder.appendingPathComponent("main\(suffix).png"))
                render(SettingsView().environment(model), width: 480, height: nil, dark: dark, to: folder.appendingPathComponent("settings\(suffix).png"))
                render(OnboardingView().environment(model), width: 480, height: 460, dark: dark, to: folder.appendingPathComponent("onboarding\(suffix).png"))
            }
            for tab in StatusTab.allCases {
                model.selectedTab = tab
                model.selectedID = model.results(in: tab).first?.id
                render(MainWindow().environment(model), width: 1040, height: 660, dark: false, to: folder.appendingPathComponent("tab-\(tab.rawValue).png"))
            }
            for (index, result) in model.results.prefix(40).enumerated() {
                render(DetailView(result: result).environment(model), width: 520, height: 1300, dark: false,
                       to: folder.appendingPathComponent(String(format: "detail-%02d-%@.png", index, result.app.name.replacingOccurrences(of: " ", with: "_"))))
            }
            NSApp.terminate(nil)
        }
        return true
    }

    /// The desktop widget, small and medium, on a rounded card like the desktop draws.
    static func renderWidgets(model: AppModel, to folder: URL) {
        let top = model.outdated.prefix(3).map {
            WidgetSnapshot.Item(name: $0.app.name, installed: $0.app.version.display,
                                latest: $0.status.candidate?.displayVersion ?? "", appPath: $0.app.url.path)
        }
        let snapshot = WidgetSnapshot(updateCount: model.outdated.count, top: Array(top), lastCheck: model.lastCheck)
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            for (size, width) in [(UpdatesWidgetView.Size.small, CGFloat(170)), (.medium, 364)] {
                let card = UpdatesWidgetView(snapshot: snapshot, size: size)
                    .padding(16)
                    .frame(width: width, height: 170)
                    .background(RoundedRectangle(cornerRadius: 22).fill(.background.secondary))
                    .padding(20)
                render(card, width: width + 40, height: 210, dark: dark,
                       to: folder.appendingPathComponent("widget-\(size == .small ? "small" : "medium")\(suffix).png"))
            }
        }
    }

    /// The menu bar glyph in each state, at 4x, on a light and a dark strip.
    static func renderMenuBarIcons(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let states: [(Bool, Int, Bool)] = [(false, 0, false), (true, 2, false), (false, 0, true)]
        let strip = NSImage(size: NSSize(width: 260, height: 100), flipped: false) { rect in
            for (row, dark) in [false, true].enumerated() {
                (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(x: 0, y: CGFloat(row) * 50, width: rect.width, height: 50).fill()
                for (i, state) in states.enumerated() {
                    let icon = MenuBarIcon.image(checking: state.0, frame: state.1, dot: state.2)
                    let tinted = NSImage(size: icon.size, flipped: false) { r in
                        icon.draw(in: r)
                        (dark ? NSColor.white : NSColor.black).set()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: NSRect(x: 20 + CGFloat(i) * 80, y: CGFloat(row) * 50 + 9, width: 36, height: 32))
                }
            }
            return true
        }
        if let tiff = strip.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("menubar-icon.png"))
        }
    }

    static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat?, dark: Bool, to url: URL) {
        let host = NSHostingView(rootView: view.frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor)))
        let size = height.map { NSSize(width: width, height: $0) } ?? host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.close()
    }
}
/// Sample apps for README art: well-known apps, versions that read naturally, every state shown.
enum DemoData {
    static func app(_ name: String, _ id: String, _ short: String, build: String? = nil, appStore: Bool = false,
                    folder: String = "/Applications", team: String = "DEMO000001", caskroom: String? = nil) -> InstalledApp {
        InstalledApp(bundleID: id, name: name, bundleNames: [name], url: URL(fileURLWithPath: "\(folder)/\(name).app"),
                     version: VersionPair(short: short, build: build),
                     signature: CodeSignature(kind: appStore ? .appStore : .developerID, teamID: team, authority: appStore ? nil : "Developer ID Application: \(name) (\(team))"),
                     isAppStore: appStore, caskroomToken: caskroom, modificationDate: Date().addingTimeInterval(-86400 * 20))
    }

    static func outdated(_ app: InstalledApp, _ latest: String, _ source: SourceKind, token: String? = nil, major: Bool = false,
                         notes: ReleaseNotes? = nil, daysAgo: Double = 2) -> AppCheckResult {
        let release = Release(source: source, version: VersionPair(short: latest), basis: .shortVersion,
                              downloadURL: source == .appStore ? nil : URL(string: "https://example.com/\(app.name).dmg"),
                              downloadPage: URL(string: "https://example.com"), releaseNotes: notes,
                              date: Date().addingTimeInterval(-86400 * daysAgo))
        var result = AppCheckResult(app: app, status: .outdated(UpdateCandidate(release: release, isMajorUpgrade: major)), decidedBy: source)
        if let token { result.match = CaskMatch(token: token, confidence: .high, evidence: [.bundleIDQuit, .fileName, .displayName]) }
        return result
    }

    /// Brave was updated last week and its earlier copy is still "in the Trash" (a temporary
    /// folder), so its detail pane offers Put Back; Discord shows a find and a refusal.
    static func history() -> UpdateHistory {
        let trash = FileManager.default.temporaryDirectory.appendingPathComponent("burnish-demo-trash", isDirectory: true)
        let earlier = trash.appendingPathComponent("Brave Browser 1.97.124 (replaced).app")
        try? FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
        let day: TimeInterval = 86400
        var history = UpdateHistory()
        history.record(.found(version: "1.98.60", source: "homebrew"), for: "com.brave.Browser", at: Date().addingTimeInterval(-6 * day))
        history.record(.updated(from: "1.97.124", to: "1.98.60", previousCopy: earlier.path), for: "com.brave.Browser",
                       at: Date().addingTimeInterval(-6 * day + 3600))
        history.record(.found(version: "0.0.419", source: "homebrew"), for: "com.hnc.Discord", at: Date().addingTimeInterval(-2 * day))
        return history
    }

    static func results() -> [AppCheckResult] {
        let notes = ReleaseNotes(text: """
        <h3>What's new</h3>
        <ul><li><b>Faster startup</b> on Apple silicon</li><li>Sharper icons in the sidebar</li><li>Fixes a crash when reconnecting a display</li></ul>
        """, format: .html, link: URL(string: "https://example.com/notes"))
        var results: [AppCheckResult] = [
            outdated(app("Google Chrome", "com.google.Chrome", "155.0.8059.86"), "156.0.8078.48", .homebrew, token: "google-chrome", daysAgo: 1),
            outdated(app("Firefox", "org.mozilla.firefox", "157.0.2"), "158.0.1", .homebrew, token: "firefox", daysAgo: 3),
            outdated(app("Discord", "com.hnc.Discord", "0.0.416"), "0.0.419", .homebrew, token: "discord", daysAgo: 2),
            outdated(app("Adguard", "com.adguard.mac.adguard", "2.20.1", build: "2627"), "2.20.2", .sparkle, token: "adguard", notes: notes, daysAgo: 3),
            outdated(app("Figma", "com.figma.Desktop", "126.9.16"), "126.10.11", .homebrew, token: "figma", daysAgo: 4),
            outdated(app("Slack", "com.tinyspeck.slackmacgap", "4.51.140", appStore: true), "4.52.182", .appStore, daysAgo: 3),
        ]
        func upToDate(_ a: InstalledApp, _ source: SourceKind, note: String? = nil) -> AppCheckResult {
            AppCheckResult(app: a, status: .upToDate(note: note), decidedBy: source)
        }
        results += [
            upToDate(app("Brave Browser", "com.brave.Browser", "1.98.60"), .homebrew),
            upToDate(app("Telegram", "ru.keepcoder.Telegram", "13.1.0", appStore: true), .appStore),
            upToDate(app("WhatsApp", "net.whatsapp.WhatsApp", "26.41.74", appStore: true), .appStore),
            upToDate(app("Xcode", "com.apple.dt.Xcode", "27.1", appStore: true), .appStore),
            upToDate(app("Stremio", "com.westbridge.stremio5-mac", "5.1.30"), .homebrew, note: "The installed version is newer than Homebrew's 5.1.26"),
            AppCheckResult(app: app("LogiPluginService", "com.logi.pluginservice", "6.4.2.3414", folder: "/Applications/Utilities"),
                           status: .needsConfirmation(CaskMatch(token: "logi-options+", confidence: .low, evidence: [.bundleIDHint])),
                           decidedBy: .homebrew),
            AppCheckResult(app: app("Final Cut Pro", "com.apple.FinalCut", "12.3"), status: .cantCheck(reason: "Updated by Apple through Software Update")),
        ]
        return results
    }
}
#endif
