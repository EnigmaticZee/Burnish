import Foundation
import Testing
@testable import Inventory

struct FakeSignatures: SignatureReading {
    var byName: [String: CodeSignature] = [:]
    func signature(of bundle: URL) -> CodeSignature {
        byName[bundle.lastPathComponent] ?? CodeSignature(kind: .developerID, teamID: "TEAM123456")
    }
}

final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("burnish-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

@discardableResult
func makeApp(_ name: String, in dir: URL, plist: [String: Any], receipt: Bool = false, electron: Bool = false) throws -> URL {
    let app = dir.appendingPathComponent("\(name).app")
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    if receipt {
        let dir = contents.appendingPathComponent("_MASReceipt")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("receipt"))
    }
    if electron {
        let dir = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("provider: generic\nurl: https://example.com/updates\n".utf8).write(to: dir.appendingPathComponent("app-update.yml"))
    }
    return app
}

@Suite struct InventoryTests {
    @Test func readsInfoPlist() throws {
        let tmp = try TempDir()
        let url = try makeApp("Rectangle", in: tmp.url, plist: [
            "CFBundleIdentifier": "com.knollsoft.Rectangle",
            "CFBundleShortVersionString": "2.0.3",
            "CFBundleVersion": "203",
            "CFBundleName": "Rectangle",
            "SUFeedURL": "https://rectangleapp.com/downloads/updates.xml",
            "SUPublicEDKey": "abc123=",
            "LSMinimumSystemVersion": "14.0",
        ])
        let app = try #require(AppInventory(signatureReader: FakeSignatures(), caskrooms: []).readApp(at: url))
        #expect(app.bundleID == "com.knollsoft.Rectangle")
        #expect(app.name == "Rectangle")
        #expect(app.fileName == "Rectangle.app")
        #expect(app.shortVersion == "2.0.3")
        #expect(app.buildVersion == "203")
        #expect(app.sparkleFeedURL?.absoluteString == "https://rectangleapp.com/downloads/updates.xml")
        #expect(app.sparklePublicEDKey == "abc123=")
        #expect(app.minimumSystemVersion == "14.0")
        #expect(app.teamID == "TEAM123456")
        #expect(!app.isAppStore)
        #expect(app.electronUpdateConfig == nil)
    }

    @Test func detectsAppStoreReceiptAndElectron() throws {
        let tmp = try TempDir()
        let mas = try makeApp("Things", in: tmp.url, plist: ["CFBundleIdentifier": "com.culturedcode.ThingsMac", "CFBundleShortVersionString": "3.21"], receipt: true)
        let electron = try makeApp("Obsidian", in: tmp.url, plist: ["CFBundleIdentifier": "md.obsidian", "CFBundleShortVersionString": "1.9.1"], electron: true)
        let inventory = AppInventory(signatureReader: FakeSignatures(), caskrooms: [])
        #expect(try #require(inventory.readApp(at: mas)).isAppStore)
        #expect(try #require(inventory.readApp(at: electron)).electronUpdateConfig != nil)
    }

    @Test func skipsBundlesWithoutIDAndBlankValues() throws {
        let tmp = try TempDir()
        let noID = try makeApp("Broken", in: tmp.url, plist: ["CFBundleShortVersionString": "1.0"])
        let blank = try makeApp("Blank", in: tmp.url, plist: ["CFBundleIdentifier": "com.x.blank", "CFBundleShortVersionString": "  ", "SUFeedURL": ""])
        let inventory = AppInventory(signatureReader: FakeSignatures(), caskrooms: [])
        #expect(inventory.readApp(at: noID) == nil)
        let app = try #require(inventory.readApp(at: blank))
        #expect(app.version.short == nil)
        #expect(app.sparkleFeedURL == nil)
    }

