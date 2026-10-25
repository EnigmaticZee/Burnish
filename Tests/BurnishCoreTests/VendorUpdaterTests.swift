import Foundation
import Inventory
import Store
import Testing
import UpdateSources
import Versions
@testable import BurnishCore

@Suite struct VendorUpdaterTests {
    static let mau = "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app"
    static let creativeCloud = "/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app"

    func app(_ name: String, _ id: String, folder: String = "/Applications", appStore: Bool = false) -> InstalledApp {
        InstalledApp(bundleID: id, name: name, url: URL(fileURLWithPath: "\(folder)/\(name).app"), version: VersionPair(short: "1.0"),
                     signature: CodeSignature(kind: appStore ? .appStore : .developerID, teamID: "TEAM000001"), isAppStore: appStore)
    }

    @Test func findsTheRightUpdaterOnlyWhenItsInstalled() {
        let installed: Set<String> = [Self.mau, Self.creativeCloud, "/Applications/Setapp.app"]
        let exists = { installed.contains($0) }
        #expect(VendorUpdaters.updater(for: app("Microsoft Word", "com.microsoft.Word"), fileExists: exists)?.name == "Microsoft AutoUpdate")
        #expect(VendorUpdaters.updater(for: app("Adobe Photoshop 2026", "com.adobe.Photoshop"), fileExists: exists)?.shortName == "Creative Cloud")
        #expect(VendorUpdaters.updater(for: app("CleanShot X", "pl.maketheweb.cleanshotx-setapp", folder: "/Applications/Setapp"), fileExists: exists)?.name == "Setapp")
        #expect(VendorUpdaters.updater(for: app("IntelliJ IDEA", "com.jetbrains.intellij"), fileExists: exists) == nil, "Toolbox isn't installed")
        #expect(VendorUpdaters.updater(for: app("Microsoft Word", "com.microsoft.Word"), fileExists: { _ in false }) == nil)
    }

    @Test func leavesAppsWithTheirOwnUpdatersAlone() {
        let exists: (String) -> Bool = { _ in true }
        #expect(VendorUpdaters.updater(for: app("Visual Studio Code", "com.microsoft.VSCode"), fileExists: exists) == nil)
        #expect(VendorUpdaters.updater(for: app("Microsoft Edge", "com.microsoft.edgemac"), fileExists: exists) == nil)
        #expect(VendorUpdaters.updater(for: app("Adobe Acrobat Reader", "com.adobe.Reader"), fileExists: exists) == nil)
        #expect(VendorUpdaters.updater(for: app("Microsoft Word", "com.microsoft.Word", appStore: true), fileExists: exists) == nil,
                "App Store copies update in the App Store")
    }

    @Test func updateOpensTheVendorsUpdaterNotADownload() {
        let updater = VendorUpdater(name: "Microsoft AutoUpdate", shortName: "AutoUpdate", path: Self.mau)
        let release = Release(source: .homebrew, version: VersionPair(short: "16.103"), basis: .shortVersion,
                              downloadURL: URL(string: "https://example.com/Word.pkg"), installsPkg: true)
        var result = outdated(app("Microsoft Word", "com.microsoft.Word"), release: release)
        result.vendorUpdater = updater
        #expect(result.action(homebrew: .showOnly) == .openUpdater(updater))
        #expect(!result.includedInUpdateAll(homebrew: .showOnly), "handed over, not installed by Update All")

        var managed = result
        managed.app.caskroomToken = "microsoft-word"
        #expect(managed.action(homebrew: .showOnly) == .managedByHomebrew(token: "microsoft-word"), "Homebrew installs stay with Homebrew")
    }

    @Test func canNotCheckSaysWhoUpdatesTheApp() {
        var findings = SourceFindings()
        findings.vendorUpdater = VendorUpdater(name: "Adobe Creative Cloud", shortName: "Creative Cloud", path: Self.creativeCloud)
        let result = StatusDecider.decide(app("Adobe Photoshop 2026", "com.adobe.Photoshop"), findings: findings,
                                          options: DecisionOptions(), system: SystemVersion("27.0"))
        #expect(result.status == .cantCheck(reason: "Updates come through Adobe Creative Cloud"))
        #expect(result.vendorUpdater?.shortName == "Creative Cloud")
    }
}
