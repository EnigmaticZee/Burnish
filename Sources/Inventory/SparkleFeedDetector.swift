import Foundation

/// Some Sparkle apps hand their feed address to Sparkle in code instead of Info.plist, so the
/// plist says nothing while the address sits in the executable, inside the same code-signed
/// bundle. This reads it out, the way `TauriDetector` reads a Tauri app's updater. The result is
/// only a lead: the checker asks the feed and keeps it only if it plainly belongs to the app.
public enum SparkleFeedDetector {
    /// Past this many leads the binary is probably a framework host or a browser, not worth guessing.
    static let maximumCandidates = 4

    /// Addresses in the executable that look like an appcast, best first.
    public static func candidateFeeds(executable: URL) -> [String] {
        guard let binary = BinaryStrings.mapped(executable) else { return [] }
        return candidates(in: binary)
    }

    static func candidates(in binary: Data) -> [String] {
        let found = BinaryStrings.httpsURLs(in: binary).filter(looksLikeAppcast)
        let ranked = found.map { ($0, rank($0)) }.sorted { $0.1 < $1.1 }
        return ranked.prefix(maximumCandidates).map(\.0)
    }

    /// The usual false friends: Sparkle's XML namespace, schema URLs, Apple's own hosts, format strings.
    private static let excluded = ["andymatuschak.org", "sparkle-project.org", "w3.org", "schemas.", "apple.com", "github.com/sparkle-project",
                                   "xmlns", "%@", "%s", "{{", "}}", "$(", "localhost"]

    /// An HTTPS address with a path that smells of an appcast, and none of the `excluded` false friends.
    static func looksLikeAppcast(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard let url = URL(string: text), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.path.count > 1 else { return false }
        guard !excluded.contains(where: lower.contains) else { return false }
        let path = url.path.lowercased()
        let file = (path as NSString).lastPathComponent
        return lower.contains("appcast") || lower.contains("sparkle")
            || file.hasSuffix(".xml") || file.hasSuffix(".rss")
            || path.split(separator: "/").contains { $0.contains("update") }
    }

    static func rank(_ text: String) -> Int {
        let lower = text.lowercased()
        if lower.contains("appcast") { return 0 }
        if lower.hasSuffix(".xml") || lower.hasSuffix(".rss") { return 1 }
        if lower.contains("sparkle") { return 2 }
        return 3
    }
}

/// Printable `https://` addresses inside a binary, in order of appearance, without repeats,
/// and the reads that feed them.
enum BinaryStrings {
    /// Executables above this size are left alone: no Sparkle or Tauri app comes close.
    static let maximumSize = 200 * 1024 * 1024

    /// Printable ASCII that can't be part of an address: quotes, brackets, a backslash.
    private static let stopBytes = Set("\"'\\<>`".utf8)

    /// The first `bytes` of a file; empty when it can't be opened.
    static func head(of file: URL, bytes: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: bytes)) ?? Data()
    }

    /// The whole file, memory-mapped, unless it is larger than `maximumSize`.
    static func mapped(_ file: URL) -> Data? {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maximumSize else { return nil }
        return try? Data(contentsOf: file, options: .alwaysMapped)
    }

    static func httpsURLs(in binary: Data, maximumLength: Int = 512) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        let urlBytes: (UInt8) -> Bool = { byte in byte > 0x20 && byte < 0x7F && !stopBytes.contains(byte) }
        binary.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let needle = Array("https://".utf8)
            var offset = 0
            while offset < raw.count,
                  let hit = memmem(base + offset, raw.count - offset, needle, needle.count) {
                let start = base.distance(to: hit)
                var end = start
                while end < raw.count, end - start < maximumLength, urlBytes(raw[end]) { end += 1 }
                if let text = String(bytes: raw[start..<end], encoding: .ascii), seen.insert(text).inserted {
                    found.append(text)
                }
                offset = max(end, start + needle.count)
            }
        }
        return found
    }

    static func contains(_ data: Data, _ text: String) -> Bool {
        let needle = Array(text.utf8)
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            return memmem(base, raw.count, needle, needle.count) != nil
        }
    }
}
