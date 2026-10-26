import Foundation
import Inventory
import Store
import Testing
import UpdateSources
import Versions
@testable import BurnishCore

@Suite struct HallmarkTests {
    func app(edKey: String? = nil, signed: Bool = true, appStore: Bool = false) -> InstalledApp {
        InstalledApp(bundleID: "com.example.tool", name: "Tool", url: URL(fileURLWithPath: "/Applications/Tool.app"),
                     version: VersionPair(short: "1.0", build: "100"),
                     signature: signed ? CodeSignature(kind: appStore ? .appStore : .developerID, teamID: "ABCDE12345",
                                                       authority: "Developer ID Application: Example Ltd (ABCDE12345)") : CodeSignature(kind: .adHoc),
                     isAppStore: appStore, sparklePublicEDKey: edKey)
    }

    func states(_ marks: [Hallmark]) -> [Hallmark.Kind: Hallmark.State] {
        Dictionary(uniqueKeysWithValues: marks.map { ($0.kind, $0.state) })
    }

    @Test func aSignedSparkleUpdateListsEveryCheck() {
        let release = Release(source: .sparkle, version: VersionPair(short: "1.1", build: "110"), basis: .bundleVersion,
                              downloadURL: URL(string: "https://updates.example.com/Tool.zip"), edSignature: "sig")
        let marks = outdated(app(edKey: "key"), release: release).hallmarks(homebrew: .showOnly)
        let s = states(marks)
        #expect(s[.source] == .confirmed)
        #expect(marks.first?.detail.contains("updates.example.com") == true)
        #expect(s[.signature] == .checkedAtInstall)
        #expect(s[.checksum] == .notAvailable, "Sparkle feeds rarely publish a checksum, and Burnish says so")
        #expect(s[.sameDeveloper] == .checkedAtInstall)
        #expect(s[.gatekeeper] == .checkedAtInstall)
        #expect(s[.wayBack] == .confirmed)
        #expect(marks.first { $0.kind == .sameDeveloper }?.detail.contains("Example Ltd") == true)
    }

    @Test func anUnsignedUpdateForAnAppThatPinsAKeyIsACaution() {
        let release = Release(source: .sparkle, version: VersionPair(short: "1.1", build: "110"), basis: .bundleVersion,
                              downloadURL: URL(string: "https://updates.example.com/Tool.zip"))
        #expect(states(outdated(app(edKey: "key"), release: release).hallmarks(homebrew: .showOnly))[.signature] == .caution)
    }

    @Test func homebrewWithAChecksumAndAMajorUpgrade() {
        let release = Release(source: .homebrew, version: VersionPair(short: "2.0"), basis: .shortVersion,
                              downloadURL: URL(string: "https://dl.example.com/Tool-2.0.dmg"), sha256: "abc", caskToken: "tool")
        let s = states(outdated(app(), release: release, major: true).hallmarks(homebrew: .showOnly))
        #expect(s[.checksum] == .checkedAtInstall)
        #expect(s[.signature] == .notAvailable)
        #expect(s[.version] == .caution, "a possibly paid upgrade is flagged")
    }

    @Test func handOffsSayWhoChecks() {
        let store = Release(source: .appStore, version: VersionPair(short: "1.1"), basis: .shortVersion)
        let s = states(outdated(app(appStore: true), release: store).hallmarks(homebrew: .showOnly))
        #expect(s[.installedBy] == .handedOff)
        #expect(s[.signature] == nil && s[.wayBack] == nil, "no install checks claimed for someone else's install")
    }

    @Test func theFullListGroupsByStateInInstallOrder() {
        let release = Release(source: .homebrew, version: VersionPair(short: "2.0"), basis: .shortVersion,
                              downloadURL: URL(string: "https://dl.example.com/Tool-2.0.dmg"), caskToken: "tool")
        let marks = outdated(app(), release: release, major: true).hallmarks(homebrew: .showOnly).inOrder
        #expect(marks.map(\.kind) == [.version, .source, .sameDeveloper, .gatekeeper, .signature, .checksum, .wayBack],
                "worth knowing, confirmed, checked during the install, not offered, then the way back")
        #expect(marks.map(\.group) == marks.map(\.group).sorted())
    }

    @Test func theFoldedListLeadsWithWhatMatters() {
        let signed = Release(source: .sparkle, version: VersionPair(short: "1.1", build: "110"), basis: .bundleVersion,
                             downloadURL: URL(string: "https://updates.example.com/Tool.zip"), edSignature: "sig")
        #expect(outdated(app(edKey: "key"), release: signed).hallmarks(homebrew: .showOnly).leading().map(\.kind)
                == [.source, .signature, .sameDeveloper])

        let major = Release(source: .homebrew, version: VersionPair(short: "2.0"), basis: .shortVersion,
                            downloadURL: URL(string: "https://dl.example.com/Tool-2.0.dmg"), caskToken: "tool")
        let leading = outdated(app(), release: major, major: true).hallmarks(homebrew: .showOnly).leading()
        #expect(leading.first?.state == .caution, "anything worth knowing is never folded away")
        #expect(!leading.contains { $0.state == .notAvailable })
        #expect(leading.count == 3)
    }

    @Test func theHistoryRecordsOnlyTheChecksThatRan() {
        let release = Release(source: .homebrew, version: VersionPair(short: "1.1"), basis: .shortVersion,
                              downloadURL: URL(string: "https://dl.example.com/Tool.dmg"), sha256: "abc")
        #expect(outdated(app(), release: release).installChecks(release) == [.source, .checksum, .sameDeveloper, .gatekeeper])
    }
}
