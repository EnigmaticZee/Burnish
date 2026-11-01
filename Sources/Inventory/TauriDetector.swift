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
        guard BinaryStrings.contains(head, "/WebKit.framework/"),
              let size = (try? executable.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maximumSize,
              let binary = try? Data(contentsOf: executable, options: .alwaysMapped),
              BinaryStrings.contains(binary, "tauri")
        else { return [] }
        return endpoints(in: binary)
    }

    /// URLs that look like an updater endpoint: a Tauri template variable, or a `latest.json`.
    static func endpoints(in binary: Data) -> [String] {
        BinaryStrings.httpsURLs(in: binary).filter { $0.contains("{{") || $0.hasSuffix("latest.json") }
    }
}
