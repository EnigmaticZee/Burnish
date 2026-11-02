import Foundation

/// Tauri apps compile their updater's address into the executable rather than Info.plist. A whole
/// binary is a lot to read, so only one that links WebKit (every Tauri app does) gets the full
/// read, and then only once it's clearly a Tauri app.
public enum TauriDetector {
    /// How much of the executable says whether it links WebKit: the load commands sit at the front.
    static let headSize = 1024 * 1024

    /// The updater endpoints, templates and all (`https://…/{{target}}/{{arch}}/{{current_version}}`).
    public static func updateEndpoints(executable: URL) -> [String] {
        updateEndpoints(executable: executable, head: BinaryStrings.head(of: executable, bytes: headSize))
    }

    /// The same, given the executable's first `headSize` bytes already read.
    static func updateEndpoints(executable: URL, head: Data) -> [String] {
        guard BinaryStrings.contains(head, "/WebKit.framework/"),
              let binary = BinaryStrings.mapped(executable),
              BinaryStrings.contains(binary, "tauri")
        else { return [] }
        return endpoints(in: binary)
    }

    /// URLs that look like an updater endpoint: a Tauri template variable, or a `latest.json`.
    static func endpoints(in binary: Data) -> [String] {
        BinaryStrings.httpsURLs(in: binary).filter { $0.contains("{{") || $0.hasSuffix("latest.json") }
    }
}
