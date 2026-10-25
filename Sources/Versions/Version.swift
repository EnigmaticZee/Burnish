/// A version string broken into comparable parts.
///
/// Rules:
/// - Dotted numbers compare part by part as integers; missing parts count as zero, so `1.2 == 1.2.0`.
/// - Letters and pre-release tags sort below the release they precede: `1.2b4 < 1.2 < 1.2.1`.
/// - Known pre-release tags rank `dev < alpha < beta < rc`; other words compare alphabetically.
/// - Strings Burnish can't read (`latest`, empty, no leading number, odd characters) don't parse at all.
public struct Version: Sendable, Comparable, Hashable, CustomStringConvertible {
    public enum Component: Sendable, Hashable {
        /// Digits with leading zeros removed ("0" for zero), so numbers of any size compare exactly.
        case number(String)
        /// A lowercased word; `rank` is set for known pre-release tags.
        case word(String, rank: Int?)
    }

    public let raw: String
    public let components: [Component]

    public init?(_ string: String) {
        let trimmed = string.trimmingWhitespace()
        guard !trimmed.isEmpty, trimmed.count <= 100 else { return nil }
        guard let parts = Version.tokenize(Version.stripPrefix(trimmed)) else { return nil }
        guard case .number = parts.first else { return nil }
        raw = trimmed
        components = parts
    }

    init(raw: String, components: [Component]) {
        self.raw = raw
        self.components = components
    }

    public var description: String { raw }

    /// The parts after the first `count`: `2.20.2.2629` dropping 3 → `2629`.
    public func dropping(_ count: Int) -> Version? {
        let rest = Array(components.dropFirst(count))
        guard case .number = rest.first else { return nil }
        return Version(raw: Self.render(rest), components: rest)
    }

    /// True when `other`'s parts start with all of this version's parts.
    public func isPrefix(of other: Version) -> Bool {
        other.components.count > components.count && Array(other.components.prefix(components.count)) == components
    }

    static func render(_ parts: [Component]) -> String {
        parts.map { part -> String in
            switch part {
            case let .number(n): n
            case let .word(w, _): w
            }
        }.joined(separator: ".")
    }

    /// `155.1.97.57` → `1.97.57`. Nil when nothing numeric would remain.
    public func droppingFirstComponent() -> Version? {
        let rest = Array(components.dropFirst())
        guard case .number = rest.first else { return nil }
        let raw = rest.map { part -> String in
            switch part {
            case let .number(n): n
            case let .word(w, _): w
            }
        }.joined(separator: ".")
        return Version(raw: raw, components: rest)
    }

    /// The first number, for shape checks. `Double` so huge date-like numbers don't overflow.
    public var leadingNumber: Double? {
        guard case let .number(digits) = components.first else { return nil }
        return Double(digits)
    }

    /// The first number as an `Int`, when it fits.
    public var major: Int? {
        guard case let .number(digits) = components.first, digits.count <= 18 else { return nil }
        return Int(digits)
    }

    /// True when the version carries any word, such as `b4` or `-rc1`.
    public var isPrerelease: Bool {
        components.contains { if case .word = $0 { return true } else { return false } }
    }

    /// True when every part is a number, like `1.2.3` or `8059`.
    public var isPlainNumeric: Bool { !isPrerelease }

    // MARK: Comparison

    public static func < (lhs: Version, rhs: Version) -> Bool { compare(lhs, rhs) < 0 }
    public static func == (lhs: Version, rhs: Version) -> Bool { compare(lhs, rhs) == 0 }

    public func hash(into hasher: inout Hasher) {
        var parts = components
        while case .number("0") = parts.last { parts.removeLast() }
        for part in parts {
            switch part {
            case let .number(n): hasher.combine(0); hasher.combine(n)
            case let .word(w, rank): hasher.combine(1); if let rank { hasher.combine(rank) } else { hasher.combine(w) }
            }
        }
    }