    @Test func scansTwoLevelsDeepAndSkipsSystemAndDuplicates() throws {
        let tmp = try TempDir()
        let root = tmp.url.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeApp("Top", in: root, plist: ["CFBundleIdentifier": "com.x.top", "CFBundleShortVersionString": "1"])
        let folder = root.appendingPathComponent("Adobe Suite")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try makeApp("Nested", in: folder, plist: ["CFBundleIdentifier": "com.x.nested", "CFBundleShortVersionString": "1"])
        let deep = folder.appendingPathComponent("Deeper")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try makeApp("TooDeep", in: deep, plist: ["CFBundleIdentifier": "com.x.deep", "CFBundleShortVersionString": "1"])
        // An app's own helpers live inside the bundle and must not be listed.
        let topContents = root.appendingPathComponent("Top.app/Contents/Library")
        try FileManager.default.createDirectory(at: topContents, withIntermediateDirectories: true)
        try makeApp("Helper", in: topContents, plist: ["CFBundleIdentifier": "com.x.helper", "CFBundleShortVersionString": "1"])
        // Safari is a symlink into /System and updates with macOS.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Calculator.app"),
            withDestinationURL: URL(fileURLWithPath: "/System/Applications/Calculator.app")
        )
        // The same app reached twice.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Top Alias.app"), withDestinationURL: root.appendingPathComponent("Top.app"))

