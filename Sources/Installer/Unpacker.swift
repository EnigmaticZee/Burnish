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
            case .unsupported: "Burnish can't open this kind of download"
            case .licenseAgreement: "This download asks you to accept a licence agreement first"
            case .tool(let detail): "The download couldn't be opened (\(detail))"
            }
        }
    }

    public init() {}

    /// Unpacks `file` into `destination` and returns it.
    public func unpack(_ file: URL, kind: ArchiveKind, into destination: URL) async throws(Failure) -> URL {
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
        let attach: Shell.Output
        do {
            attach = try await Shell.run("/usr/bin/hdiutil", [
                "attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", "-mountpoint", mountPoint.path, image.path,
            ])
        } catch {
            throw .tool(error.localizedDescription)
        }
        guard attach.succeeded else {
            if attach.errorText.lowercased().contains("license") { throw .licenseAgreement }
            throw .tool("hdiutil attach: \(attach.errorText)")
        }
        do {
            let items = try FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: [.isSymbolicLinkKey])
            for item in items where !(item.lastPathComponent.hasPrefix(".")) {
                // Skip the usual "Applications" shortcut and any other symlink.
                if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
                let ext = item.pathExtension.lowercased()
                guard ext == "app" || ext == "pkg" || ext == "mpkg" else { continue }
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
        guard output.succeeded else { throw .tool("\((tool as NSString).lastPathComponent): \(output.errorText)") }
    }
}
