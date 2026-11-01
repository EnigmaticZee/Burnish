import Foundation
import Store

/// Everything a bug report needs in one plain-text file, so a report can be acted on without a
/// reply: versions, settings, the last check, each app's history and Burnish's own recent log
/// lines. It names the apps on the Mac, which is why the person saves it and chooses where it goes;
/// Burnish never sends it anywhere.
public enum Diagnostics {
    public static func report(engine: BurnishEngine, appVersion: String, build: String) async -> String {
        var out: [String] = []
        let os = ProcessInfo.processInfo.operatingSystemVersion
        out.append("Burnish \(appVersion) (\(build))")
        out.append("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(InstallerEnvironmentChip.description)")
        out.append("Saved \(ISO8601DateFormatter().string(from: Date()))")
        out.append("")

        let managed = ManagedSettings.apply(to: await engine.store.load(.settings, default: Settings()))
        out.append("== Settings")
        out.append(json(managed.settings))
        if !managed.locked.isEmpty { out.append("Set by the organisation: \(managed.locked.map(\.rawValue).sorted().joined(separator: ", "))") }
        out.append("")

        let rules = await engine.store.load(.appRules, default: AppRules())
        let ignores = await engine.store.load(.ignoreRules, default: IgnoreRules())
        let feeds = await engine.store.load(.userFeeds, default: UserFeeds())
        out.append("== Rules, ignores and feeds you added")
        out.append(json(rules))
        out.append(json(ignores))
        out.append(json(feeds))
        out.append("")

        out.append("== Last check")
        if let report = await engine.lastReport() {
            out.append("Finished \(ISO8601DateFormatter().string(from: report.finishedAt)) · offline: \(report.isOffline)"
                + (report.caskDataDate.map { " · Homebrew data from \(ISO8601DateFormatter().string(from: $0))" } ?? ""))
            if !report.problems.isEmpty { out.append("Problems: \(report.problems.joined(separator: "; "))") }
            for r in report.results {
                let latest = r.status.candidate?.displayVersion ?? "-"
                let source = (r.status.candidate?.source ?? r.decidedBy)?.rawValue ?? "-"
                let match = r.match.map { " · \($0.token) (\($0.confidence))" } ?? ""
                out.append("\(r.app.name) · \(r.app.bundleID) · \(r.app.version.display) → \(latest) · \(source)\(match) · \(r.status.summary)")
                for note in r.notes { out.append("    \(note)") }
            }
        } else {
            out.append("No check yet")
        }
        out.append("")

        out.append("== History")
        let history = await engine.history()
        for (bundleID, events) in history.events.sorted(by: { $0.key < $1.key }) {
            out.append(bundleID)
            for event in events.suffix(20) { out.append("    \(json(event, pretty: false))") }
        }
        out.append("")

        out.append("== Log (Burnish only, last two days)")
        out.append(await logLines())
        return out.joined(separator: "\n") + "\n"
    }

    static func json<T: Encodable>(_ value: T, pretty: Bool = true) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Burnish's own entries from the unified log. `log show` can take a while on a busy Mac, so
    /// it gets twenty seconds and is then left behind.
    static func logLines(limit: Int = 400) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--style", "compact", "--last", "2d", "--predicate", "subsystem == \"io.github.enigmaticzee.Burnish\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "log show couldn't run: \(error.localizedDescription)" }
        let reader = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if process.isRunning { process.terminate() }
        }
        let data = await reader.value
        watchdog.cancel()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(limit).joined(separator: "\n")
    }
}

/// Which chip this Mac has, in words.
enum InstallerEnvironmentChip {
    static var description: String {
        #if arch(arm64)
        "Apple silicon"
        #else
        "Intel"
        #endif
    }
}

extension CheckStatus {
    /// One line for reports: the tab plus the reason or the version.
    var summary: String {
        switch self {
        case .outdated(let c): "update \(c.displayVersion)" + (c.isMajorUpgrade ? " (major)" : "")
        case .upToDate(let note): "up to date" + (note.map { " (\($0))" } ?? "")
        case .needsConfirmation(let match): "needs confirmation (\(match.token))"
        case .cantCheck(let reason): "can't check: \(reason)"
        case .ignored(.app, _): "ignored"
        case .ignored(.version(let v), _): "ignoring \(v)"
        }
    }
}
