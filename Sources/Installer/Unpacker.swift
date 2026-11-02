import Foundation

/// Opens a downloaded archive into a staging folder. Disk images are copied out and detached
/// straight away, so nothing stays mounted.
public struct Unpacker: Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        case unsupported
        case licenseAgreement
        case tool(String)

        public var errorDescription: String? {
            switch self {
            case .unsupported: String(localized: "Burnish can't open this kind of download")
            case .licenseAgreement: String(localized: "This download asks you to accept a licence agreement first")
            case .tool(let detail): String(localized: "The download couldn't be opened (\(detail))")
            }
        }
    }

    public init() {}

    /// Opens `file` as `detected`, and when that tool can't read it gives the other openers a turn,
    /// so a misread of the first bytes costs a second rather than the install. Returns the kind
    /// that worked; when none does, the failure is the one for the kind Burnish read.
    public func open(_ file: URL, detected: ArchiveKind, into destination: URL) async throws(Failure) -> ArchiveKind {
        let alternatives: [ArchiveKind] = [.dmg, .zip, .tar].filter { $0.opener != detected.opener }
        var firstFailure: Failure?
        for kind in [detected] + alternatives where kind != .pkg {
            do {
                _ = try await unpack(file, kind: kind, into: destination)
                return kind
            } catch .licenseAgreement {
                throw .licenseAgreement
            } catch {
                if kind == detected { firstFailure = error }
                try? FileManager.default.removeItem(at: destination)
            }
        }
        throw firstFailure ?? .unsupported
    }

    /// Unpacks `file` into `destination` and returns it.
    func unpack(_ file: URL, kind: ArchiveKind, into destination: URL) async throws(Failure) -> URL {
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw .tool(error.localizedDescription)
        }
        switch kind {
        case .zip:
            try await run("/usr/bin/ditto", ["-x", "-k", file.path, destination.path])
        case .tarGzip, .tarBzip2, .tarXz, .tar:
            try await run("/usr/bin/tar", ["-xf", file.path, "-C", destination.path])
        case .dmg:
            try await copyOutOfDiskImage(file, into: destination)
        case .pkg, .unknown:
            throw .unsupported
        }
        return destination
    }

    private func copyOutOfDiskImage(_ image: URL, into destination: URL) async throws(Failure) {
        // A licence agreement must be accepted by the person, never by Burnish.
        if let info = try? await Shell.run("/usr/bin/hdiutil", ["imageinfo", "-plist", image.path]), info.succeeded,
           let plist = try? PropertyListSerialization.propertyList(from: info.stdout, format: nil) as? [String: Any],
           let properties = plist["Properties"] as? [String: Any],
           properties["Software License Agreement"] as? Bool == true {
            throw .licenseAgreement
        }
        let mountPoint = destination.deletingLastPathComponent().appendingPathComponent("mount-\(UUID().uuidString)")
        let attach = try await attach(image, at: mountPoint)
        guard attach.succeeded else {
            if attach.errorText.lowercased().contains("license") { throw .licenseAgreement }
            throw .tool("hdiutil attach: \(lastLine(attach.errorText))")
        }
        do {
            // Skip the usual "Applications" shortcut and any other symlink.
            let items = try FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                .filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true }
            let installable = items.filter { ["app", "pkg", "mpkg"].contains($0.pathExtension.lowercased()) }
            // Some images keep the app inside a folder; then the folders come out instead.
            let wanted = installable.isEmpty
                ? items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                : installable
            for item in wanted {
                try await run("/usr/bin/ditto", [item.path, destination.appendingPathComponent(item.lastPathComponent).path])
            }
        } catch let failure as Failure {
            await detach(mountPoint)
            throw failure
        } catch {
            await detach(mountPoint)
            throw .tool(error.localizedDescription)
        }
        await detach(mountPoint)
    }

    /// `hdiutil attach` answers "Resource temporarily unavailable" when another image is being
    /// attached at the same moment; a short wait and another go is all it needs.
    private func attach(_ image: URL, at mountPoint: URL) async throws(Failure) -> Shell.Output {
        var output: Shell.Output?
        for delay in [0.0, 0.5, 1, 2, 3] {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            do {
                output = try await Shell.run("/usr/bin/hdiutil", [
                    "attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", "-mountpoint", mountPoint.path, image.path,
                ])
            } catch {
                throw .tool(error.localizedDescription)
            }
            if let output, output.succeeded || !output.errorText.contains("temporarily unavailable") { return output }
        }
        guard let output else { throw .tool("hdiutil attach: no answer") }
        return output
    }

    private func detach(_ mountPoint: URL) async {
        _ = try? await Shell.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
    }

    private func run(_ tool: String, _ args: [String]) async throws(Failure) {
        let output: Shell.Output
        do {
            output = try await Shell.run(tool, args)
        } catch {
            throw .tool(error.localizedDescription)
        }
        guard output.succeeded else { throw .tool("\((tool as NSString).lastPathComponent): \(lastLine(output.errorText))") }
    }

    /// The tool's verdict, without the warnings it printed on the way (hdiutil's deprecation note
    /// comes before every answer on newer systems).
    private func lastLine(_ text: String) -> String {
        text.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? text
    }
}
