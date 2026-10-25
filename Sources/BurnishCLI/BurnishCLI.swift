import BurnishCore
import Installer
import Foundation
import Inventory
import Store
import UpdateSources

// burnish inventory            Every app found, with bundle ID, versions, Team ID and source hints (M1)
// burnish check [--csv|--json] Detection report: app, installed, latest, source, confidence (M2, F20)


func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? String(s.prefix(width - 1)) + "…" : s + String(repeating: " ", count: width - s.count)
}

func csv(_ fields: [String]) -> String {
    fields.map { f in
        f.contains(",") || f.contains("\"") || f.contains("\n") ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
    }.joined(separator: ",")
}

func hints(_ app: InstalledApp) -> String {
    var h: [String] = []
    if app.isAppStore { h.append(app.isWrappedIOSApp ? "app-store(ios)" : "app-store") }
    if app.sparkleFeedURL != nil { h.append("sparkle") } else if app.sparklePublicEDKey != nil { h.append("sparkle(runtime feed)") }
    if app.electronUpdateConfig != nil { h.append("electron") }
    if let token = app.caskroomToken { h.append("caskroom:\(token)") }
    return h.joined(separator: " ")
}

struct Row {
    let name, bundleID, installed, latest, source, confidence, status, detail: String
}

func row(_ r: AppCheckResult) -> Row {
    let latest = r.status.candidate?.displayVersion ?? ""
    let confidence = r.match.map { "\($0.confidence) (\($0.token))" } ?? ""
    let status: String
    var detail = ""
    switch r.status {
    case .upToDate(let note): status = "up to date"; detail = note ?? ""
    case .outdated(let c): status = c.isMajorUpgrade ? "update (major, may be paid)" : "update"
    case .needsConfirmation(let m): status = "needs confirmation"; detail = m.channelUnsure ? "channel unsure: \(([m.token] + m.alternatives).prefix(3).joined(separator: ", "))" : "suggested \(m.token)"
    case .cantCheck(let reason): status = "can't check"; detail = reason
    case .ignored(let kind, _): status = "ignored"; detail = "\(kind)"
    }
    if !r.notes.isEmpty { detail += (detail.isEmpty ? "" : "; ") + r.notes.joined(separator: "; ") }
    return Row(
        name: r.app.name, bundleID: r.app.bundleID, installed: r.app.version.display, latest: latest,
        source: r.decidedBy?.rawValue ?? "", confidence: confidence, status: status, detail: detail
    )
}

@main
struct BurnishCLI {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "help"
        let flags = Set(arguments.dropFirst())
        let engine = BurnishEngine()

        switch command {
        case "inventory":
            let settings = await engine.store.load(.settings, default: Settings())
            let start = Date()
            let result = engine.scan(settings: settings)
            print(pad("App", 28) + pad("Bundle ID", 38) + pad("Version", 16) + pad("Build", 16) + pad("Team ID", 12) + "Hints")
            for app in result.apps {
                print(pad(app.name, 28) + pad(app.bundleID, 38) + pad(app.version.short ?? "-", 16) + pad(app.version.build ?? "-", 16)
                      + pad(app.teamID ?? app.signature.kind.rawValue, 12) + hints(app))
            }
            print("\n\(result.apps.count) apps in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")

        case "check":
            let start = Date()
            let report = await engine.runCheck()
            let rows = report.results.map(row)
            if flags.contains("--json") {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                FileHandle.standardOutput.write(try encoder.encode(report))
                print()
            } else if flags.contains("--csv") {
                print(csv(["app", "bundle_id", "installed", "latest", "source", "confidence", "status", "detail"]))
                for r in rows { print(csv([r.name, r.bundleID, r.installed, r.latest, r.source, r.confidence, r.status, r.detail])) }
            } else {
                print(pad("App", 26) + pad("Installed", 16) + pad("Latest", 16) + pad("Source", 10) + pad("Status", 22) + "Match / detail")
                for r in rows {
                    print(pad(r.name, 26) + pad(r.installed, 16) + pad(r.latest, 16) + pad(r.source, 10) + pad(r.status, 22)
                          + [r.confidence, r.detail].filter { !$0.isEmpty }.joined(separator: " — "))
                }
            }
            let counts = Dictionary(grouping: report.results, by: \.status.tab).mapValues(\.count)
            let summary = StatusTab.allCases.map { "\($0.title): \(counts[$0] ?? 0)" }.joined(separator: " · ")
            let matched = report.results.filter { $0.decidedBy != nil }.count
            FileHandle.standardError.write(Data("""

            \(summary)
            Matched to a source: \(matched) of \(report.results.count) · \(String(format: "%.1f", Date().timeIntervalSince(start)))s\
            \(report.isOffline ? " · offline" : "")\
            \(report.problems.isEmpty ? "" : "\nProblems: " + report.problems.joined(separator: "; "))

            """.utf8))

        case "update":
            guard let query = arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) else {
                print("Usage: burnish update <app name or bundle ID>")
                return
            }
            let settings = await engine.store.load(.settings, default: Settings())
            let report = await engine.runCheck()
            guard let result = report.results.first(where: {
                $0.app.bundleID == query || $0.app.name.caseInsensitiveCompare(query) == .orderedSame
            }) else {
                print("No app called \(query) in the app folders.")
                return
            }
            guard let candidate = result.status.candidate, result.status.isOutdated else {
                print("\(result.app.name) \(result.app.version.display): \(row(result).status). \(row(result).detail)")
                return
            }
            let action = result.action(homebrew: settings.homebrewHandling)
            guard action == .install else {
                print("\(result.app.name) \(candidate.displayVersion) is available, but Burnish won't install it itself: \(action)")
                return
            }
            print("Updating \(result.app.name) \(result.app.version.display) → \(candidate.displayVersion) from \(candidate.source.label)")
            let printer = PhasePrinter()
            let outcome = await engine.install(result, progress: { printer.show($0) }, askToQuit: { name in
                print("\(name) didn't quit within 10 seconds (it may have unsaved work). Quit it yourself and run this again.")
                return .cancel
            })
            switch outcome {
            case .installed(let oldCopy, let relaunched):
                print("Done. The old version is in the Trash\(oldCopy.map { " (\($0.lastPathComponent))" } ?? "")\(relaunched ? "; \(result.app.name) was relaunched" : "").")
            case .openedInInstaller(let pkg):
                print("Verified the installer package and opened it in Installer: \(pkg.lastPathComponent)")
            case .refused(let refusal):
                print("Refused (\(refusal.rule.rawValue)): \(refusal.message)")
                if let page = refusal.downloadPage { print("Download page: \(page.absoluteString)") }
            case .cancelled:
                print("Cancelled. Nothing was changed.")
            }

        default:
            print("""
            Usage:
              burnish inventory              List every app with bundle ID, versions, Team ID and update hints
              burnish check                  Check every app for updates (table)
              burnish check --csv            Same, as CSV (the M2 detection report)
              burnish check --json           Same, as JSON
              burnish update <app>           Download, verify and install one app's update
            """)
        }
    }
}

/// Prints install progress, one line per phase (downloads every 10%).
final class PhasePrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ""

    func show(_ phase: InstallPhase) {
        var line = phase.label
        if let fraction = phase.fraction { line = "Downloading \(Int(fraction * 10) * 10)%" }
        lock.withLock {
            guard line != last else { return }
            last = line
            print("  \(line)")
        }
    }
}
