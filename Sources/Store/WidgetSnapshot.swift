import Foundation

/// What the desktop widget shows, written by the app after every check. The widget is sandboxed,
/// so it reads this one small file from Burnish's folder instead of the whole report.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public var id: String { appPath }
        public var name: String
        public var installed: String
        public var latest: String
        public var appPath: String

        public init(name: String, installed: String, latest: String, appPath: String) {
            self.name = name
            self.installed = installed
            self.latest = latest
            self.appPath = appPath
        }
    }

    public var updateCount: Int
    /// The first three updates, in the order the popover lists them.
    public var top: [Item]
    public var lastCheck: Date?

    public init(updateCount: Int, top: [Item], lastCheck: Date?) {
        self.updateCount = updateCount
        self.top = Array(top.prefix(3))
        self.lastCheck = lastCheck
    }

    public static let fileName = "widget.json"

    /// Burnish's folder in the real home folder. Inside the sandbox `NSHomeDirectory()` is the
    /// widget's container, so this asks the user database instead.
    public static var directory: URL {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Burnish", isDirectory: true)
    }

    public static func load(from directory: URL = directory) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    public func save(to directory: URL = directory) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
