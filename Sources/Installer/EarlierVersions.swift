import Foundation

/// Keeps the version an update replaced in Burnish's own folder for a while, so emptying the
/// Trash doesn't take away Put Back. One earlier version per app; anything older than the
/// keeping period goes back to the Trash, never deleted outright.
public struct EarlierVersions: Sendable {
    public static let keepFor: TimeInterval = 30 * 24 * 3600

    public let directory: URL
    let trash: Trashing

    public init(directory: URL, trash: Trashing = FileManagerTrash()) {
        self.directory = directory
        self.trash = trash
    }

    /// Moves `copy` (normally just put in the Trash) into this folder and returns where it went.
    /// The app's previously kept version, if any, goes to the Trash.
    public func keep(_ copy: URL, bundleID: String, now: Date = Date()) throws -> URL {
        let folder = directory.appendingPathComponent(Self.safe(bundleID), isDirectory: true)
        let fm = FileManager.default
        if let old = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for item in old { _ = try? trash.trash(item) }
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(copy.lastPathComponent)
        try fm.moveItem(at: copy, to: target)
        // The keeping period starts now, whatever the bundle's own dates say.
        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: target.path)
        return target
    }

    /// Sends kept versions older than the keeping period to the Trash. Returns what went.
    @discardableResult
    public func prune(now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var removed: [URL] = []
        for folder in folders {
            let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for item in items {
                let kept = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
                if now.timeIntervalSince(kept) > Self.keepFor, (try? trash.trash(item)) != nil { removed.append(item) }
            }
            if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? fm.removeItem(at: folder) }
        }
        return removed
    }

    static func safe(_ bundleID: String) -> String {
        bundleID.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "..", with: "-")
    }
}