    /// Returns -1, 0 or 1.
    static func compare(_ lhs: Version, _ rhs: Version) -> Int {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let l = index < lhs.components.count ? lhs.components[index] : nil
            let r = index < rhs.components.count ? rhs.components[index] : nil
            let result = compareComponent(l, r)
            if result != 0 { return result }
        }
        return 0
    }

    /// `nil` means the version has ended. An ended version equals trailing zeros
    /// and beats any trailing word (a release beats its own pre-releases).
    private static func compareComponent(_ l: Component?, _ r: Component?) -> Int {
        switch (l, r) {
        case (nil, nil):
            return 0
        case let (nil, .number(n)?):
            return n == "0" ? 0 : -1
        case let (.number(n)?, nil):
            return n == "0" ? 0 : 1
        case (nil, .word?):
            return 1
        case (.word?, nil):
            return -1
        case (.number?, .word?):
            return 1
        case (.word?, .number?):
            return -1
        case let (.number(a)?, .number(b)?):
            if a.count != b.count { return a.count < b.count ? -1 : 1 }
            return a == b ? 0 : (a < b ? -1 : 1)
        case let (.word(a, rankA)?, .word(b, rankB)?):
            if let rankA, let rankB { return rankA == rankB ? 0 : (rankA < rankB ? -1 : 1) }
            return a == b ? 0 : (a < b ? -1 : 1)
        }
    }

    // MARK: Parsing

    /// Pre-release tags and their order. A release (no tag) beats all of them.
    static let prereleaseRanks: [String: Int] = [
        "dev": 0, "devel": 0, "develop": 0, "development": 0, "nightly": 0, "canary": 0,
        "snapshot": 0, "internal": 0, "test": 0,
        "a": 1, "alpha": 1,
        "b": 2, "beta": 2, "eap": 2, "ea": 2, "pre": 2, "preview": 2, "prerelease": 2,
        "rc": 3, "cr": 3, "candidate": 3,
    ]

    /// Words that mark a release or a patch and carry no ordering of their own.
    /// They act as separators: `6000.6.7f1` reads as `6000.6.7.1`.
    static let neutralWords: Set<String> = [
        "build", "r", "rev", "revision", "release", "final", "stable", "ga", "lts", "esr",
        "f", "p", "patch", "u", "update", "hotfix", "fix", "sp", "pl", "hf", "latest", "version", "ver", "v",
    ]

    private static func stripPrefix(_ string: String) -> Substring {
        var s = Substring(string)
        let lower = s.lowercased()
        if lower.hasPrefix("version ") {
            s = s.dropFirst("version ".count)
        } else if lower.hasPrefix("v"), let next = s.dropFirst().first, next.isASCIIDigit {
            s = s.dropFirst()
        }
        return s
    }

    private static func tokenize(_ string: Substring) -> [Component]? {
        var parts: [Component] = []
        var digits = ""
        var letters = ""

        func flushDigits() {
            guard !digits.isEmpty else { return }
            let stripped = digits.drop { $0 == "0" }
            parts.append(.number(stripped.isEmpty ? "0" : String(stripped)))
            digits = ""
        }
        func flushLetters() {
            guard !letters.isEmpty else { return }
            let word = letters.lowercased()
            letters = ""
            if neutralWords.contains(word) { return }
            parts.append(.word(word, rank: prereleaseRanks[word]))
        }

        for char in string {
            if char.isASCIIDigit {
                flushLetters()
                digits.append(char)
            } else if char.isASCIILetter {
                flushDigits()
                letters.append(char)
            } else if separators.contains(char) {
                flushDigits()
                flushLetters()
            } else {
                return nil
            }
        }
        flushDigits()
        flushLetters()
        return parts.isEmpty ? nil : parts
    }

    private static let separators: Set<Character> = [".", "-", "_", "+", "~", " "]
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
}

extension String {
    func trimmingWhitespace() -> String {
        var s = Substring(self)
        while let first = s.first, first.isWhitespace { s = s.dropFirst() }
        while let last = s.last, last.isWhitespace { s = s.dropLast() }
        return String(s)
    }
}
