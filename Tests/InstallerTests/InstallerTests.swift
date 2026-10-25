import CryptoKit
import Foundation
import Inventory
import Net
import NetTesting
import Testing
import UpdateSources
import Versions
@testable import Installer

// MARK: Stand-ins. Nothing here touches /Applications, the real Trash or running apps.

/// Reads a pretend Team ID from `Contents/Resources/fake-team` inside the bundle.
struct FakeSignatures: SignatureReading {
    func signature(of bundle: URL) -> CodeSignature {
        let marker = bundle.appendingPathComponent("Contents/Resources/fake-team")
        guard let team = try? String(contentsOf: marker, encoding: .utf8), team != "UNSIGNED" else { return .unsigned }
        return CodeSignature(kind: .developerID, teamID: team)
    }
}

/// Plays the code requirement check: valid only when the marker names the expected team.
struct FakeValidator: SignatureValidating {
    func validate(_ app: URL, teamID: String) throws {
        let marker = app.appendingPathComponent("Contents/Resources/fake-team")
        guard let team = try? String(contentsOf: marker, encoding: .utf8), team != "UNSIGNED" else {
            throw SignatureValidator.Failure.unsigned
        }
        if team == "BROKEN" { throw SignatureValidator.Failure.invalid("a sealed resource is missing or invalid") }
        if team != teamID { throw SignatureValidator.Failure.invalid("not signed by the same developer") }
    }
}

/// Real Security-framework reads for downloaded copies, the fake marker for the installed one
/// (a test can't sign with a real Team ID).
struct SplitSignatures: SignatureReading {
    let installedFolder: URL
    func signature(of bundle: URL) -> CodeSignature {
        bundle.path.hasPrefix(installedFolder.path + "/") ? FakeSignatures().signature(of: bundle) : SecuritySignatureReader().signature(of: bundle)
    }
}

final class FakeGatekeeper: GatekeeperAssessing, @unchecked Sendable {
    var accept = true
    func assess(_ app: URL) async -> Bool { accept }
}

final class FakePackageSignatures: PackageSignatureReading, @unchecked Sendable {
    var team: String?
    func teamID(ofPackage url: URL) async -> String? { team }
}

final class FakeApps: RunningAppControlling, @unchecked Sendable {
    let lock = NSLock()
    var runningPIDs: Set<pid_t> = []
    var quitsWhenAsked = true
    var quitRequests = 0
    var relaunched: [URL] = []

    func running(_ app: URL) async -> [pid_t] { lock.withLock { Array(runningPIDs) } }
    func requestQuit(_ pid: pid_t) async {
        lock.withLock {
            quitRequests += 1
            if quitsWhenAsked { runningPIDs.remove(pid) }
        }
    }
    func isRunning(_ pid: pid_t) async -> Bool { lock.withLock { runningPIDs.contains(pid) } }
    func relaunch(_ app: URL) async { lock.withLock { relaunched.append(app) } }
}

/// A folder that plays the Trash.
struct FolderTrash: Trashing {
    let folder: URL
    var fail: Error?
    func trash(_ url: URL) throws -> URL? {
        if let fail { throw fail }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Like the real Trash, a name that's taken gets a number.
        var target = folder.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)")
            n += 1
        }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
}

final class FakeFiles: FileOperating, @unchecked Sendable {
    var writable = true
    var unwritable: Set<String> = []
    var failMovesInto: URL?
    var privilegedCalls = 0
    var lastRequirement: String?
    func isWritable(_ directory: URL) -> Bool { writable && !unwritable.contains(directory.path) }
    func move(_ source: URL, to destination: URL) throws {
        if destination == failMovesInto { failMovesInto = nil; throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.moveItem(at: source, to: destination)
    }
    func privilegedReplace(old: URL, new: URL, trashTarget: URL, requirement: String, appName: String) async throws {
        privilegedCalls += 1
        lastRequirement = requirement
        try FileManager.default.createDirectory(at: trashTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: old, to: trashTarget)
        try FileManager.default.moveItem(at: new, to: old)
    }
}

final class FakeOpener: PackageOpening, @unchecked Sendable {
    var opened: [URL] = []
    func open(_ package: URL) async { opened.append(package) }
}

// MARK: Fixture apps

let teamA = "AAAAAAAAAA"
let teamB = "BBBBBBBBBB"
let bundleID = "com.example.fixture"

@discardableResult
func makeBundle(in dir: URL, name: String = "Fixture", id: String = bundleID, short: String, build: String,
                team: String? = teamA, edKey: String? = nil, minimumOS: String? = nil) throws -> URL {
    let app = dir.appendingPathComponent("\(name).app")
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
    var plist: [String: Any] = [
        "CFBundleIdentifier": id, "CFBundleShortVersionString": short, "CFBundleVersion": build,
        "CFBundleExecutable": name, "CFBundlePackageType": "APPL",
    ]
    if let edKey { plist["SUPublicEDKey"] = edKey }
    if let minimumOS { plist["LSMinimumSystemVersion"] = minimumOS }
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: contents.appendingPathComponent("MacOS/\(name)").path)
    if let team { try team.write(to: contents.appendingPathComponent("Resources/fake-team"), atomically: true, encoding: .utf8) }
    return app
}

