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
