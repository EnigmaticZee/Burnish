import Foundation
import Inventory

/// A developer's own updater that looks after some of their apps, found on this Mac.
public struct VendorUpdater: Sendable, Hashable, Codable {
    /// "Microsoft AutoUpdate".
    public let name: String
    /// "AutoUpdate": short enough for a row's button.
    public let shortName: String
    /// The updater app itself.
    public let path: String

    public init(name: String, shortName: String, path: String) {
        self.name = name
        self.shortName = shortName
        self.path = path
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

/// Apps whose developer ships its own updater: Burnish opens that instead of a download page or
/// its own install, because the vendor's tool handles shared components, licences and
/// delta updates that a plain replace would miss.
public enum VendorUpdaters {
    struct Known {
        let name: String
        let shortName: String
        let paths: [String]
        let applies: @Sendable (InstalledApp) -> Bool
    }

    /// Office, Teams and Defender update through AutoUpdate; VS Code and Edge have their own.
    static let microsoftApps: Set<String> = [
        "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.microsoft.Outlook",
        "com.microsoft.onenote.mac", "com.microsoft.teams", "com.microsoft.teams2", "com.microsoft.wdav",
        "com.microsoft.CompanyPortalMac",
    ]

    static let known: [Known] = [
        Known(name: "Microsoft AutoUpdate", shortName: "AutoUpdate",
              paths: ["/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app"],
              applies: { microsoftApps.contains($0.bundleID) }),
        Known(name: "Adobe Creative Cloud", shortName: "Creative Cloud",
              paths: ["/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app"],
              applies: { $0.bundleID.hasPrefix("com.adobe.") && !$0.bundleID.hasPrefix("com.adobe.acc")
                  && !$0.bundleID.hasPrefix("com.adobe.Reader") }),
        Known(name: "Setapp", shortName: "Setapp",
              paths: ["/Applications/Setapp.app"],
              applies: { $0.url.path.contains("/Applications/Setapp/") }),
        Known(name: "JetBrains Toolbox", shortName: "Toolbox",
              paths: ["/Applications/JetBrains Toolbox.app", "~/Applications/JetBrains Toolbox.app"],
              applies: { $0.bundleID.hasPrefix("com.jetbrains.") && $0.bundleID != "com.jetbrains.toolbox" }),
    ]

    /// The vendor updater for this app, when it's installed.
    public static func updater(for app: InstalledApp,
                               fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> VendorUpdater? {
        guard !app.isAppStore else { return nil }
        for vendor in known where vendor.applies(app) {
            let paths = vendor.paths.map { ($0 as NSString).expandingTildeInPath }
            if let path = paths.first(where: fileExists) {
                return VendorUpdater(name: vendor.name, shortName: vendor.shortName, path: path)
            }
        }
        return nil
    }
}