func zip(_ app: URL, to zipURL: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = ["-c", "-k", "--keepParent", app.path, zipURL.path]
    try p.run()
    p.waitUntilExit()
}

func dmg(of folder: URL, to dmgURL: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    p.arguments = ["create", "-quiet", "-ov", "-fs", "HFS+", "-format", "UDZO", "-volname", "Fixture", "-srcfolder", folder.path, dmgURL.path]
    try p.run()
    p.waitUntilExit()
}

func codesignAdHoc(_ app: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    p.arguments = ["--force", "--sign", "-", app.path]
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
}

/// One install scenario in its own temporary folder.
final class Harness {
    let root: URL
    let applications: URL
    let trashFolder: URL
    let build: URL
    let client = MockHTTPClient()
    let apps = FakeApps()
    let files = FakeFiles()
    let gatekeeper = FakeGatekeeper()
    let packages = FakePackageSignatures()
    let opener = FakeOpener()
    var trashFailure: Error?
    var signatures: SignatureReading = FakeSignatures()
    var validator: SignatureValidating = FakeValidator()
    let key = Curve25519.Signing.PrivateKey()
    let downloadURL = "https://example.com/Fixture-1.1.zip"
    let page = URL(string: "https://example.com/download")!

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("burnish-install-\(UUID().uuidString)")
        applications = root.appendingPathComponent("Applications")
        trashFolder = root.appendingPathComponent("Trash")
        build = root.appendingPathComponent("build")
        for dir in [applications, build] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    /// The installed copy: version 1.0 (100), signed by team A, pinning the EdDSA key.
    func installed(team: String? = teamA, edKey: Bool = true, signature: CodeSignature? = nil, appStore: Bool = false, caskroom: String? = nil) throws -> InstalledApp {
        let url = try makeBundle(in: applications, short: "1.0", build: "100", team: team, edKey: edKey ? publicKey : nil)
        let base = AppInventory(signatureReader: signatures, caskrooms: []).readApp(at: url)!
        return InstalledApp(
            bundleID: base.bundleID, name: base.name, url: url, version: base.version,
            signature: signature ?? (team.map { CodeSignature(kind: .developerID, teamID: $0) } ?? .unsigned),
            isAppStore: appStore, sparklePublicEDKey: base.sparklePublicEDKey, caskroomToken: caskroom
        )
    }

    /// Builds the new version, zips it and serves it. Returns the archive bytes.
    @discardableResult
    func serveZip(id: String = bundleID, short: String = "1.1", build buildNumber: String = "110", team: String? = teamA,
                  minimumOS: String? = nil, prepare: (URL) throws -> Void = { _ in }) throws -> Data {
        let folder = build.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = try makeBundle(in: folder, id: id, short: short, build: buildNumber, team: team, minimumOS: minimumOS)
        try prepare(app)
        let archive = folder.appendingPathComponent("Fixture.zip")
        try zip(app, to: archive)
        let data = try Data(contentsOf: archive)
        client.serveDownload(downloadURL, data: data)
        return data
    }

    func sparkleRelease(signing data: Data?, with signer: Curve25519.Signing.PrivateKey? = nil, url: String? = nil) throws -> Release {
        let signature = try data.map { try (signer ?? key).signature(for: $0).base64EncodedString() }
        return Release(
            source: .sparkle, version: VersionPair(short: "1.1", build: "110"), basis: .bundleVersion,
            downloadURL: URL(string: url ?? downloadURL), downloadPage: page, edSignature: signature
        )
    }

    func caskRelease(sha256: String?, url: String? = nil) -> Release {
        Release(source: .homebrew, version: VersionPair(short: "1.1"), basis: .shortVersion,
                downloadURL: URL(string: url ?? downloadURL), downloadPage: page, sha256: sha256, caskToken: "fixture")
    }

    func installer() -> AppInstaller {
        var env = InstallerEnvironment(
            client: client, workDirectory: root.appendingPathComponent("work"), signatures: signatures,
            validator: validator, gatekeeper: gatekeeper, packageSignatures: packages, apps: apps,
            trash: FolderTrash(folder: trashFolder, fail: trashFailure), files: files, packageOpener: opener,
            system: SystemVersion("27.0")
        )
        env.quitTimeout = 0.3
        env.pollInterval = 0.05
        env.userTrash = trashFolder
        return AppInstaller(environment: env)
    }

    func install(_ app: InstalledApp, _ release: Release, askToQuit: @escaping @Sendable (String) async -> QuitDecision = { _ in .cancel }) async -> InstallOutcome {
        await installer().install(InstallRequest(app: app, release: release), askToQuit: askToQuit)
    }

