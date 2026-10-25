import Foundation

/// One `<item>` of a Sparkle appcast.
public struct AppcastItem: Sendable, Hashable {
    public var title: String?
    public var link: URL?
    public var pubDate: Date?
    /// `sparkle:version`: compared with `CFBundleVersion`.
    public var version: String?
    public var shortVersion: String?
    public var minimumSystemVersion: String?
    public var maximumSystemVersion: String?
    public var minimumAutoupdateVersion: String?
    public var channel: String?
    public var hardwareRequirements: [String] = []
    public var isCritical = false
    public var isInformational = false
    /// `<description>` HTML, keyed by `xml:lang` ("" for none).
    public var descriptions: [String: String] = [:]
    public var releaseNotesLinks: [String: URL] = [:]
    public var fullReleaseNotesLink: URL?
    public var enclosure: Enclosure?

    public struct Enclosure: Sendable, Hashable {
        public var url: URL?
        public var length: Int64?
        public var type: String?
        public var version: String?
        public var shortVersion: String?
        public var edSignature: String?
        public var os: String?
        public var installationType: String?
    }

    /// The build to compare, falling back the way Sparkle does.
    public var effectiveVersion: String? { version ?? enclosure?.version ?? shortVersion ?? enclosure?.shortVersion }
    public var effectiveShortVersion: String? { shortVersion ?? enclosure?.shortVersion }

    /// Picks the text for the user's language, then the unlabelled one, then any.
    public static func localized<T>(_ values: [String: T], language: String?) -> T? {
        if let language, let match = values.first(where: { $0.key.lowercased().hasPrefix(language.lowercased()) })?.value {
            return match
        }
        return values[""] ?? values.sorted { $0.key < $1.key }.first?.value
    }
}

/// Parses appcast XML, including old Sparkle 1 feeds that keep versions on the enclosure.
public final class AppcastParser: NSObject, XMLParserDelegate {
    static let sparkleNS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    static let xmlNS = "http://www.w3.org/XML/1998/namespace"

    private var items: [AppcastItem] = []
    private var current: AppcastItem?
    private var stack: [String] = []
    private var text = ""
    private var lang = ""
    private var failure: Error?

    public static func parse(_ data: Data) throws -> [AppcastItem] {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw delegate.failure ?? parser.parserError ?? CocoaError(.propertyListReadCorrupt)
        }
        return delegate.items
    }

    private func key(_ name: String, _ namespace: String?) -> String {
        namespace == Self.sparkleNS ? "sparkle:\(name)" : name
    }

    public func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes: [String: String] = [:]
    ) {
        let name = key(elementName, namespaceURI)
        stack.append(name)
        text = ""
        lang = attributes["xml:lang"] ?? attributes["lang"] ?? ""

        switch name {
        case "item":
            current = AppcastItem()
        case "enclosure" where current != nil && !stack.contains("sparkle:deltas"):
            func attr(_ local: String) -> String? {
                attributes["sparkle:\(local)"] ?? attributes[local]
            }
            current?.enclosure = AppcastItem.Enclosure(
                url: attributes["url"].flatMap(URL.init(string:)),
                length: attributes["length"].flatMap { Int64($0) },
                type: attributes["type"],
                version: attr("version"),
                shortVersion: attr("shortVersionString"),
                edSignature: attr("edSignature"),
                os: attr("os"),
                installationType: attr("installationType")
            )
        case "sparkle:criticalUpdate":
            current?.isCritical = true
        case "sparkle:informationalUpdate":
            current?.isInformational = true
        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = key(elementName, namespaceURI)
        defer { stack.removeLast(); text = "" }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only direct children of <item> describe the item (not those inside sparkle:informationalUpdate etc.).
        let parent = stack.dropLast().last
        guard current != nil else { return }
        if name == "item" {
            items.append(current!)
            current = nil
            return
        }
        guard parent == "item" else { return }
        switch name {
        case "title": current?.title = value.nilIfEmpty
        case "link": current?.link = URL(string: value)
        case "pubDate": current?.pubDate = Self.parseDate(value)
        case "description": if !value.isEmpty { current?.descriptions[lang] = value }
        case "sparkle:version": current?.version = value.nilIfEmpty
        case "sparkle:shortVersionString": current?.shortVersion = value.nilIfEmpty
        case "sparkle:minimumSystemVersion": current?.minimumSystemVersion = value.nilIfEmpty
        case "sparkle:maximumSystemVersion": current?.maximumSystemVersion = value.nilIfEmpty
        case "sparkle:minimumAutoupdateVersion": current?.minimumAutoupdateVersion = value.nilIfEmpty
        case "sparkle:channel": current?.channel = value.nilIfEmpty
        case "sparkle:hardwareRequirements":
            current?.hardwareRequirements = value.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        case "sparkle:releaseNotesLink": if let url = URL(string: value) { current?.releaseNotesLinks[lang] = url }
        case "sparkle:fullReleaseNotesLink": current?.fullReleaseNotesLink = URL(string: value)
        default: break
        }
    }

    public func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { failure = parseError }

    static func parseDate(_ string: String) -> Date? {
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return ISO8601DateFormatter().date(from: string)
    }
}
