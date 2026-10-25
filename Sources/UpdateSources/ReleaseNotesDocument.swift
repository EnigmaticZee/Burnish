import Foundation

/// Release notes reduced to a few safe building blocks. HTML from feeds is never handed to a
/// web view: scripts, styles, images, frames and remote resources are dropped, and only
/// http(s) links survive. The UI renders these blocks with plain SwiftUI text.
public struct ReleaseNotesDocument: Sendable, Hashable {
    public struct Inline: Sendable, Hashable {
        public var text: String
        public var bold = false
        public var italic = false
        public var code = false
        public var link: URL?

        public init(text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, link: URL? = nil) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.code = code
            self.link = link
        }
    }

    public enum Block: Sendable, Hashable {
        case heading(level: Int, [Inline])
        case paragraph([Inline])
        /// `ordered` is the item number in a numbered list.
        case listItem(ordered: Int?, depth: Int, [Inline])
        case code(String)
        case rule
    }

    public var blocks: [Block]

    public init(blocks: [Block]) { self.blocks = blocks }

    public static func from(_ notes: ReleaseNotes) -> ReleaseNotesDocument? {
        guard let text = notes.text else { return nil }
        switch notes.format {
        case .html: return html(text)
        case .markdown: return markdown(text)
        case .plainText: return plainText(text)
        }
    }

    public var isEmpty: Bool { blocks.isEmpty }

    /// Text only, for tests.
    public var plainText: String {
        blocks.map { block -> String in
            switch block {
            case let .heading(_, runs), let .paragraph(runs): runs.map(\.text).joined()
            case let .listItem(ordered, depth, runs):
                String(repeating: "  ", count: depth) + (ordered.map { "\($0). " } ?? "• ") + runs.map(\.text).joined()
            case let .code(text): text
            case .rule: "—"
            }
        }.joined(separator: "\n")
    }

    // MARK: Plain text (App Store)

    public static func plainText(_ text: String) -> ReleaseNotesDocument {
        var blocks: [Block] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let first = line.first, ["•", "-", "*", "–", "·"].contains(first), line.count > 1 {
                let rest = line.dropFirst().trimmingCharacters(in: .whitespaces)
                blocks.append(.listItem(ordered: nil, depth: 0, [Inline(text: rest)]))
            } else {
                blocks.append(.paragraph([Inline(text: line)]))
            }
        }
        return ReleaseNotesDocument(blocks: blocks)
    }

    // MARK: Markdown (GitHub, Electron)

    public static func markdown(_ text: String) -> ReleaseNotesDocument {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var fence: [String]?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(inlineMarkdown(paragraph.joined(separator: " "))))
            paragraph = []
        }

        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = fence {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    flushParagraph()
                    fence = []
                }
                continue
            }
            if fence != nil { fence!.append(raw); continue }
            if line.isEmpty { flushParagraph(); continue }
            if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) && line.count >= 3 {
                flushParagraph()
                blocks.append(.rule)
                continue
            }
            if line.hasPrefix("#") {
                flushParagraph()
                let level = min(line.prefix { $0 == "#" }.count, 6)
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { blocks.append(.heading(level: level, inlineMarkdown(title))) }
                continue
            }
            let depth = raw.prefix { $0 == " " }.count / 2
            if let marker = line.first, "-*+".contains(marker), line.dropFirst().first == " " {
                flushParagraph()
                blocks.append(.listItem(ordered: nil, depth: depth, inlineMarkdown(String(line.dropFirst(2)))))
                continue
            }
            if let dot = line.firstIndex(of: "."), let number = Int(line[..<dot]), line[line.index(after: dot)...].hasPrefix(" ") {
                flushParagraph()
                blocks.append(.listItem(ordered: number, depth: depth, inlineMarkdown(String(line[line.index(dot, offsetBy: 2)...]))))
                continue
            }
            paragraph.append(line.hasPrefix(">") ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : line)
        }
        if let lines = fence { blocks.append(.code(lines.joined(separator: "\n"))) }
        flushParagraph()
        return ReleaseNotesDocument(blocks: blocks)
    }

    static func inlineMarkdown(_ text: String) -> [Inline] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let attributed = try? AttributedString(markdown: text, options: options) else { return [Inline(text: text)] }
        return attributed.runs.map { run in
            let intent = run.inlinePresentationIntent ?? []
            return Inline(
                text: String(attributed[run.range].characters),
                bold: intent.contains(.stronglyEmphasized),
                italic: intent.contains(.emphasized),
                code: intent.contains(.code),
                link: run.link.flatMap(safeLink)
            )
        }
    }

    static func safeLink(_ url: URL) -> URL? {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? url : nil
    }

    // MARK: HTML (Sparkle)

    static let droppedElements: Set<String> = [
        "script", "style", "iframe", "object", "embed", "svg", "video", "audio", "noscript", "template",
        "head", "title", "form", "select", "textarea", "button", "canvas", "math", "frame", "frameset",
    ]
    static let blockElements: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "main", "aside", "blockquote", "tr",
        "table", "dl", "dt", "dd", "figure", "figcaption", "center", "body", "html", "details", "summary",
    ]

    public static func html(_ html: String) -> ReleaseNotesDocument {
        var builder = HTMLBuilder()
        let chars = Array(html)
        var i = 0
        var dropping: String?

        while i < chars.count {
            if chars[i] == "<" {
                // Comments and doctype.
                if matches(chars, at: i, "<!--") {
                    i = find(chars, "-->", from: i + 4).map { $0 + 3 } ?? chars.count
                    continue
                }
                guard let end = tagEnd(chars, from: i) else {
                    builder.text(String(chars[i...]))
                    break
                }
                let tag = Tag(String(chars[(i + 1)..<end]))
                i = end + 1
                guard let tag else { continue }
                if let d = dropping {
                    if tag.closing && tag.name == d { dropping = nil }
                    continue
                }
                if droppedElements.contains(tag.name) {
                    if !tag.closing && !tag.selfClosing { dropping = tag.name }
                    continue
                }
                builder.handle(tag)
            } else {
                let start = i
                while i < chars.count && chars[i] != "<" { i += 1 }
                if dropping == nil { builder.text(decodeEntities(String(chars[start..<i]))) }
            }
        }
        builder.flush()
        return ReleaseNotesDocument(blocks: builder.blocks)
    }

    struct Tag {
        let name: String
        let closing: Bool
        let selfClosing: Bool
        let attributes: [String: String]

        init?(_ raw: String) {
            var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasPrefix("!") || body.hasPrefix("?") { return nil }
            closing = body.hasPrefix("/")
            if closing { body.removeFirst() }
            selfClosing = body.hasSuffix("/")
            if selfClosing { body.removeLast() }
            let nameEnd = body.firstIndex { $0.isWhitespace } ?? body.endIndex
            let tagName = body[..<nameEnd].lowercased()
            guard !tagName.isEmpty, tagName.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
            name = tagName
            attributes = Tag.parseAttributes(String(body[nameEnd...]))
        }

        static func parseAttributes(_ s: String) -> [String: String] {
            var out: [String: String] = [:]
            let chars = Array(s)
            var i = 0
            while i < chars.count {
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                let keyStart = i
                while i < chars.count, !chars[i].isWhitespace, chars[i] != "=" { i += 1 }
                let key = String(chars[keyStart..<i]).lowercased()
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                var value = ""
                if i < chars.count, chars[i] == "=" {
                    i += 1
                    while i < chars.count, chars[i].isWhitespace { i += 1 }
                    if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                        let quote = chars[i]
                        i += 1
                        let start = i
                        while i < chars.count, chars[i] != quote { i += 1 }
                        value = String(chars[start..<min(i, chars.count)])
                        i += 1
                    } else {
                        let start = i
                        while i < chars.count, !chars[i].isWhitespace { i += 1 }
                        value = String(chars[start..<i])
                    }
                }
                if !key.isEmpty { out[key] = decodeEntities(value) }
                if i == keyStart { i += 1 }
            }
            return out
        }
    }

    struct HTMLBuilder {
        var blocks: [Block] = []
        var runs: [Inline] = []
        var bold = 0, italic = 0, code = 0
        var links: [URL?] = []
        var heading: Int?
        var lists: [(ordered: Bool, counter: Int)] = []
        var inItem: (ordered: Int?, depth: Int)?
        var pre: String?

        mutating func text(_ s: String) {
            if pre != nil { pre! += s; return }
            var collapsed = ""
            var lastWasSpace = runs.last?.text.last.map { $0 == " " || $0 == "\n" } ?? true
            for ch in s {
                if ch.isWhitespace {
                    if !lastWasSpace { collapsed.append(" ") }
                    lastWasSpace = true
                } else {
                    collapsed.append(ch)
                    lastWasSpace = false
                }
            }
            guard !collapsed.isEmpty else { return }
            let run = Inline(text: collapsed, bold: bold > 0 || heading != nil, italic: italic > 0, code: code > 0, link: links.last ?? nil)
            if var last = runs.last, last.bold == run.bold, last.italic == run.italic, last.code == run.code, last.link == run.link {
                last.text += run.text
                runs[runs.count - 1] = last
            } else {
                runs.append(run)
            }
        }

        mutating func flush() {
            var trimmed = runs
            while let first = trimmed.first, first.text.allSatisfy(\.isWhitespace) { trimmed.removeFirst() }
            while let last = trimmed.last, last.text.allSatisfy(\.isWhitespace) { trimmed.removeLast() }
            if !trimmed.isEmpty {
                trimmed[0].text = String(trimmed[0].text.drop { $0 == " " })
                let lastIndex = trimmed.count - 1
                while trimmed[lastIndex].text.last == " " || trimmed[lastIndex].text.last == "\n" { trimmed[lastIndex].text.removeLast() }
                if let level = heading {
                    blocks.append(.heading(level: level, trimmed.map { var r = $0; r.bold = false; return r }))
                } else if let item = inItem {
                    blocks.append(.listItem(ordered: item.ordered, depth: item.depth, trimmed))
                } else {
                    blocks.append(.paragraph(trimmed))
                }
            }
            runs = []
        }

        mutating func handle(_ tag: Tag) {
            let name = tag.name
            switch name {
            case "b", "strong": bold += tag.closing ? (bold > 0 ? -1 : 0) : 1
            case "i", "em": italic += tag.closing ? (italic > 0 ? -1 : 0) : 1
            case "code", "tt", "kbd", "samp": code += tag.closing ? (code > 0 ? -1 : 0) : 1
            case "a":
                if tag.closing {
                    if !links.isEmpty { links.removeLast() }
                } else {
                    links.append(tag.attributes["href"].flatMap(URL.init(string:)).flatMap(ReleaseNotesDocument.safeLink))
                }
            case "br":
                if pre != nil { pre! += "\n" } else if !runs.isEmpty { flush() }
            case "hr":
                flush()
                blocks.append(.rule)
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                heading = tag.closing ? nil : Int(String(name.last!))
            case "ul", "ol":
                flush()
                inItem = nil
                if tag.closing { if !lists.isEmpty { lists.removeLast() } } else { lists.append((name == "ol", 0)) }
            case "li":
                flush()
                if tag.closing {
                    inItem = nil
                } else {
                    let depth = max(lists.count - 1, 0)
                    var number: Int?
                    if !lists.isEmpty, lists[lists.count - 1].ordered {
                        lists[lists.count - 1].counter += 1
                        number = lists[lists.count - 1].counter
                    }
                    inItem = (number, depth)
                }
            case "pre":
                flush()
                if tag.closing {
                    if let text = pre?.trimmingCharacters(in: .newlines), !text.isEmpty { blocks.append(.code(text)) }
                    pre = nil
                } else {
                    pre = ""
                }
            case "td", "th":
                text(" ")
            case "img":
                if let alt = tag.attributes["alt"], !alt.isEmpty { text(alt) }
            default:
                if ReleaseNotesDocument.blockElements.contains(name) { flush() }
            }
        }
    }

    static func matches(_ chars: [Character], at i: Int, _ s: String) -> Bool {
        let target = Array(s)
        guard i + target.count <= chars.count else { return false }
        return Array(chars[i..<(i + target.count)]) == target
    }

    static func find(_ chars: [Character], _ s: String, from: Int) -> Int? {
        var i = from
        while i < chars.count {
            if matches(chars, at: i, s) { return i }
            i += 1
        }
        return nil
    }

    /// The `>` that ends a tag, skipping any inside quoted attribute values.
    static func tagEnd(_ chars: [Character], from start: Int) -> Int? {
        var quote: Character?
        var i = start + 1
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ">" {
                return i
            } else if c == "<" {
                return nil
            }
            i += 1
        }
        return nil
    }

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—",
        "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·",
        "copy": "©", "reg": "®", "trade": "™", "rarr": "→", "larr": "←", "times": "×", "deg": "°",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                var decoded: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if name.hasPrefix("#") {
                    decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    decoded = namedEntities[name]
                }
                if let decoded {
                    out += decoded
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}