        let result = AppInventory(signatureReader: FakeSignatures(), caskrooms: []).scan(roots: [root])
        #expect(result.apps.map(\.bundleID).sorted() == ["com.x.nested", "com.x.top"])
    }

    @Test func listsTwoCopiesInDifferentFolders() throws {
        let tmp = try TempDir()
        let a = tmp.url.appendingPathComponent("A"), b = tmp.url.appendingPathComponent("B")
        for dir in [a, b] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try makeApp("Same", in: dir, plist: ["CFBundleIdentifier": "com.x.same", "CFBundleShortVersionString": dir == a ? "1.0" : "2.0"])
        }
        let apps = AppInventory(signatureReader: FakeSignatures(), caskrooms: []).scan(roots: [a, b]).apps
        #expect(apps.count == 2)
        #expect(Set(apps.map(\.shortVersion)) == ["1.0", "2.0"])
    }

    @Test func excludesBurnishItself() throws {
        let tmp = try TempDir()
        try makeApp("Burnish", in: tmp.url, plist: ["CFBundleIdentifier": "io.github.enigmaticzee.Burnish", "CFBundleShortVersionString": "1.0"])
        let apps = AppInventory(signatureReader: FakeSignatures(), caskrooms: [], excludedBundleIDs: ["io.github.enigmaticzee.Burnish"]).scan(roots: [tmp.url]).apps
        #expect(apps.isEmpty)
    }

    @Test func readsWrappedIOSApp() throws {
        let tmp = try TempDir()
        let outer = tmp.url.appendingPathComponent("Game.app")
        let inner = outer.appendingPathComponent("Wrapper/Game.app")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.x.game", "CFBundleShortVersionString": "4.2"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: inner.appendingPathComponent("Info.plist"))
        try FileManager.default.createSymbolicLink(atPath: outer.appendingPathComponent("WrappedBundle").path, withDestinationPath: "Wrapper/Game.app")
        let app = try #require(AppInventory(signatureReader: FakeSignatures(), caskrooms: []).readApp(at: outer))
        #expect(app.isAppStore)
        #expect(app.isWrappedIOSApp)
        #expect(app.shortVersion == "4.2")
    }

    @Test func caskroomReceiptMarksAppsAsManagedByHomebrew() throws {
        let tmp = try TempDir()
        let apps = tmp.url.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try makeApp("Visual Studio Code", in: apps, plist: ["CFBundleIdentifier": "com.microsoft.VSCode", "CFBundleShortVersionString": "1.143.0"])
        try makeApp("iTerm", in: apps, plist: ["CFBundleIdentifier": "com.googlecode.iterm2", "CFBundleShortVersionString": "3.7.5"])
        try makeApp("Hand Installed", in: apps, plist: ["CFBundleIdentifier": "com.x.hand", "CFBundleShortVersionString": "1"])

        let caskroom = tmp.url.appendingPathComponent("Caskroom")
        // Newer Homebrew: INSTALL_RECEIPT.json
        let vscodeMeta = caskroom.appendingPathComponent("visual-studio-code/.metadata")
        try FileManager.default.createDirectory(at: vscodeMeta, withIntermediateDirectories: true)
        let receipt: [String: Any] = ["uninstall_artifacts": [["app": ["Visual Studio Code.app"]], ["binary": ["code"]]]]
        try JSONSerialization.data(withJSONObject: receipt).write(to: vscodeMeta.appendingPathComponent("INSTALL_RECEIPT.json"))
        // Older Homebrew: the cask file saved under .metadata/<version>/<timestamp>/Casks
        let itermCasks = caskroom.appendingPathComponent("iterm2/.metadata/3.7.5/20260901120000.000/Casks")
        try FileManager.default.createDirectory(at: itermCasks, withIntermediateDirectories: true)
        try Data(#"cask "iterm2" do\n  version "3.7.5"\n  app "iTerm.app"\nend\n"#.replacingOccurrences(of: "\\n", with: "\n").utf8)
            .write(to: itermCasks.appendingPathComponent("iterm2.rb"))

        let result = AppInventory(signatureReader: FakeSignatures(), caskrooms: [caskroom]).scan(roots: [apps])
        let byID = Dictionary(uniqueKeysWithValues: result.apps.map { ($0.bundleID, $0) })
        #expect(byID["com.microsoft.VSCode"]?.caskroomToken == "visual-studio-code")
        #expect(byID["com.googlecode.iterm2"]?.caskroomToken == "iterm2")
        #expect(byID["com.x.hand"]?.caskroomToken == nil)
        #expect(result.caskroom.tokens == ["iterm2", "visual-studio-code"])
    }

    @Test func caskArtifactTargetsWin() {
        let artifacts: [[String: Any]] = [
            ["app": ["Foo.app"], "target": "/Applications/Foo.app"],
            ["app": ["Source.app", ["target": "Renamed.app"]]],
            ["binary": ["foo"], "target": "$HOMEBREW_PREFIX/bin/foo"],
        ]
        #expect(CaskroomScanner.apps(fromArtifacts: artifacts) == ["Foo.app", "Renamed.app"])
    }

    @Test func realSignatures() throws {
        // Apple's own app: signed by Apple, no Team ID.
        let calculator = SecuritySignatureReader().signature(of: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        #expect(calculator.kind == .apple)
        #expect(calculator.teamID == nil)
        #expect(!calculator.canBeAutoUpdated)

        // An ad-hoc signed bundle we make ourselves.
        let tmp = try TempDir()
        let app = try makeApp("AdHoc", in: tmp.url, plist: [
            "CFBundleIdentifier": "com.x.adhoc", "CFBundleShortVersionString": "1", "CFBundleExecutable": "AdHoc",
        ])
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/AdHoc").path)
        let unsigned = SecuritySignatureReader().signature(of: app)
        #expect(!unsigned.canBeAutoUpdated)
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", app.path]
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        let adhoc = SecuritySignatureReader().signature(of: app)
        #expect(adhoc.kind == .adHoc)
        #expect(adhoc.teamID == nil)
        #expect(!adhoc.canBeAutoUpdated)
        #expect(throws: Never.self) { try SignatureValidator.validate(app) }
    }

    @Test func authorityKinds() {
        #expect(SecuritySignatureReader.kind(for: "Developer ID Application: Google LLC (EQHXZ8M8AV)", teamID: "EQHXZ8M8AV") == .developerID)
        #expect(SecuritySignatureReader.kind(for: "Apple Mac OS Application Signing", teamID: "59GAB85EFG") == .appStore)
        #expect(SecuritySignatureReader.kind(for: "Apple Development: someone@example.com (ABCDE12345)", teamID: "ABCDE12345") == .development)
        #expect(SecuritySignatureReader.kind(for: "Software Signing", teamID: nil) == .apple)
        #expect(CodeSignature(kind: .developerID, teamID: "EQHXZ8M8AV").canBeAutoUpdated)
        #expect(!CodeSignature(kind: .appStore, teamID: "59GAB85EFG").canBeAutoUpdated)
    }
}
