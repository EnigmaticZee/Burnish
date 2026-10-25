import Foundation
import Inventory
import Store
import Testing
import UpdateSources
import Versions
@testable import BurnishCore

@Suite struct AutoUpdatePolicyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86400

    func result(major: Bool = false, critical: Bool = false, released: Date? = nil, appStore: Bool = false) -> AppCheckResult {
        let app = makeApp("Tool", "com.example.tool", "1.0", build: "100", appStore: appStore)
        let release = Release(source: .sparkle, version: VersionPair(short: major ? "2.0" : "1.1", build: "110"), basis: .bundleVersion,
                              downloadURL: URL(string: "https://example.com/t.zip"), date: released, isCritical: critical)
        return outdated(app, release: release, major: major)
    }

    func settings(on: Bool = true, wait: AutoUpdateWait = .threeDays) -> Settings {
        var s = Settings()
        s.autoUpdate = on
        s.autoUpdateWait = wait
        return s
    }

    @Test func waitsUntilTheUpdateHasBeenOutLongEnough() {
        let r = result(released: now.addingTimeInterval(-1 * day))
        #expect(AutoUpdatePolicy.decide(r, settings: settings(), rule: AppRule(), firstSeen: nil, isRunning: false, now: now)
                == .wait(until: now.addingTimeInterval(2 * day)))
        let old = result(released: now.addingTimeInterval(-4 * day))
        #expect(AutoUpdatePolicy.decide(old, settings: settings(), rule: AppRule(), firstSeen: nil, isRunning: false, now: now) == .install)
    }

    @Test func countsFromFirstSeenWhenTheSourceGivesNoDate() {
        let r = result()
        #expect(AutoUpdatePolicy.decide(r, settings: settings(), rule: AppRule(), firstSeen: now.addingTimeInterval(-5 * day),
                                        isRunning: false, now: now) == .install)
        if case .wait = AutoUpdatePolicy.decide(r, settings: settings(), rule: AppRule(), firstSeen: nil, isRunning: false, now: now) {} else {
            Issue.record("never seen before: the wait starts now")
        }
    }

    @Test func securityUpdatesSkipTheWait() {
        let r = result(critical: true, released: now)
        #expect(AutoUpdatePolicy.decide(r, settings: settings(), rule: AppRule(), firstSeen: nil, isRunning: false, now: now) == .install)
    }

    @Test func neverMajorNeverOpenNeverWhenOff() {
        let past = now.addingTimeInterval(-30 * day)
        let decide = { (r: AppCheckResult, s: Settings, rule: AppRule, running: Bool) in
            AutoUpdatePolicy.decide(r, settings: s, rule: rule, firstSeen: nil, isRunning: running, now: self.now)
        }
        if case .skip = decide(result(major: true, released: past), settings(), AppRule(), false) {} else { Issue.record("major") }
        if case .skip = decide(result(released: past), settings(), AppRule(), true) {} else { Issue.record("open app") }
        if case .skip = decide(result(released: past), settings(on: false), AppRule(), false) {} else { Issue.record("setting off") }
        if case .skip = decide(result(released: past, appStore: true), settings(), AppRule(), false) {} else { Issue.record("App Store") }
    }

    @Test func perAppRulesWin() {
        let past = now.addingTimeInterval(-30 * day)
        #expect(AutoUpdatePolicy.decide(result(released: past), settings: settings(on: false), rule: AppRule(updates: .automatic),
                                        firstSeen: nil, isRunning: false, now: now) == .install, "automatic for this app even when off")
        if case .skip = AutoUpdatePolicy.decide(result(released: past), settings: settings(on: true), rule: AppRule(updates: .notifyOnly),
                                                firstSeen: nil, isRunning: false, now: now) {} else { Issue.record("notify only") }
    }

    @Test func firstSeenComesFromTheHistory() {
        var history = UpdateHistory()
        history.noteFound(version: "1.1", source: "sparkle", for: "com.example.tool", at: now.addingTimeInterval(-2 * day))
        history.noteFound(version: "1.1", source: "sparkle", for: "com.example.tool", at: now)
        #expect(history.firstSeen(version: "1.1", for: "com.example.tool") == now.addingTimeInterval(-2 * day))
    }
}
