import Foundation

/// The processor and macOS version, as Homebrew names them in a cask's `variations`.
public struct Platform: Sendable, Hashable {
    public let isARM: Bool
    public let macOSMajor: Int

    public init(isARM: Bool, macOSMajor: Int) {
        self.isARM = isARM
        self.macOSMajor = macOSMajor
    }

    public static var current: Platform {
        #if arch(arm64)
        let arm = true
        #else
        let arm = false
        #endif
        return Platform(isARM: arm, macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    static let codenames: [Int: String] = [
        11: "big_sur", 12: "monterey", 13: "ventura", 14: "sonoma", 15: "sequoia", 26: "tahoe", 27: "golden_gate",
    ]

    /// Newer macOS versions than this table knows use the newest name, which matches
    /// what Homebrew publishes as the default.
    public var codename: String {
        if let name = Self.codenames[macOSMajor] { return name }
        let newest = Self.codenames.keys.max()!
        return macOSMajor > newest ? Self.codenames[newest]! : "big_sur"
    }

    /// `arm64_sonoma` or `sonoma`. The cask's top-level fields describe the newest macOS on
    /// Apple silicon; variations override them for other platforms.
    public var variationKey: String { isARM ? "arm64_\(codename)" : codename }
}
