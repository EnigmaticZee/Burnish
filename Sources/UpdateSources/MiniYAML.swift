/// Just enough YAML for electron-builder's `app-update.yml` and `latest-mac.yml`:
/// `key: value`, quoted strings, `|` and `>` block scalars, and lists of flat maps.
/// Burnish ships no YAML dependency, and these files never use more than this.
public enum YAMLValue: Sendable, Hashable {
    case string(String)
    case list([[String: String]])

    public var string: String? { if case let .string(s) = self { s } else { nil } }
    public var list: [[String: String]]? { if case let .list(l) = self { l } else { nil } }
}

public enum MiniYAML {
    public static func parse(_ text: String) -> [String: YAMLValue] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String: YAMLValue] = [:]
        var index = 0

        func indent(of line: String) -> Int { line.prefix { $0 == " " }.count }
        func isBlank(_ line: String) -> Bool {
            let t = line.trimmed
            return t.isEmpty || t.hasPrefix("#")
        }

        while index < lines.count {
            let line = lines[index]
            guard !isBlank(line), indent(of: line) == 0, let (key, rest) = splitKey(line) else { index += 1; continue }
            index += 1

            if rest == "|" || rest == ">" || rest.hasPrefix("|") || rest.hasPrefix(">") {
                var block: [String] = []
                var blockIndent: Int?
                while index < lines.count {
                    let l = lines[index]
                    if l.trimmed.isEmpty { block.append(""); index += 1; continue }
                    let i = indent(of: l)
                    if i == 0 { break }
                    if blockIndent == nil { blockIndent = i }
                    block.append(String(l.dropFirst(min(i, blockIndent!))))
                    index += 1
                }
                while block.last == "" { block.removeLast() }
                result[key] = .string(rest.hasPrefix(">") ? block.joined(separator: " ") : block.joined(separator: "\n"))
            } else if rest.isEmpty {
                // A list of maps (`- url: …`) or of plain strings (`- text`).
                var items: [[String: String]] = []
                while index < lines.count {
                    let l = lines[index]
                    if isBlank(l) { index += 1; continue }
                    if indent(of: l) == 0 { break }
                    let t = l.trimmed
                    if t.hasPrefix("- ") || t == "-" {
                        let body = String(t.dropFirst(min(2, t.count)))
                        if let (k, v) = splitKey(body) {
                            items.append([k: unquote(v)])
                        } else {
                            items.append(["": unquote(body)])
                        }
                    } else if let (k, v) = splitKey(t), !items.isEmpty {
                        items[items.count - 1][k] = unquote(v)
                    }
                    index += 1
                }
                result[key] = .list(items)
            } else {
                result[key] = .string(unquote(rest))
            }
        }
        return result
    }

    /// `key: value` → ("key", "value"); a colon inside a URL value is kept.
    static func splitKey(_ line: String) -> (String, String)? {
        let trimmed = line.trimmed
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let key = String(trimmed[..<colon]).trimmed
        guard !key.isEmpty, !key.contains(" ") || key.hasPrefix("\"") else { return nil }
        let after = trimmed.index(after: colon)
        if after < trimmed.endIndex, trimmed[after] != " " { return nil }
        var value = String(trimmed[after...]).trimmed
        if !value.hasPrefix("\"") && !value.hasPrefix("'"), let hash = value.range(of: " #") {
            value = String(value[..<hash.lowerBound]).trimmed
        }
        return (unquote(key), value)
    }

    static func unquote(_ value: String) -> String {
        let v = value.trimmed
        if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            return String(v.dropFirst().dropLast())
        }
        return v
    }
}

extension String {
    var trimmed: String {
        var s = Substring(self)
        while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() }
        while let l = s.last, l == " " || l == "\t" { s = s.dropLast() }
        return String(s)
    }
}
