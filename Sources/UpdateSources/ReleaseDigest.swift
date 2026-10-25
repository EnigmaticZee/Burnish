import Foundation

/// A quick read of a developer's release notes, made by plain rules: each line is sorted into a
/// new thing, a fix, an improvement or a security fix by its section heading or its own words.
/// Lines that fit none are left for the full notes. Nothing is invented, so the summary can
/// only ever repeat what the developer wrote.
public struct ReleaseDigest: Sendable, Hashable {
    public enum Kind: Int, Sendable, CaseIterable, Comparable {
        case security, new, fix, improvement

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Highlight: Sendable, Hashable {
        public let kind: Kind
        public let text: String
    }

    public let counts: [Kind: Int]
    /// The first line of each kind, security first, at most three.
    public let highlights: [Highlight]

    public var total: Int { counts.values.reduce(0, +) }

    /// "1 security fix, 2 shiny new things and 6 squashed bugs".
    public var headline: String {
        let parts = Kind.allCases.compactMap { kind -> String? in
            guard let n = counts[kind], n > 0 else { return nil }
            switch kind {
            case .security: return String(localized: "\(n) security fixes")
            case .new: return String(localized: "\(n) shiny new things")
            case .fix: return String(localized: "\(n) squashed bugs")
            case .improvement: return String(localized: "\(n) improvements")
            }
        }
        return ListFormatter.localizedString(byJoining: parts)
    }

    /// Nil when fewer than two lines could be sorted: then a summary would say nothing.
    public static func make(_ document: ReleaseNotesDocument) -> ReleaseDigest? {
        var lines: [(Kind, String)] = []
        var section: Kind?
        let hasList = document.blocks.contains { if case .listItem = $0 { true } else { false } }
        for block in document.blocks {
            switch block {
            case let .heading(_, runs):
                section = kind(ofHeading: text(runs))
            case let .listItem(_, depth, runs) where depth == 0:
                let line = text(runs)
                if let kind = kind(of: line) ?? section { lines.append((kind, line)) }
            case let .paragraph(runs) where !hasList:
                for sentence in sentences(text(runs)) {
                    if let kind = kind(of: sentence) ?? section { lines.append((kind, sentence)) }
                }
            default:
                continue
            }
        }
        guard lines.count >= 2 else { return nil }
        var counts: [Kind: Int] = [:]
        for (kind, _) in lines { counts[kind, default: 0] += 1 }
        var highlights: [Highlight] = []
        for kind in Kind.allCases {
            if let first = lines.first(where: { $0.0 == kind }) { highlights.append(Highlight(kind: kind, text: shortened(first.1))) }
        }
        return ReleaseDigest(counts: counts, highlights: Array(highlights.prefix(3)))
    }

    // MARK: Sorting rules

    static let securityWords = #"\b(security|vulnerab\w*|cve-\d+|exploit\w*)\b"#
    static let fixWords = #"\b(fix(es|ed)?|bugs?|crash\w*|resolv\w*|issues?|problems?|no longer|correct(ed|s)?|prevent\w*|hang\w*|freez\w*)\b"#
    static let newWords = #"\b(new|add(ed|s)?|introduc\w*|you can now|now supports?|support for)\b"#
    static let improvementWords = #"\b(improv\w*|faster|better|performance|speed\w*|optimi[sz]\w*|enhanc\w*|refin\w*|polish\w*|reduc\w*|smoother)\b"#

    static func kind(of line: String) -> Kind? {
        if matches(line, securityWords) { return .security }
        if matches(line, fixWords) { return .fix }
        if matches(line, newWords) { return .new }
        if matches(line, improvementWords) { return .improvement }
        return nil
    }

    static func kind(ofHeading heading: String) -> Kind? {
        let h = heading.lowercased()
        if h.contains("security") { return .security }
        if h.contains("fix") || h.contains("bug") { return .fix }
        if h.contains("new") || h.contains("added") || h.contains("feature") { return .new }
        if h.contains("improve") || h.contains("change") || h.contains("enhance") { return .improvement }
        return nil
    }

    static func matches(_ line: String, _ pattern: String) -> Bool {
        line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func text(_ runs: [ReleaseNotesDocument.Inline]) -> String {
        runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sentences(_ paragraph: String) -> [String] {
        paragraph.components(separatedBy: ". ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count > 3 }
    }

    /// One line, at a word boundary.
    static func shortened(_ line: String, limit: Int = 100) -> String {
        guard line.count > limit else { return line }
        let cut = line.prefix(limit)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }
}
