import Foundation
import Store
import UpdateSources

/// Whether Burnish installs an update on its own, and if not yet, when. Plain rules, so it's
/// easy to say why: never a major (possibly paid) upgrade, never an app that's open, never
/// anything Burnish can't install with every check, and only once the update has been out for
/// the chosen wait, unless the developer marked it as a security update.
public enum AutoUpdatePolicy {
    public enum Decision: Sendable, Equatable {
        case install
        case wait(until: Date)
        case skip(String)
    }

    public static func decide(
        _ result: AppCheckResult, settings: Settings, rule: AppRule, firstSeen: Date?, isRunning: Bool, now: Date = Date()
    ) -> Decision {
        guard case let .outdated(candidate) = result.status else { return .skip(String(localized: "No update")) }
        switch rule.updates {
        case .notifyOnly: return .skip(String(localized: "Set to tell you only"))
        case .followSettings where !settings.autoUpdate: return .skip(String(localized: "Automatic updates are off"))
        default: break
        }
        guard result.action(homebrew: settings.homebrewHandling) == .install else {
            return .skip(String(localized: "Burnish doesn't install this one itself"))
        }
        if candidate.isMajorUpgrade { return .skip(String(localized: "Major upgrades may be paid, so they wait for you")) }
        if isRunning { return .skip(String(localized: "The app is open")) }
        if candidate.release.isCritical { return .install }

        let wait = TimeInterval(settings.autoUpdateWait.days) * 24 * 3600
        guard wait > 0 else { return .install }
        // Out since the release date, or since Burnish first saw it when the source gives no date.
        let since = [candidate.release.date, firstSeen].compactMap { $0 }.min() ?? now
        let until = since.addingTimeInterval(wait)
        return now >= until ? .install : .wait(until: until)
    }
}
