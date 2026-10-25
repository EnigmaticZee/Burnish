import Foundation
import Inventory
import Net
import UpdateSources
import Versions
import os

/// Everything the installer touches, so tests can swap the real Trash, Gatekeeper and
/// running apps for stand-ins in a temporary folder.
public struct InstallerEnvironment: Sendable {
    public var client: HTTPClient
    /// Burnish's own scratch space (`~/Library/Application Support/Burnish/Downloads`).
    public var workDirectory: URL
    public var signatures: SignatureReading
    public var validator: SignatureValidating
    public var gatekeeper: GatekeeperAssessing
    public var packageSignatures: PackageSignatureReading
    public var apps: RunningAppControlling
    public var trash: Trashing
    public var files: FileOperating
    public var packageOpener: PackageOpening
    public var system: SystemVersion
    public var unpacker = Unpacker()
    /// Rule 6: ask the app to quit and wait up to 10 seconds.
    public var quitTimeout: TimeInterval = 10
    public var pollInterval: TimeInterval = 0.25
    /// Where the admin path parks the old copy (the user's Trash).
    public var userTrash: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")

    public init(
        client: HTTPClient, workDirectory: URL, signatures: SignatureReading, validator: SignatureValidating,
        gatekeeper: GatekeeperAssessing, packageSignatures: PackageSignatureReading, apps: RunningAppControlling,
        trash: Trashing, files: FileOperating, packageOpener: PackageOpening, system: SystemVersion
    ) {
        self.client = client
        self.workDirectory = workDirectory
        self.signatures = signatures
        self.validator = validator
        self.gatekeeper = gatekeeper
        self.packageSignatures = packageSignatures
        self.apps = apps
        self.trash = trash
        self.files = files
        self.packageOpener = packageOpener
        self.system = system
    }

    public static func live(client: HTTPClient, workDirectory: URL) -> InstallerEnvironment {
        InstallerEnvironment(
            client: client, workDirectory: workDirectory,
            signatures: SecuritySignatureReader(), validator: SecuritySignatureValidator(),
            gatekeeper: SpctlGatekeeper(), packageSignatures: PkgutilSignatureReader(),
            apps: WorkspaceAppController(), trash: FileManagerTrash(), files: SystemFileOperations(),
            packageOpener: WorkspacePackageOpener(), system: .current
        )
    }
}

/// Download → verify → unpack → verify → quit → replace → relaunch.
///
/// Every install rule (the README's eight promises) runs before the installed app is touched. Any failure
/// returns `.refused` with a plain reason and the download page; the old app stays as it was.
public struct AppInstaller: Sendable {
    public let env: InstallerEnvironment
    private let log = Logger(subsystem: "io.github.enigmaticzee.Burnish", category: "install")

    public init(environment: InstallerEnvironment) {
        env = environment
    }

