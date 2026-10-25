import Foundation
import Versions

/// Finds apps and reads what they say about themselves.
public struct AppInventory: Sendable {
    public static let systemApplications = URL(fileURLWithPath: "/Applications")
    public static var userApplications: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    }
    public static let defaultCaskrooms = [
        URL(fileURLWithPath: "/opt/homebrew/Caskroom"),
        URL(fileURLWithPath: "/usr/local/Caskroom"),
    ]

    private let signatureReader: SignatureReading
    private let caskrooms: [URL]
    private let excludedBundleIDs: Set<String>

    public init(
        signatureReader: SignatureReading = SecuritySignatureReader(),
        caskrooms: [URL] = AppInventory.defaultCaskrooms,
        excludedBundleIDs: Set<String> = []
    ) {
        self.signatureReader = signatureReader
        self.caskrooms = caskrooms
        self.excludedBundleIDs = excludedBundleIDs
    }

    /// Scans each root two folders deep (`/Applications/X.app` and `/Applications/Folder/X.app`).
    /// Apps that resolve into `/System` (Safari) are skipped; they update with macOS.
    public func scan(roots: [URL]) -> InventoryResult {
        let caskroom = CaskroomScanner(roots: caskrooms).scan()
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for bundle in roots.flatMap(Self.findBundles) {
            let resolved = bundle.resolvingSymlinksInPath().standardizedFileURL
            guard !resolved.path.hasPrefix("/System/"), seen.insert(resolved.path).inserted else { continue }
            guard var app = readApp(at: bundle) else { continue }
            guard !excludedBundleIDs.contains(app.bundleID) else { continue }
            app.caskroomToken = caskroom.token(forAppNamed: app.fileName, version: app.version.short)
            apps.append(app)
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return InventoryResult(apps: apps, caskroom: caskroom)
    }

    static func findBundles(in root: URL) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        guard let top = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        for item in top {
            if item.pathExtension == "app" {
                found.append(item)
            } else if item.isDirectory, item.pathExtension.isEmpty || item.pathExtension == "localized" {
                let nested = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                found.append(contentsOf: nested.filter { $0.pathExtension == "app" })
            }
        }
        return found
    }

    /// Reads one `.app` bundle. Returns nil for bundles without a bundle ID.
    public func readApp(at url: URL) -> InstalledApp? {
        let fm = FileManager.default
        let contents = url.appendingPathComponent("Contents")
        var plistURL = contents.appendingPathComponent("Info.plist")
        var isWrapped = false
        if !fm.fileExists(atPath: plistURL.path) {
            // iPhone and iPad apps on Apple silicon: Foo.app/WrappedBundle -> Wrapper/Foo.app
            let wrapped = url.appendingPathComponent("WrappedBundle/Info.plist")
            guard fm.fileExists(atPath: wrapped.path) else { return nil }
            plistURL = wrapped
            isWrapped = true
        }
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = (plist["CFBundleIdentifier"] as? String)?.nonEmpty
        else { return nil }

        let short = (plist["CFBundleShortVersionString"] as? String)?.nonEmpty
        let build = (plist["CFBundleVersion"] as? String)?.nonEmpty
        let names = [plist["CFBundleDisplayName"], plist["CFBundleName"]].compactMap { ($0 as? String)?.nonEmpty }
        let feed = (plist["SUFeedURL"] as? String)?.nonEmpty.flatMap { URL(string: $0) }
        let receipt = contents.appendingPathComponent("_MASReceipt/receipt")
        let electron = contents.appendingPathComponent("Resources/app-update.yml")
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

        return InstalledApp(
            bundleID: bundleID,
            name: url.deletingPathExtension().lastPathComponent,
            bundleNames: Array(NSOrderedSet(array: names)) as? [String] ?? names,
            url: url,
            version: VersionPair(short: short, build: build),
            signature: signatureReader.signature(of: url),
            isAppStore: isWrapped || fm.fileExists(atPath: receipt.path),
            isWrappedIOSApp: isWrapped,
            sparkleFeedURL: feed,
            sparklePublicEDKey: (plist["SUPublicEDKey"] as? String)?.nonEmpty,
            electronUpdateConfig: fm.fileExists(atPath: electron.path) ? electron : nil,
            minimumSystemVersion: (plist["LSMinimumSystemVersion"] as? String)?.nonEmpty,
            modificationDate: modified
        )
    }
}

public struct InventoryResult: Sendable {
    public var apps: [InstalledApp]
    public var caskroom: CaskroomScan
}

extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}

extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
