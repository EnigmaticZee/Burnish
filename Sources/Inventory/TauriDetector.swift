import Foundation

/// Tauri apps compile their updater's address into the executable rather than Info.plist. A whole
/// binary is a lot to read, so only one that links WebKit (every Tauri app does) gets the full
/// read, and then only once it's clearly a Tauri app.
public enum TauriDetector {
    /// Larger executables are left alone: no Tauri app comes close.
    static let maximumSize = 200 * 1024 * 1024

    /// The updater endpoints, templates and all (`https://…/{{target}}/{{arch}}/{{current_version}}`).
    public static func updateEndpoints(executable: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: executable) else { return [] }
        let head = (try? handle.read(upToCount: 1024 * 1024)) ?? Data()
        try? handle.close()
        guard contains(head, "/WebKit.framework/"),
              let size = (try? executable.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maximumSize,
              let binary = try? Data(contentsOf: executable, options: .alwaysMapped),
              contains(binary, "tauri")
        else { return [] }
        return endpoints(in: binary)
    }

    /// URLs that look like an updater endpoint: a Tauri template variable, or a `latest.json`.
    static func endpoints(in binary: Data) -> [String] {
        var found: [String] = []
        let urlBytes: (UInt8) -> Bool = { byte in
            byte > 0x20 && byte < 0x7F && !"\"'\\<>`".utf8.contains(byte)
        }
        binary.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let needle = Array("https://".utf8)
            var offset = 0
            while offset < raw.count,
                  let hit = memmem(base + offset, raw.count - offset, needle, needle.count) {
                let start = base.distance(to: hit)
                var end = start
                while end < raw.count, end - start < 512, urlBytes(raw[end]) { end += 1 }
                if let text = String(bytes: raw[start..<end], encoding: .ascii),
                   text.contains("{{") || text.hasSuffix("latest.json"), !found.contains(text) {
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