    public func install(
        _ request: InstallRequest,
        progress: @escaping @Sendable (InstallPhase) -> Void = { _ in },
        askToQuit: @escaping @Sendable (String) async -> QuitDecision = { _ in .cancel }
    ) async -> InstallOutcome {
        let snapshot = request.app
        let release = request.release
        func refuse(_ rule: InstallRefusal.Rule, _ message: String) -> InstallOutcome {
            log.notice("Refused \(snapshot.bundleID, privacy: .public) [\(rule.rawValue, privacy: .public)]: \(message, privacy: .public)")
            return .refused(InstallRefusal(rule, message, downloadPage: request.downloadPage))
        }

        // MARK: Before downloading anything
        if snapshot.isAppStore { return refuse(.manualOnly, String(localized: "App Store apps update in the App Store")) }
        if snapshot.isManagedByHomebrew { return refuse(.manualOnly, String(localized: "Managed by Homebrew: update it with brew upgrade")) }
        // The check may be days old, and the app may have updated itself since. Decide from what's on disk now.
        guard var app = AppInventory(signatureReader: env.signatures, caskrooms: []).readApp(at: snapshot.url),
              app.bundleID == snapshot.bundleID else {
            return refuse(.changedSinceCheck, String(localized: "\(snapshot.name) has moved or changed since Burnish checked it. Check again."))
        }
        app.caskroomToken = snapshot.caskroomToken
        if app.isAppStore { return refuse(.manualOnly, String(localized: "App Store apps update in the App Store")) }
        guard app.signature.canBeAutoUpdated, let teamID = app.teamID, Self.isTeamID(teamID) else {
            return refuse(.unsignedInstalledApp, String(localized: "Burnish only replaces apps signed by their developer, and this copy isn't"))
        }
        if let checkedTeam = snapshot.teamID, checkedTeam != teamID {
            return refuse(.changedSinceCheck, String(localized: "\(app.name)'s signature changed since Burnish checked it. Check again."))
        }
        if release.isInformational || release.needsManualInstall {
            return refuse(.manualOnly, String(localized: "This update has to be downloaded from the developer's page"))
        }
        // Sparkle's own rule: below this version the developer wants a manual (often paid) upgrade.
        if release.wantsManualUpgrade(from: app.version) {
            return refuse(.manualOnly, String(localized: "The developer asks for this upgrade to be downloaded by hand"))
        }
        guard let url = release.downloadURL else { return refuse(.manualOnly, String(localized: "The source doesn't offer a download")) }
        // Rule 1: only the app's own feed or Homebrew's data, and only over HTTPS.
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              [.sparkle, .homebrew, .electron, .github].contains(release.source)
        else { return refuse(.trustedOrigin, String(localized: "The download doesn't come from a trusted HTTPS source")) }
        // Rule 2: an app that pins an EdDSA key only takes signed updates.
        let edKey = release.source == .sparkle ? app.sparklePublicEDKey : nil
        if edKey != nil, release.edSignature == nil {
            return refuse(.publisherSignature, String(localized: "The update isn't signed by its developer"))
        }
        guard case .newer = release.compare(with: app.version) else {
            return refuse(.notNewer, String(localized: "The update isn't newer than the installed version"))
        }

        let job = env.workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: job) }

        // MARK: Download
        progress(.downloading(received: 0, total: release.length))
        let file = job.appendingPathComponent("download")
        do {
            try await env.client.download(url, to: file) { received, total in
                progress(.downloading(received: received, total: total ?? release.length))
            }
        } catch {
            return refuse(.download, String(localized: "The download failed (\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))"))
        }

        // MARK: Verify the file (rules 2 and 3)
        progress(.verifying)
        if let edKey, let signature = release.edSignature {
            guard DownloadVerifier.verifyEdDSA(file: file, signature: signature, publicKey: edKey) else {
                return refuse(.publisherSignature, String(localized: "The update's signature doesn't match the developer's key"))
            }
        }
        if let expected = release.sha256 {
            guard (try? DownloadVerifier.sha256Hex(of: file)) == expected.lowercased() else {
                return refuse(.checksum, String(localized: "The download doesn't match its published checksum"))
            }
        }
        if let expected = release.sha512 {
            guard (try? DownloadVerifier.sha512Base64(of: file)) == expected else {
                return refuse(.checksum, String(localized: "The download doesn't match its published checksum"))
            }
        }

        // MARK: Unpack
        let kind = ArchiveKind.detect(file)
        if kind == .pkg {
            return await openPackage(file, teamID: teamID, name: url.lastPathComponent, refuse: refuse)
        }
        let staging = job.appendingPathComponent("staging", isDirectory: true)
        do {
            _ = try await env.unpacker.unpack(file, kind: kind, into: staging)
        } catch .licenseAgreement {
            return refuse(.manualOnly, Unpacker.Failure.licenseAgreement.errorDescription!)
        } catch {
            return refuse(.unpack, error.errorDescription ?? String(localized: "The download couldn't be opened"))
        }

        let newApp: URL
        switch locateApp(in: staging, for: app, expectedNames: request.expectedAppNames) {
        case .found(let found):
            newApp = found
        case .wrongBundleID(let id):
            return refuse(.sameDeveloper, String(localized: "The new copy has a different bundle ID (\(id))"))
        case .packageOnly(let pkg):
            return await openPackage(pkg, teamID: teamID, name: pkg.lastPathComponent, refuse: refuse)
        case .nothing:
            return refuse(.unpack, String(localized: "The download doesn't contain \(app.fileName)"))
        }

        // MARK: Same developer (rule 4)
        do {
            try env.validator.validate(newApp, teamID: teamID)
        } catch {
            return refuse(.sameDeveloper, (error as? LocalizedError)?.errorDescription ?? String(localized: "The new copy's signature isn't valid"))
        }
        let newSignature = env.signatures.signature(of: newApp)
        guard newSignature.teamID == teamID else {
            return refuse(.sameDeveloper, String(localized: "Signature didn't match the installed app"))
        }
        guard await env.gatekeeper.assess(newApp) else {
            return refuse(.sameDeveloper, String(localized: "macOS Gatekeeper didn't accept the new copy (it may not be notarised)"))
        }
        guard let newInfo = AppInventory(signatureReader: env.signatures, caskrooms: []).readApp(at: newApp),
              newInfo.bundleID == app.bundleID else {
            return refuse(.sameDeveloper, String(localized: "The new copy has a different bundle ID"))
        }
        guard case .newer = UpdateComparator.compare(installed: app.version, available: newInfo.version, basis: release.basis.comparison) else {
            return refuse(.notNewer, String(localized: "The download isn't newer than the installed version"))
        }
        guard env.system.satisfies(minimum: newInfo.minimumSystemVersion) else {
            return refuse(.notNewer, String(localized: "The new version needs macOS \(newInfo.minimumSystemVersion ?? "") or later"))
        }

        let outcome = await swap(app, with: newApp, teamID: teamID, progress: progress, askToQuit: askToQuit, refuse: refuse)
        if case .installed = outcome {
            log.info("Updated \(app.bundleID, privacy: .public) to \(newInfo.version.display, privacy: .public)")
        }
        return outcome
    }

    /// Puts back the version Burnish replaced, from the copy it left in the Trash. The copy sat in
    /// a folder anyone can write to, so it's checked like a download: same bundle ID, a valid
    /// signature from the same team, and Gatekeeper. The current version goes to the Trash in turn.
    public func restore(
        _ request: RestoreRequest,
        progress: @escaping @Sendable (InstallPhase) -> Void = { _ in },
        askToQuit: @escaping @Sendable (String) async -> QuitDecision = { _ in .cancel }
    ) async -> InstallOutcome {
        let snapshot = request.app
        let previous = request.previousCopy
        func refuse(_ rule: InstallRefusal.Rule, _ message: String) -> InstallOutcome {
            log.notice("Refused restore of \(snapshot.bundleID, privacy: .public) [\(rule.rawValue, privacy: .public)]: \(message, privacy: .public)")
            return .refused(InstallRefusal(rule, message, downloadPage: nil))
        }
        let reader = AppInventory(signatureReader: env.signatures, caskrooms: [])
        guard let app = reader.readApp(at: snapshot.url), app.bundleID == snapshot.bundleID else {
            return refuse(.changedSinceCheck, String(localized: "\(snapshot.name) has moved or changed since Burnish checked it. Check again."))
        }
        guard app.signature.canBeAutoUpdated, let teamID = app.teamID, Self.isTeamID(teamID) else {
            return refuse(.unsignedInstalledApp, String(localized: "Burnish only replaces apps signed by their developer, and this copy isn't"))
        }
        guard FileManager.default.fileExists(atPath: previous.path), let earlier = reader.readApp(at: previous) else {
            return refuse(.previousCopy, String(localized: "The earlier version is no longer in the Trash"))
        }
        guard earlier.bundleID == app.bundleID else {
            return refuse(.previousCopy, String(localized: "The copy in the Trash is a different app (\(earlier.bundleID))"))
        }
        guard earlier.version != app.version else {
            return refuse(.previousCopy, String(localized: "The copy in the Trash is the version you already have"))
        }
        do {
            try env.validator.validate(previous, teamID: teamID)
        } catch {
            return refuse(.sameDeveloper, (error as? LocalizedError)?.errorDescription ?? String(localized: "The earlier version's signature isn't valid"))
        }
        guard env.signatures.signature(of: previous).teamID == teamID else {
            return refuse(.sameDeveloper, String(localized: "Signature didn't match the installed app"))
        }
        guard await env.gatekeeper.assess(previous) else {
            return refuse(.sameDeveloper, String(localized: "macOS Gatekeeper didn't accept the earlier version"))
        }
        let outcome = await swap(app, with: previous, teamID: teamID, progress: progress, askToQuit: askToQuit, refuse: refuse)
        if case .installed = outcome {
            log.info("Restored \(app.bundleID, privacy: .public) to \(earlier.version.display, privacy: .public)")
        }
        return outcome
    }

    /// Rules 6 to 8: quit politely, move the installed copy to the Trash, put `replacement` in its
    /// place (through the administrator prompt when the folder needs it), relaunch if it was running.
    private func swap(
        _ app: InstalledApp, with replacement: URL, teamID: String,
        progress: @escaping @Sendable (InstallPhase) -> Void,
        askToQuit: @escaping @Sendable (String) async -> QuitDecision,
        refuse: (InstallRefusal.Rule, String) -> InstallOutcome
    ) async -> InstallOutcome {
        // MARK: Quit politely (rule 6)
        let pids = await env.apps.running(app.url)
        let wasRunning = !pids.isEmpty
        if wasRunning {
            progress(.waitingForQuit)
            while true {
                for pid in pids { await env.apps.requestQuit(pid) }
                if await waitForExit(pids) { break }
                switch await askToQuit(app.name) {
                case .tryAgain: continue
                case .cancel: return .cancelled
                }
            }
        }
        func relaunchIfNeeded() async {
            if wasRunning { await env.apps.relaunch(app.url) }
        }

        // MARK: Replace, keeping the old copy in the Trash (rules 7 and 8)
        progress(.replacing)
        let parent = app.url.deletingLastPathComponent()
        var oldCopy: URL?
        // Moving a folder elsewhere needs write access to it as well as to its parent.
        if env.files.isWritable(parent) && env.files.isWritable(app.url) {
            do {
                oldCopy = try env.trash.trash(app.url)
            } catch {
                await relaunchIfNeeded()
                if Self.isPermissionError(error) {
                    return refuse(.appManagement, String(localized: "Burnish needs the App Management permission to replace apps. Turn it on in System Settings → Privacy & Security → App Management."))
                }
                return refuse(.replace, String(localized: "The old version couldn't be moved to the Trash (\(error.localizedDescription))"))
            }
            do {
                try env.files.move(replacement, to: app.url)
            } catch {
                // A half-copied new version goes to the Trash too, then the old one comes back.
                if FileManager.default.fileExists(atPath: app.url.path) { _ = try? env.trash.trash(app.url) }
                var restored = false
                if let oldCopy, !FileManager.default.fileExists(atPath: app.url.path) {
                    restored = (try? env.files.move(oldCopy, to: app.url)) != nil
                }
                if restored { await relaunchIfNeeded() }
                return refuse(.replace, restored
                    ? String(localized: "The new version couldn't be moved into place, so the old one was put back")
                    : String(localized: "The new version couldn't be moved into place. The old version is in the Trash; drag it back to \(parent.path)."))
            }
        } else {
            let target = Self.uniqueTrashURL(for: app, in: env.userTrash)
            do {
                try await env.files.privilegedReplace(old: app.url, new: replacement, trashTarget: target,
                                                      requirement: Self.requirement(teamID: teamID), appName: app.name)
                oldCopy = target
            } catch let error as CocoaError where error.code == .userCancelled {
                await relaunchIfNeeded()
                return .cancelled
            } catch {
                await relaunchIfNeeded()
                return refuse(.permission, String(localized: "Replacing \(app.name) needs an administrator, and that didn't work (\(error.localizedDescription))"))
            }
        }

        if wasRunning {
            progress(.relaunching)
            await env.apps.relaunch(app.url)
        }
        return .installed(oldCopy: oldCopy, relaunched: wasRunning)
    }

    // MARK: Packages (rule 5)

    private func openPackage(
        _ pkg: URL, teamID: String, name: String, refuse: (InstallRefusal.Rule, String) -> InstallOutcome
    ) async -> InstallOutcome {
        guard await env.packageSignatures.teamID(ofPackage: pkg) == teamID else {
            return refuse(.package, String(localized: "The installer package isn't signed by the same developer as the installed app"))
        }
        // The job folder is cleaned up on return, so keep the package somewhere Installer can read it.
        let packages = env.workDirectory.appendingPathComponent("Packages", isDirectory: true)
        let kept = packages.appendingPathComponent(Self.safePackageName(name))
        do {
            try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: pkg, to: kept)
        } catch {
            return refuse(.package, String(localized: "The installer package couldn't be saved (\(error.localizedDescription))"))
        }
        await env.packageOpener.open(kept)
        return .openedInInstaller(kept)
    }

    // MARK: Helpers

    enum Located: Equatable {
        case found(URL)
        case wrongBundleID(String)
        case packageOnly(URL)
        case nothing
    }

    /// Finds the app inside the unpacked download: same bundle ID, real directory, inside staging.
    func locateApp(in staging: URL, for app: InstalledApp, expectedNames: [String]) -> Located {
        let root = staging.resolvingSymlinksInPath().standardizedFileURL.path
        var bundles: [URL] = []
        var packages: [URL] = []
        func walk(_ dir: URL, depth: Int) {
            guard depth <= 3, let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { return }
            for item in items {
                let values = try? item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values?.isSymbolicLink == true { continue }
                let ext = item.pathExtension.lowercased()
                if ext == "app" {
                    bundles.append(item)
                } else if ext == "pkg" || ext == "mpkg" {
                    packages.append(item)
                } else if values?.isDirectory == true, item.lastPathComponent != "__MACOSX" {
                    walk(item, depth: depth + 1)
                }
            }
        }
        walk(staging, depth: 0)
        bundles = bundles.filter { $0.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root + "/") }

        let reader = AppInventory(signatureReader: env.signatures, caskrooms: [])
        let infos = bundles.compactMap { url in reader.readApp(at: url).map { (url, $0) } }
        let matching = infos.filter { $0.1.bundleID == app.bundleID }
        if !matching.isEmpty {
            let preferred = Set([app.fileName.lowercased()] + expectedNames.map { $0.lowercased() })
            return .found((matching.first { preferred.contains($0.0.lastPathComponent.lowercased()) } ?? matching[0]).0)
        }
        let names = Set([app.fileName.lowercased()] + expectedNames.map { $0.lowercased() })
        if let lookalike = infos.first(where: { names.contains($0.0.lastPathComponent.lowercased()) }) ?? (infos.count == 1 ? infos.first : nil) {
            return .wrongBundleID(lookalike.1.bundleID)
        }
        if let pkg = packages.first { return .packageOnly(pkg) }
        return .nothing
    }

    private func waitForExit(_ pids: [pid_t]) async -> Bool {
        let deadline = Date().addingTimeInterval(env.quitTimeout)
        while Date() < deadline {
            if await !anyRunning(pids) { return true }
            try? await Task.sleep(nanoseconds: UInt64(env.pollInterval * 1_000_000_000))
        }
        return await !anyRunning(pids)
    }

    private func anyRunning(_ pids: [pid_t]) async -> Bool {
        for pid in pids {
            if await env.apps.isRunning(pid) { return true }
        }
        return false
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) { return true }
        if ns.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }

    /// `Foo 1.0 (replaced 2026-10-24 221505).app`. The admin script refuses to overwrite it anyway,
    /// but a timestamp keeps the name free even when ~/.Trash can't be listed.
    static func uniqueTrashURL(for app: InstalledApp, in trash: URL, now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let base = "\(app.name) \(app.version.display) (replaced \(formatter.string(from: now)))"
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var candidate = trash.appendingPathComponent("\(base).app")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = trash.appendingPathComponent("\(base) \(n).app")
            n += 1
        }
        return candidate
    }

    /// A file name that stays inside Burnish's Packages folder whatever the download URL said.
    static func safePackageName(_ name: String) -> String {
        var base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "Update" }
        let lower = base.lowercased()
        if !lower.hasSuffix(".pkg") && !lower.hasSuffix(".mpkg") { base += ".pkg" }
        return "\(UUID().uuidString.prefix(8))-\(base)"
    }

    static func isTeamID(_ id: String) -> Bool {
        id.count == 10 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Signed by an Apple-issued certificate (Developer ID or App Store) for this Team ID.
    public static func requirement(teamID: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}
