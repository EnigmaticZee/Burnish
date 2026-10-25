import AppKit
import Foundation
import Inventory

/// `spctl --assess`: the same check Gatekeeper makes before opening an app, including notarisation.
public struct SpctlGatekeeper: GatekeeperAssessing {
    public init() {}

    public func assess(_ app: URL) async -> Bool {
        guard let output = try? await Shell.run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) else { return false }
        return output.succeeded
    }
}

public struct SecuritySignatureValidator: SignatureValidating {
    public init() {}
    public func validate(_ app: URL, teamID: String) throws {
        try SignatureValidator.validate(app, requirement: AppInstaller.requirement(teamID: teamID))
    }
}

/// The Team ID of a package that Gatekeeper accepts for installing (`spctl -t install`, which
/// requires an Apple-issued Developer ID Installer certificate and notarisation), read from
/// `pkgutil --check-signature` ("Developer ID Installer: Name (TEAMID)").
public struct PkgutilSignatureReader: PackageSignatureReading {
    public init() {}

    public func teamID(ofPackage url: URL) async -> String? {
        guard let assessment = try? await Shell.run("/usr/sbin/spctl", ["--assess", "--type", "install", url.path]),
              assessment.succeeded,
              let output = try? await Shell.run("/usr/sbin/pkgutil", ["--check-signature", url.path]), output.succeeded
        else { return nil }
        return Self.teamID(fromCheckSignature: output.text)
    }

    static func teamID(fromCheckSignature text: String) -> String? {
        // A self-signed certificate can claim any name; only trust Apple-issued ones.
        guard text.split(separator: "\n").contains(where: { $0.contains("Status:") && $0.contains("issued by Apple") }) else {
            return nil
        }
        for line in text.split(separator: "\n") where line.contains("Developer ID Installer:") {
            if let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close {
                return String(line[line.index(after: open)..<close])
            }
        }
        return nil
    }
}

/// Quits and relaunches apps through AppKit. Quitting is always the polite kind.
public struct WorkspaceAppController: RunningAppControlling {
    public init() {}

    @MainActor
    public func running(_ app: URL) async -> [pid_t] {
        // Compare paths, not URLs: `Foo.app` and `Foo.app/` are the same bundle.
        let target = app.resolvingSymlinksInPath().standardizedFileURL.path
        return NSWorkspace.shared.runningApplications
            .filter { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == target }
            .map(\.processIdentifier)
    }

    @MainActor
    public func requestQuit(_ pid: pid_t) async {
        _ = NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    @MainActor
    public func isRunning(_ pid: pid_t) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }

    @MainActor
    public func relaunch(_ app: URL) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }
}

public struct FileManagerTrash: Trashing {
    public init() {}

    public func trash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}

public struct SystemFileOperations: FileOperating {
    public init() {}

    public func isWritable(_ directory: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: directory.path)
    }

    public func move(_ source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    /// The shell script run as root. Paths arrive as arguments ($1…$5), never spliced into text.
    /// It never deletes: a failed copy is parked in the Trash and the old version moved back.
    static let replaceScript = """
    old="$1"; new="$2"; target="$3"; partial="$4"; req="$5"
    [ -e "$target" ] && exit 3
    [ -e "$partial" ] && exit 3
    /bin/mv "$old" "$target" || exit 4
    if /usr/bin/ditto "$new" "$old" && /usr/bin/codesign --verify --deep --strict -R "=$req" "$old"; then exit 0; fi
    [ -e "$old" ] && /bin/mv "$old" "$partial"
    [ -e "$old" ] && exit 6
    /bin/mv "$target" "$old" || exit 6
    exit 5
    """

    /// Uses the standard macOS administrator prompt via `osascript`. Burnish never sees or
    /// stores the password.
    public func privilegedReplace(old: URL, new: URL, trashTarget: URL, requirement: String, appName: String) async throws {
        let partial = trashTarget.deletingPathExtension().appendingPathExtension("incomplete-\(UUID().uuidString.prefix(6)).app")
        let script = """
        on run argv
            set cmd to "/bin/sh -c " & quoted form of (item 1 of argv) & " burnish"
            repeat with i from 2 to 6
                set cmd to cmd & " " & quoted form of (item i of argv)
            end repeat
            do shell script cmd with prompt (item 7 of argv) with administrator privileges
        end run
        """
        let output = try await Shell.run("/usr/bin/osascript", [
            "-e", script, Self.replaceScript, old.path, new.path, trashTarget.path, partial.path, requirement,
            String(localized: "Burnish needs an administrator to update \(appName)."),
        ])
        guard output.succeeded else {
            let text = output.errorText
            if text.contains("-128") { throw CocoaError(.userCancelled) }
            let message: String
            if text.hasSuffix("(5)") {
                message = String(localized: "The copy failed, so the old version was put back")
            } else if text.hasSuffix("(6)") {
                message = String(localized: "The copy failed. The old version is in the Trash as \(trashTarget.lastPathComponent)")
            } else if text.hasSuffix("(3)") {
                message = String(localized: "A file with the same name is already in the Trash")
            } else {
                message = text
            }
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

public struct WorkspacePackageOpener: PackageOpening {
    public init() {}

    @MainActor
    public func open(_ package: URL) async {
        let installer = URL(fileURLWithPath: "/System/Library/CoreServices/Installer.app")
        let configuration = NSWorkspace.OpenConfiguration()
        _ = try? await NSWorkspace.shared.open([package], withApplicationAt: installer, configuration: configuration)
    }
}