    func installedVersion() -> String? {
        let plist = applications.appendingPathComponent("Fixture.app/Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    var trashIsEmpty: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: trashFolder.path)) ?? []).isEmpty
    }

    /// A refused install always leaves the old app untouched and offers the download page.
    func expectRefused(_ outcome: InstallOutcome, _ rule: InstallRefusal.Rule, sourceLocation: SourceLocation = #_sourceLocation) {
        guard case let .refused(refusal) = outcome else {
            Issue.record("expected refusal (\(rule)), got \(outcome)", sourceLocation: sourceLocation)
            return
        }
        #expect(refusal.rule == rule, "rule", sourceLocation: sourceLocation)
        #expect(refusal.downloadPage == page, "download page offered", sourceLocation: sourceLocation)
        #expect(installedVersion() == "1.0", "old app untouched", sourceLocation: sourceLocation)
        #expect(trashIsEmpty, "nothing moved to the Trash", sourceLocation: sourceLocation)
        #expect(opener.opened.isEmpty, "no installer opened", sourceLocation: sourceLocation)
    }
}

// MARK: The happy path

@Suite struct InstallSucceeds {
    @Test func sparkleZipReplacesAndKeepsOldInTrash() async throws {
        let h = try Harness()
        let app = try h.installed()
        let data = try h.serveZip()
        let outcome = await h.install(app, try h.sparkleRelease(signing: data))
        guard case let .installed(oldCopy, relaunched) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(h.installedVersion() == "1.1")
        #expect(!relaunched)
        let trashed = try #require(oldCopy)
        #expect(trashed.deletingLastPathComponent().path == h.trashFolder.path, "old version is in the Trash")
        let oldPlist = try PropertyListSerialization.propertyList(from: Data(contentsOf: trashed.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        #expect(oldPlist?["CFBundleShortVersionString"] as? String == "1.0")
        #expect(!FileManager.default.fileExists(atPath: h.root.appendingPathComponent("work").appendingPathComponent("download").path))
    }

    @Test func caskZipWithMatchingChecksum() async throws {
        let h = try Harness()
        let app = try h.installed(edKey: false)
        let data = try h.serveZip()
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let outcome = await h.install(app, h.caskRelease(sha256: sha))
        guard case .installed = outcome else { Issue.record("got \(outcome)"); return }
        #expect(h.installedVersion() == "1.1")
    }

    @Test func quitsPolitelyAndRelaunchesOnlyIfRunning() async throws {
        let h = try Harness()
        let app = try h.installed()
        let data = try h.serveZip()
        h.apps.runningPIDs = [4242]
        let outcome = await h.install(app, try h.sparkleRelease(signing: data))
        guard case .installed(_, let relaunched) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(relaunched)
        #expect(h.apps.quitRequests == 1)
        #expect(h.apps.relaunched == [app.url])
    }

    @Test func diskImage() async throws {
        let h = try Harness()
        let app = try h.installed(edKey: false)
        let folder = h.build.appendingPathComponent("dmg-src")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try makeBundle(in: folder, short: "1.1", build: "110")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Applications"), withDestinationURL: URL(fileURLWithPath: "/Applications"))
        let image = h.build.appendingPathComponent("Fixture.dmg")
        try dmg(of: folder, to: image)
        h.client.serveDownload(h.downloadURL, data: try Data(contentsOf: image))
        #expect(ArchiveKind.detect(image) == .dmg)

        let outcome = await h.install(app, h.caskRelease(sha256: nil))
        guard case .installed = outcome else { Issue.record("got \(outcome)"); return }
        #expect(h.installedVersion() == "1.1")
    }

    @Test func adminPromptWhenFolderIsNotWritable() async throws {
        let h = try Harness()
        let app = try h.installed()
        let data = try h.serveZip()
        h.files.writable = false
        let outcome = await h.install(app, try h.sparkleRelease(signing: data))
        guard case .installed(let oldCopy?, _) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(h.files.privilegedCalls == 1)
        #expect(oldCopy.deletingLastPathComponent().path == h.trashFolder.path)
        #expect(oldCopy.lastPathComponent.hasPrefix("Fixture 1.0 (replaced "))
        #expect(h.files.lastRequirement == "anchor apple generic and certificate leaf[subject.OU] = \"\(teamA)\"")
        #expect(h.installedVersion() == "1.1")
    }
}

// MARK: Every install rule refuses a bad file (the README's eight promises)

@Suite struct InstallRefuses {
    @Test func wrongTeamID() async throws {
        let h = try Harness()
        let app = try h.installed()
        let data = try h.serveZip(team: teamB)
        h.expectRefused(await h.install(app, try h.sparkleRelease(signing: data)), .sameDeveloper)
    }

    @Test func badEdDSASignature() async throws {
        let h = try Harness()
        let app = try h.installed()
        let data = try h.serveZip()
        let impostor = Curve25519.Signing.PrivateKey()
        h.expectRefused(await h.install(app, try h.sparkleRelease(signing: data, with: impostor)), .publisherSignature)
    }

    @Test func tamperedFileFailsEdDSA() async throws {
        let h = try Harness()
        let app = try h.installed()
        let data = try h.serveZip()
        var tampered = data
        tampered[tampered.count / 2] ^= 0xFF
        h.client.serveDownload(h.downloadURL, data: tampered)
        h.expectRefused(await h.install(app, try h.sparkleRelease(signing: data)), .publisherSignature)
    }

    @Test func missingEdDSASignatureWhenAppPinsAKey() async throws {
        let h = try Harness()
        let app = try h.installed()
        try h.serveZip()
        h.expectRefused(await h.install(app, try h.sparkleRelease(signing: nil)), .publisherSignature)
        #expect(h.client.requests.isEmpty, "refused before downloading")
    }

    @Test func wrongChecksum() async throws {
        let h = try Harness()
        let app = try h.installed(edKey: false)
        try h.serveZip()
        h.expectRefused(await h.install(app, h.caskRelease(sha256: String(repeating: "0", count: 64))), .checksum)
    }

    @Test func wrongSHA512() async throws {
        let h = try Harness()
        let app = try h.installed(edKey: false)
        try h.serveZip()
        let release = Release(source: .electron, version: VersionPair(short: "1.1"), basis: .shortVersion,
                              downloadURL: URL(string: h.downloadURL), downloadPage: h.page, sha512: Data(repeating: 1, count: 64).base64EncodedString())
        h.expectRefused(await h.install(app, release), .checksum)
    }

    @Test func unsignedNewApp() async throws {
        let h = try Harness()
        let app = try h.installed()
        let data = try h.serveZip(team: "UNSIGNED")
        h.expectRefused(await h.install(app, try h.sparkleRelease(signing: data)), .sameDeveloper)
    }

    @Test func brokenSignature() async throws {
        let h = try Harness()
        let app = try h.installed()
        let data = try h.serveZip(team: "BROKEN")
        h.expectRefused(await h.install(app, try h.sparkleRelease(signing: data)), .sameDeveloper)
    }

    @Test func realUnsignedAndAdHocCopiesAreRefused() async throws {
        // Real Security-framework checks: a bundle with no signature, then an ad-hoc one (no Team ID).
        for adHoc in [false, true] {
            let h = try Harness()
            h.signatures = SplitSignatures(installedFolder: h.applications)
            h.validator = SecuritySignatureValidator()
            let app = try h.installed(signature: CodeSignature(kind: .developerID, teamID: teamA))
            let data = try h.serveZip(team: nil) { bundle in if adHoc { try codesignAdHoc(bundle) } }
            h.expectRefused(await h.install(app, try h.sparkleRelease(signing: data)), .sameDeveloper)
        }
    }

    @Test func packageIsOpenedInInstallerNeverRun() async throws {
        let h = try Harness()
        let app = try h.installed(edKey: false)
        h.packages.team = teamA
        var pkg = Data("xar!".utf8)
        pkg.append(Data(repeating: 0, count: 600))
        h.client.serveDownload(h.downloadURL, data: pkg)
        let outcome = await h.install(app, h.caskRelease(sha256: nil))
        guard case let .openedInInstaller(kept) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(h.opener.opened == [kept])
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(h.installedVersion() == "1.0", "Burnish doesn't replace anything for a .pkg")
        #expect(h.trashIsEmpty)
    }

    @Test func packageFromAnotherDeveloper() async throws {
        let h = try Harness()
        let app = try h.installed(edKey: false)
        h.packages.team = teamB
        var pkg = Data("xar!".utf8)
        pkg.append(Data(repeating: 0, count: 600))
        h.client.serveDownload(h.downloadURL, data: pkg)
        h.expectRefused(await h.install(app, h.caskRelease(sha256: nil)), .package)
    }

    @Test func differentBundleID() async throws {
        let h = try Harness()
        let app = try h.installed()
        let data = try h.serveZip(id: "com.attacker.fixture")
        h.expectRefused(await h.install(app, try h.sparkleRelease(signing: data)), .sameDeveloper)
    }

    @Test func unsignedInstalledAppIsNeverAutoUpdated() async throws {
        let h = try Harness()
        let app = try h.installed(team: nil, edKey: false)
        try h.serveZip(team: nil)
        h.expectRefused(await h.install(app, h.caskRelease(sha256: nil)), .unsignedInstalledApp)
        #expect(h.client.requests.isEmpty, "refused before downloading")
    }

    @Test func plainHTTPOrigin() async throws {
        let h = try Harness()
        let app = try h.installed(edKey: false)
        h.expectRefused(await h.install(app, h.caskRelease(sha256: nil, url: "http://example.com/Fixture-1.1.zip")), .trustedOrigin)
    }

    @Test func gatekeeperRejection() async throws {
        let h = try Harness()
        let app = try h.installed()
        let data = try h.serveZip()
        h.gatekeeper.accept = false
        h.expectRefused(await h.install(app, try h.sparkleRelease(signing: data)), .sameDeveloper)
    }

    @Test func downloadNotNewer() async throws {
        let h = try Harness()
        let app = try h.installed()
        let data = try h.serveZip(short: "1.0", build: "100")
        h.expectRefused(await h.install(app, try h.sparkleRelease(signing: data)), .notNewer)
    }

    @Test func needsNewerMacOS() async throws {
        let h = try Harness()
        let app = try h.installed()
        let data = try h.serveZip(minimumOS: "99.0")
        h.expectRefused(await h.install(app, try h.sparkleRelease(signing: data)), .notNewer)
    }

    @Test func appStoreAndHomebrewAppsAreNotTouched() async throws {
        let h = try Harness()
        let mas = try h.installed(edKey: false, appStore: true)
        h.expectRefused(await h.install(mas, h.caskRelease(sha256: nil)), .manualOnly)
        try FileManager.default.removeItem(at: mas.url)
        let brew = try h.installed(edKey: false, caskroom: "fixture")
        h.expectRefused(await h.install(brew, h.caskRelease(sha256: nil)), .manualOnly)
        #expect(h.client.requests.isEmpty)
    }

    @Test func informationalUpdate() async throws {
        let h = try Harness()
        let app = try h.installed()
        var release = try h.sparkleRelease(signing: Data())
        release.isInformational = true
        h.expectRefused(await h.install(app, release), .manualOnly)
    }

    @Test func appThatWontQuitIsNeverForced() async throws {
        let h = try Harness()
        let app = try h.installed()
        let data = try h.serveZip()
        h.apps.runningPIDs = [99]
        h.apps.quitsWhenAsked = false
        let asked = Counter()
        let outcome = await h.install(app, try h.sparkleRelease(signing: data)) { _ in
            await asked.increment()
            return await asked.value < 2 ? .tryAgain : .cancel
        }
        #expect(outcome == .cancelled)
        #expect(await asked.value == 2, "the user was asked, twice")
        #expect(h.apps.quitRequests == 2, "only polite quit requests")
        #expect(h.installedVersion() == "1.0")
        #expect(h.trashIsEmpty)
    }

    @Test func failedMovePutsOldAppBack() async throws {
        let h = try Harness()
        let app = try h.installed()
        let data = try h.serveZip()
        h.files.failMovesInto = app.url
        let outcome = await h.install(app, try h.sparkleRelease(signing: data))
        guard case let .refused(refusal) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(refusal.rule == .replace)
        #expect(h.installedVersion() == "1.0", "the old version is back where it was")
    }

    @Test func missingAppManagementPermission() async throws {
        let h = try Harness()
        let app = try h.installed()
        let data = try h.serveZip()
        h.trashFailure = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        let outcome = await h.install(app, try h.sparkleRelease(signing: data))
        guard case let .refused(refusal) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(refusal.rule == .appManagement)
        #expect(refusal.message.contains("App Management"))
        #expect(h.installedVersion() == "1.0")
    }
}

// MARK: Putting an earlier version back

@Suite struct RestorePutsBackTheEarlierVersion {
    /// Updates 1.0 to 1.1 the normal way, so the Trash holds 1.0 just as it would for real.
    func updated(_ h: Harness) async throws -> (current: InstalledApp, previous: URL) {
        let app = try h.installed()
        let data = try h.serveZip()
        guard case let .installed(oldCopy?, _) = await h.install(app, try h.sparkleRelease(signing: data)) else {
            throw CocoaError(.featureUnsupported)
        }
        let current = try #require(AppInventory(signatureReader: h.signatures, caskrooms: []).readApp(at: app.url))
        return (current, oldCopy)
    }

    func version(of bundle: URL) -> String? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    func expectRefused(_ outcome: InstallOutcome, _ rule: InstallRefusal.Rule, _ h: Harness, previous: URL,
                       sourceLocation: SourceLocation = #_sourceLocation) {
        guard case let .refused(refusal) = outcome else {
            Issue.record("expected refusal (\(rule)), got \(outcome)", sourceLocation: sourceLocation)
            return
        }
        #expect(refusal.rule == rule, sourceLocation: sourceLocation)
        #expect(h.installedVersion() == "1.1", "the current version stays", sourceLocation: sourceLocation)
    }

    @Test func swapsBackAndKeepsTheNewerCopyInTheTrash() async throws {
        let h = try Harness()
        let (current, previous) = try await updated(h)
        let outcome = await h.installer().restore(RestoreRequest(app: current, previousCopy: previous))
        guard case let .installed(newerCopy?, relaunched) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(h.installedVersion() == "1.0")
        #expect(!relaunched)
        #expect(!FileManager.default.fileExists(atPath: previous.path), "the earlier copy came out of the Trash")
        #expect(version(of: newerCopy) == "1.1", "and 1.1 went in, so there's still a way back")
    }

    @Test func quitsPolitelyAndRelaunches() async throws {
        let h = try Harness()
        let (current, previous) = try await updated(h)
        h.apps.runningPIDs = [42]
        let outcome = await h.installer().restore(RestoreRequest(app: current, previousCopy: previous))
        guard case .installed(_, let relaunched) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(relaunched)
        #expect(h.installedVersion() == "1.0")
    }

    @Test func refusesWhenTheCopyIsGone() async throws {
        let h = try Harness()
        let (current, previous) = try await updated(h)
        try FileManager.default.removeItem(at: previous)
        expectRefused(await h.installer().restore(RestoreRequest(app: current, previousCopy: previous)), .previousCopy, h, previous: previous)
    }

    @Test func refusesADifferentApp() async throws {
        let h = try Harness()
        let (current, previous) = try await updated(h)
        let impostor = try makeBundle(in: h.build, name: "Impostor", id: "com.example.other", short: "1.0", build: "100")
        expectRefused(await h.installer().restore(RestoreRequest(app: current, previousCopy: impostor)), .previousCopy, h, previous: previous)
    }

    @Test func refusesTheSameVersion() async throws {
        let h = try Harness()
        let (current, previous) = try await updated(h)
        let twin = try makeBundle(in: h.build, short: "1.1", build: "110")
        expectRefused(await h.installer().restore(RestoreRequest(app: current, previousCopy: twin)), .previousCopy, h, previous: previous)
    }

    @Test func refusesAnotherDevelopersCopy() async throws {
        let h = try Harness()
        let (current, previous) = try await updated(h)
        try teamB.write(to: previous.appendingPathComponent("Contents/Resources/fake-team"), atomically: true, encoding: .utf8)
        expectRefused(await h.installer().restore(RestoreRequest(app: current, previousCopy: previous)), .sameDeveloper, h, previous: previous)
    }

    @Test func refusesATamperedCopy() async throws {
        let h = try Harness()
        let (current, previous) = try await updated(h)
        try "BROKEN".write(to: previous.appendingPathComponent("Contents/Resources/fake-team"), atomically: true, encoding: .utf8)
        expectRefused(await h.installer().restore(RestoreRequest(app: current, previousCopy: previous)), .sameDeveloper, h, previous: previous)
    }

    @Test func refusesWhenGatekeeperSaysNo() async throws {
        let h = try Harness()
        let (current, previous) = try await updated(h)
        h.gatekeeper.accept = false
        expectRefused(await h.installer().restore(RestoreRequest(app: current, previousCopy: previous)), .sameDeveloper, h, previous: previous)
    }
}

@Suite struct InstallRechecksTheDisk {
    @Test func appThatUpdatedItselfIsNeverDowngraded() async throws {
        let h = try Harness()
        let checked = try h.installed()
        // After the check, the app updated itself to 1.2 (120).
        try FileManager.default.removeItem(at: checked.url)
        try makeBundle(in: h.applications, short: "1.2", build: "120", edKey: h.publicKey)
        let data = try h.serveZip()
        let outcome = await h.install(checked, try h.sparkleRelease(signing: data))
        guard case let .refused(refusal) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(refusal.rule == .notNewer)
        #expect(h.installedVersion() == "1.2")
        #expect(h.client.requests.isEmpty, "decided before downloading")
    }

    @Test func differentAppAtTheSamePath() async throws {
        let h = try Harness()
        let checked = try h.installed()
        try FileManager.default.removeItem(at: checked.url)
        try makeBundle(in: h.applications, id: "com.other.app", short: "1.0", build: "100")
        try h.serveZip()
        let outcome = await h.install(checked, try h.sparkleRelease(signing: Data()))
        guard case let .refused(refusal) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(refusal.rule == .changedSinceCheck)
    }

    @Test func signatureChangedSinceCheck() async throws {
        let h = try Harness()
        let checked = try h.installed()
        try teamB.write(to: checked.url.appendingPathComponent("Contents/Resources/fake-team"), atomically: true, encoding: .utf8)
        let outcome = await h.install(checked, try h.sparkleRelease(signing: try h.serveZip()))
        guard case let .refused(refusal) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(refusal.rule == .changedSinceCheck)
    }

    @Test func belowSparkleMinimumAutoupdateVersion() async throws {
        let h = try Harness()
        let app = try h.installed()
        var release = try h.sparkleRelease(signing: try h.serveZip())
        release.minimumAutoupdateVersion = "105"
        h.expectRefused(await h.install(app, release), .manualOnly)
    }

    @Test func rootOwnedAppFolderUsesTheAdminPrompt() async throws {
        let h = try Harness()
        let app = try h.installed()
        let data = try h.serveZip()
        h.files.unwritable = [app.url.path]
        let outcome = await h.install(app, try h.sparkleRelease(signing: data))
        guard case .installed = outcome else { Issue.record("got \(outcome)"); return }
        #expect(h.files.privilegedCalls == 1)
    }

    @Test func packageNameCannotEscapeThePackagesFolder() async throws {
        let h = try Harness()
        let app = try h.installed(edKey: false)
        h.packages.team = teamA
        var pkg = Data("xar!".utf8)
        pkg.append(Data(repeating: 0, count: 600))
        let evil = "https://example.com/..%2F..%2F..%2Fevil.pkg"
        h.client.serveDownload(evil, data: pkg)
        let outcome = await h.install(app, h.caskRelease(sha256: nil, url: evil))
        guard case let .openedInInstaller(kept) = outcome else { Issue.record("got \(outcome)"); return }
        let packages = h.root.appendingPathComponent("work/Packages").standardizedFileURL.path
        #expect(kept.standardizedFileURL.deletingLastPathComponent().path == packages)
        #expect(!kept.lastPathComponent.contains("/"))
    }

    @Test(arguments: ["dotdot", "absolute", "symlink"])
    func maliciousZipsStayInsideStaging(_ kind: String) async throws {
        let h = try Harness()
        let outside = h.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let zipURL = h.build.appendingPathComponent("\(kind).zip")
        try ZipWriter.write(kind: kind, outside: outside, to: zipURL)
        let staging = h.root.appendingPathComponent("work/job/staging")
        _ = try? await Unpacker().unpack(zipURL, kind: .zip, into: staging)
        let escaped = (FileManager.default.enumerator(atPath: h.root.path)?.allObjects as? [String] ?? [])
            .filter { $0.contains("escaped") && !$0.hasPrefix("work/job/staging/") }
        #expect(escaped.isEmpty, "\(escaped)")
        #expect(!FileManager.default.fileExists(atPath: "/tmp/escaped-burnish-\(kind).txt"))
    }
}

/// The admin script itself, run without admin rights in a temporary folder.
@Suite struct PrivilegedReplaceScript {
    func run(old: URL, new: URL, target: URL, partial: URL, requirement: String) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", SystemFileOperations.replaceScript, "burnish", old.path, new.path, target.path, partial.path, requirement]
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    func version(_ app: URL) -> String? {
        (try? PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    @Test func replacesAndKeepsTheOldCopy() throws {
        let h = try Harness()
        let old = try makeBundle(in: h.applications, short: "1.0", build: "100")
        let newFolder = h.build.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        let new = try makeBundle(in: newFolder, short: "1.1", build: "110")
        try codesignAdHoc(new)
        try FileManager.default.createDirectory(at: h.trashFolder, withIntermediateDirectories: true)
        let target = h.trashFolder.appendingPathComponent("Fixture 1.0.app")
        let status = try run(old: old, new: new, target: target, partial: h.trashFolder.appendingPathComponent("partial.app"),
                             requirement: "identifier \"\(bundleID)\"")
        #expect(status == 0)
        #expect(version(old) == "1.1")
        #expect(version(target) == "1.0")
    }

    @Test func failedVerificationPutsTheOldVersionBack() throws {
        let h = try Harness()
        let old = try makeBundle(in: h.applications, short: "1.0", build: "100")
        let newFolder = h.build.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        let new = try makeBundle(in: newFolder, short: "1.1", build: "110")
        try codesignAdHoc(new)
        try FileManager.default.createDirectory(at: h.trashFolder, withIntermediateDirectories: true)
        let target = h.trashFolder.appendingPathComponent("Fixture 1.0.app")
        let partial = h.trashFolder.appendingPathComponent("partial.app")
        // An ad-hoc copy can never satisfy an Apple-anchored Team ID requirement.
        let status = try run(old: old, new: new, target: target, partial: partial, requirement: AppInstaller.requirement(teamID: teamA))
        #expect(status == 5)
        #expect(version(old) == "1.0", "old version is back")
        #expect(version(partial) == "1.1", "the rejected copy is parked in the Trash, not deleted")
    }

    @Test func refusesWhenTheTrashNameIsTaken() throws {
        let h = try Harness()
        let old = try makeBundle(in: h.applications, short: "1.0", build: "100")
        try FileManager.default.createDirectory(at: h.trashFolder, withIntermediateDirectories: true)
        let target = try makeBundle(in: h.trashFolder, short: "0.9", build: "90")
        let status = try run(old: old, new: old, target: target, partial: h.trashFolder.appendingPathComponent("p.app"), requirement: "anchor apple")
        #expect(status == 3)
        #expect(version(old) == "1.0")
        #expect(version(target) == "0.9", "nothing moved into the existing item")
    }
}

/// Writes zips with path tricks, the way an attacker's archive would.
enum ZipWriter {
    static func write(kind: String, outside: URL, to url: URL) throws {
        let script = """
        import zipfile, stat, sys
        kind, outside, out = sys.argv[1], sys.argv[2], sys.argv[3]
        with zipfile.ZipFile(out, 'w') as z:
            z.writestr('Fixture.app/Contents/Info.plist', 'x')
            if kind == 'dotdot':
                z.writestr('../../../escaped-dotdot.txt', 'x')
            elif kind == 'absolute':
                z.writestr('/tmp/escaped-burnish-absolute.txt', 'x')
            else:
                info = zipfile.ZipInfo('link'); info.create_system = 3; info.external_attr = (stat.S_IFLNK | 0o777) << 16
                z.writestr(info, outside)
                z.writestr('link/escaped-symlink.txt', 'x')
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", "-c", script, kind, outside.path, url.path]
        try p.run()
        p.waitUntilExit()
    }
}

actor Counter {
    var value = 0
    func increment() { value += 1 }
}

@Suite struct InstallerHelpers {
    @Test func archiveKinds() throws {
        let h = try Harness()
        func write(_ bytes: [UInt8], _ name: String) throws -> URL {
            let url = h.build.appendingPathComponent(name)
            var data = Data(bytes)
            data.append(Data(repeating: 0, count: 600))
            try data.write(to: url)
            return url
        }
        #expect(ArchiveKind.detect(try write([0x50, 0x4B, 0x03, 0x04], "a.bin")) == .zip)
        #expect(ArchiveKind.detect(try write(Array("xar!".utf8), "b.bin")) == .pkg)
        #expect(ArchiveKind.detect(try write([0x1F, 0x8B], "c.bin")) == .tarGzip)
        #expect(ArchiveKind.detect(try write([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], "d.bin")) == .tarXz)
        #expect(ArchiveKind.detect(try write(Array("<html>".utf8), "e.bin")) == .unknown)
    }

    @Test func pkgutilOutput() {
        let text = """
        Package "AdGuard.pkg":
           Status: signed by a developer certificate issued by Apple for distribution
           Notarization: trusted by the Apple notary service
           Certificate Chain:
            1. Developer ID Installer: Adguard Software Limited (TC3Q7MAJXF)
               Expires: 2027-02-01 00:00:00 +0000
            2. Developer ID Certification Authority
        """
        #expect(PkgutilSignatureReader.teamID(fromCheckSignature: text) == "TC3Q7MAJXF")
        #expect(PkgutilSignatureReader.teamID(fromCheckSignature: "Status: no signature") == nil)
    }

    @Test func sha256Streaming() throws {
        let h = try Harness()
        let url = h.build.appendingPathComponent("x")
        try Data("hello".utf8).write(to: url)
        #expect(try DownloadVerifier.sha256Hex(of: url) == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }
}

@Suite struct CommunityFeedInstalls {
    @Test func aReleaseFromACommunityListedFeedIsNeverInstalled() async throws {
        let h = try Harness()
        let app = try h.installed()
        let data = try h.serveZip()
        var release = try h.sparkleRelease(signing: data)
        release.listedByCommunity = true
        h.expectRefused(await h.install(app, release), .trustedOrigin)
    }
}

@Suite struct KeepingEarlierVersions {
    func setUp() throws -> (root: URL, kept: EarlierVersions, trash: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("burnish-earlier-\(UUID().uuidString)")
        let trash = root.appendingPathComponent("Trash")
        return (root, EarlierVersions(directory: root.appendingPathComponent("Earlier Versions"), trash: FolderTrash(folder: trash)), trash)
    }

    @Test func keepsOneVersionPerAppAndTrashesTheOneBefore() throws {
        let (root, kept, trash) = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let v1 = try makeBundle(in: root.appendingPathComponent("a"), name: "Fixture 1.0", short: "1.0", build: "100")
        let first = try kept.keep(v1, bundleID: bundleID)
        #expect(FileManager.default.fileExists(atPath: first.path))
        let v2 = try makeBundle(in: root.appendingPathComponent("b"), name: "Fixture 1.1", short: "1.1", build: "110")
        let second = try kept.keep(v2, bundleID: bundleID)
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(!FileManager.default.fileExists(atPath: first.path), "only the latest earlier version stays")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: trash.path))?.contains("Fixture 1.0.app") == true, "and the older one went to the Trash, not away")
    }

    @Test func afterThirtyDaysItGoesToTheTrash() throws {
        let (root, kept, trash) = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try makeBundle(in: root.appendingPathComponent("a"), name: "Fixture 0.9", short: "0.9", build: "90")
        let now = Date()
        let kept1 = try kept.keep(old, bundleID: bundleID, now: now.addingTimeInterval(-31 * 86400))
        #expect(kept.prune(now: now).map(\.lastPathComponent) == [kept1.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: kept1.path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: trash.path))?.isEmpty == false)
        let fresh = try makeBundle(in: root.appendingPathComponent("b"), name: "Fixture 1.0", short: "1.0", build: "100")
        _ = try kept.keep(fresh, bundleID: bundleID, now: now)
        #expect(kept.prune(now: now).isEmpty, "a fresh copy stays")
    }
}
