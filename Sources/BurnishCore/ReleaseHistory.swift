import Foundation

/// Burnish's own release notes, read from the copy of docs/HISTORY.md inside the app, so What's
/// New opens on the Mac instead of a web page. Reads the same shape the release scripts do: a
/// "## version — date" heading, a one-line headline, "+ " lines for the short version, "- " items
/// and closing paragraphs, with wrapped lines indented by two spaces.
public struct ReleaseHistory: Sendable {
    public struct Entry: Sendable, Hashable, Identifiable {
        public var id: String { version }
        public var version: String
        public var date: String
        public var headline = ""
        public var short: [String] = []
        public var items: [String] = []
        public var paragraphs: [String] = []
    }

    public let entries: [Entry]

    public init(markdown: String) {
        enum Part { case none, short, item, paragraph }
        var entries: [Entry] = []
        var entry: Entry?
        var part = Part.none

        for line in markdown.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                if let entry { entries.append(entry) }
                let heading = line.dropFirst(3).components(separatedBy: " — ")
                entry = Entry(version: heading[0].trimmingCharacters(in: .whitespaces),
                              date: heading.dropFirst().joined(separator: " — ").trimmingCharacters(in: .whitespaces))
                part = .none
                continue
            }
            guard var current = entry else { continue }
            if text.isEmpty {
                part = .none
            } else if line.hasPrefix("+ ") {
                current.short.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                part = .short
            } else if line.hasPrefix("- ") {
                current.items.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                part = .item
            } else if line.hasPrefix("  "), part == .short {
                current.short[current.short.count - 1] += " " + text
            } else if line.hasPrefix("  "), part == .item {
                current.items[current.items.count - 1] += " " + text
            } else if part == .paragraph {
                current.paragraphs[current.paragraphs.count - 1] += " " + text
            } else if current.headline.isEmpty, current.short.isEmpty, current.items.isEmpty, current.paragraphs.isEmpty {
                current.headline = text
            } else {
                current.paragraphs.append(text)
                part = .paragraph
            }
            entry = current
        }
        if let entry { entries.append(entry) }
        self.entries = entries
    }

    /// The entry for `version`, or the newest one when this copy's version isn't listed.
    public func entry(for version: String) -> Entry? {
        entries.first { $0.version == version } ?? entries.first
    }

    /// The notes bundled with the app, if this copy has them.
    public static func bundled(in bundle: Bundle = .main) -> ReleaseHistory? {
        guard let url = bundle.url(forResource: "HISTORY", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return ReleaseHistory(markdown: text)
    }
}
