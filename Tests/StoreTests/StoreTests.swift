import Foundation
import Testing
@testable import Store

@Suite struct StoreTests {
    func makeStore() -> StateStore {
        StateStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("burnish-store-\(UUID().uuidString)"))
    }

    @Test func roundTripsSettings() async {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(await store.load(.settings) == nil)
        var settings = Settings()
        settings.checkFrequency = .weekly
        settings.appStoreLookups = false
        await store.save(settings, .settings)
        #expect(await store.load(.settings) == settings)
    }

    @Test func oldFilesFillInDefaults() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(#"{"checkFrequency":"manual","futureKey":42}"#.utf8).write(to: store.url(for: StoreKey<Settings>.settings))
        let settings = try #require(await store.load(.settings))
        #expect(settings.checkFrequency == .manual)
        #expect(settings.notificationsEnabled)
        #expect(settings.homebrewHandling == .showOnly)
    }

    @Test func ignoreRulesPersist() async {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        await store.update(.ignoreRules, default: IgnoreRules()) {
            $0.apps.insert("com.x.app")
            $0.versions["com.y.app"] = "2.0"
        }
        let rules = await store.load(.ignoreRules, default: IgnoreRules())
        #expect(rules.ignoresApp("com.x.app"))
        #expect(rules.ignoresVersion("2.0", of: "com.y.app"))
        #expect(!rules.ignoresVersion("2.1", of: "com.y.app"))
    }

    @Test func corruptFileReadsAsMissing() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url(for: StoreKey<IgnoreRules>.ignoreRules))
        #expect(await store.load(.ignoreRules) == nil)
    }

    @Test func frequencies() {
        #expect(CheckFrequency.daily.interval == 86400)
        #expect(CheckFrequency.manual.interval == nil)
    }
}

@Suite struct UpdateHistoryRules {
    @Test func newestFirstAndCapped() {
        var history = UpdateHistory()
        for n in 0..<(UpdateHistory.limit + 5) {
            history.record(.refused(version: "\(n)", reason: "test"), for: "com.x.app", at: Date(timeIntervalSince1970: Double(n)))
        }
        let events = history.events(for: "com.x.app")
        #expect(events.count == UpdateHistory.limit)
        #expect(events.first?.kind == .refused(version: "\(UpdateHistory.limit + 4)", reason: "test"))
    }

    @Test func aFoundVersionIsNotedOnce() {
        var history = UpdateHistory()
        history.noteFound(version: "2.0", source: "sparkle", for: "com.x.app")
        history.noteFound(version: "2.0", source: "sparkle", for: "com.x.app")
        history.noteFound(version: "2.1", source: "sparkle", for: "com.x.app")
        #expect(history.events(for: "com.x.app").count == 2)
    }

    @Test func putBackOnlyOffersTheLatestUpdate() {
        var history = UpdateHistory()
        #expect(history.latestUpdate(for: "com.x.app") == nil)
        history.record(.updated(from: "1.0", to: "1.1", previousCopy: "/T/x 1.0.app"), for: "com.x.app")
        history.noteFound(version: "1.2", source: "homebrew", for: "com.x.app")
        guard case .updated(_, "1.1", _)? = history.latestUpdate(for: "com.x.app")?.kind else {
            Issue.record("expected the 1.1 update"); return
        }
        history.record(.restored(to: "1.0", from: "1.1", replacedCopy: "/T/x 1.1.app"), for: "com.x.app")
        #expect(history.latestUpdate(for: "com.x.app") == nil, "nothing to put back once it's been put back")
    }

    @Test func survivesARoundTrip() async {
        let store = StateStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("burnish-history-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        await store.update(.history, default: UpdateHistory()) {
            $0.record(.handedOff(version: "3.0", to: "homebrew"), for: "com.x.app")
        }
        let loaded = await store.load(.history, default: UpdateHistory())
        #expect(loaded.events(for: "com.x.app").first?.kind == .handedOff(version: "3.0", to: "homebrew"))
    }
}
