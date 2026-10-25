/// What an app or a source says its version is: a display version and a build number.
public struct VersionPair: Sendable, Hashable, Codable {
    /// `CFBundleShortVersionString`, or a source's display version.
    public var short: String?
    /// `CFBundleVersion`, or a source's build number.
    public var build: String?

    public init(short: String?, build: String? = nil) {
        self.short = short?.nonEmpty
        self.build = build?.nonEmpty
    }

    /// Splits strings like `5.0 (1234)` or `2.1 build 345` into a version and a build.
    public static func splittingDisplay(_ string: String) -> VersionPair {
        let s = string.trimmingWhitespace()
        if let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close {
            let core = String(s[..<open]).trimmingWhitespace()
            var inner = String(s[s.index(after: open)..<close]).trimmingWhitespace()
            if inner.lowercased().hasPrefix("build ") { inner = String(inner.dropFirst(6)) }
            return VersionPair(short: core, build: inner)
        }
        let marker = Array(" build ")
        let lower = Array(s.lowercased())
        if lower.count > marker.count {
            for offset in 0...(lower.count - marker.count) where Array(lower[offset..<offset + marker.count]) == marker {
                let core = String(s.prefix(offset))
                let build = String(s.dropFirst(offset + marker.count))
                return VersionPair(short: core, build: build)
            }
        }
        return VersionPair(short: s)
    }

    /// Homebrew writes `1.2.3,456` for short version `1.2.3` with build `456`.
    /// Parts after the second are download-URL details and are ignored.
    public static func fromCask(_ version: String) -> VersionPair {
        let parts = version.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
        return VersionPair(short: parts.first, build: parts.count > 1 ? parts[1] : nil)
    }

    /// The best single string to show a person.
    public var display: String { short ?? build ?? "?" }
}

/// Which part of the installed app a source compares against.
public enum ComparisonBasis: Sendable {
    /// App Store, Homebrew, Electron and GitHub compare display versions.
    case shortVersion
    /// Sparkle compares `CFBundleVersion`, so Burnish does too for Sparkle sources.
    case bundleVersion
}

public enum UpdateVerdict: Sendable, Equatable {
    /// The source has a newer version. `major` is true for a first-number jump like 5.x → 6.x.
    case newer(major: Bool)
    case same
    /// The installed copy is newer than the source (a beta, or a source that lags). Never a downgrade.
    case older
    /// Burnish can't tell. Never shown as an update.
    case cantCompare(CantCompareReason)
}

/// Why two versions couldn't be compared. Kept as data so this module stays free of UI text.
public enum CantCompareReason: Sendable, Equatable {
    /// The source gave no version at all.
    case noVersion(fromFeed: Bool)
    /// The source says "latest" instead of a number.
    case latest
    /// The source's version isn't readable.
    case unreadable(String)
    /// The installed copy's version isn't readable.
    case installedUnreadable
    /// The two use different numbering schemes.
    case formatsDiffer(installed: String, available: String, fromFeed: Bool)
    /// The feed's build number is newer but its display version is older.
    case buildNewerVersionOlder
}

public enum UpdateComparator {
    public static func compare(installed: VersionPair, available: VersionPair, basis: ComparisonBasis) -> UpdateVerdict {
        switch basis {
        case .shortVersion: return compareShort(installed: installed, available: available)
        case .bundleVersion: return compareBuild(installed: installed, available: available)
        }
    }

    // MARK: Display-version sources

    private static func compareShort(installed: VersionPair, available: VersionPair) -> UpdateVerdict {
        guard let availableString = available.short ?? available.build else {
            return .cantCompare(.noVersion(fromFeed: false))
        }
        guard let latest = Version(availableString) else {
            return .cantCompare(unreadable(availableString))
        }
        guard let installedString = installed.short ?? installed.build, let current = Version(installedString) else {
            return .cantCompare(.installedUnreadable)
        }
        let installedBuild = installed.build.flatMap(Version.init)

        if latest == current {
            // Same display version: a numeric build part can still say "newer" (`1.2.3,456`).
            if let availableBuild = available.build.flatMap(Version.init), let installedBuild,
               availableBuild.isPlainNumeric, installedBuild.isPlainNumeric,
               isCompatible(availableBuild, installedBuild), availableBuild > installedBuild {
                return .newer(major: false)
            }
            return .same
        }
        // Some casks track the build number instead of the display version.
        if let installedBuild, latest == installedBuild { return .same }

        // Homebrew sometimes writes the build into the version: `2.20.2.2629` is 2.20.2 (2629).
        if current.isPrefix(of: latest), let extra = latest.dropping(current.components.count), let installedBuild {
            if extra == installedBuild { return .same }
            if Self.looksLikeSameBuildScheme(extra, installedBuild) {
                return extra > installedBuild ? .newer(major: false) : .older
            }
        }

        if isCompatible(latest, current) {
            return latest > current ? .newer(major: isMajorUpgrade(from: current, to: latest)) : .older
        }
        // A cask that tracks build numbers: only when the shapes clearly agree (`8230` vs `8226`),
        // so a tiny CFBundleVersion like `1` never turns `5.2` into an update.
        if let installedBuild, latest.components.count == installedBuild.components.count,
           latest.components.count >= 2 || (latest.leadingNumber ?? 0) >= 100,
           isCompatible(latest, installedBuild) {
            return latest > installedBuild ? .newer(major: false) : .older
        }
        // Chromium-based apps put the engine's major first: Brave 155.1.97.57 is Brave 1.97.57.
        if current.components.count >= 4, let engine = current.major, (50...999).contains(engine),
           latest.components.count >= 3,
           let unprefixed = current.droppingFirstComponent(), unprefixed.leadingNumber == latest.leadingNumber {
            if latest == unprefixed { return .same }
            return latest > unprefixed ? .newer(major: false) : .older
        }
        return .cantCompare(.formatsDiffer(installed: installedString, available: availableString, fromFeed: false))
    }

    /// Two single numbers with the same number of digits (at least three): `2629` and `2630`.
    static func looksLikeSameBuildScheme(_ a: Version, _ b: Version) -> Bool {
        guard a.components.count == 1, b.components.count == 1,
              case let .number(x) = a.components[0], case let .number(y) = b.components[0] else { return false }
        return x.count == y.count && x.count >= 3
    }

    // MARK: Sparkle

    private static func compareBuild(installed: VersionPair, available: VersionPair) -> UpdateVerdict {
        guard let availableString = available.build ?? available.short else {
            return .cantCompare(.noVersion(fromFeed: true))
        }
        guard let latest = Version(availableString) else {
            return .cantCompare(unreadable(availableString))
        }
        guard let installedString = installed.build ?? installed.short, let current = Version(installedString) else {
            return .cantCompare(.installedUnreadable)
        }
        let installedShort = installed.short.flatMap(Version.init)
        let availableShort = available.short.flatMap(Version.init)

        if latest == current { return .same }
        guard isCompatible(latest, current) else {
            // Builds use different schemes; fall back to display versions when both are readable.
            if let installedShort, let availableShort, isCompatible(installedShort, availableShort) {
                if availableShort == installedShort { return .same }
                return availableShort > installedShort
                    ? .newer(major: isMajorUpgrade(from: installedShort, to: availableShort)) : .older
            }
            return .cantCompare(.formatsDiffer(installed: installedString, available: availableString, fromFeed: true))
        }
        guard latest > current else { return .older }

        if let installedShort, let availableShort, isCompatible(installedShort, availableShort) {
            if availableShort < installedShort {
                return .cantCompare(.buildNewerVersionOlder)
            }
            return .newer(major: isMajorUpgrade(from: installedShort, to: availableShort))
        }
        return .newer(major: false)
    }

    // MARK: Rules

    /// Two versions use the same scheme when their first numbers are in the same range.
    /// This stops `8226` (a build) being read as newer than `8.2.26` (a version).
    public static func isCompatible(_ a: Version, _ b: Version) -> Bool {
        guard let x = a.leadingNumber, let y = b.leadingNumber else { return false }
        let lo = min(x, y), hi = max(x, y)
        if hi < 100 { return true }
        return lo >= 50 && hi <= lo * 2
    }

    /// A jump in the first number (5.x → 6.x) may be a paid upgrade. Rapid-release apps with
    /// big first numbers (Chrome 155 → 156) and 0.x → 1.0 jumps don't count.
    public static func isMajorUpgrade(from installed: Version, to latest: Version) -> Bool {
        guard let from = installed.major, let to = latest.major else { return false }
        return to > from && from >= 1 && to < 50
    }

    private static func unreadable(_ string: String) -> CantCompareReason {
        string.lowercased() == "latest" ? .latest : .unreadable(string)
    }
}

extension String {
    var nonEmpty: String? {
        let t = trimmingWhitespace()
        return t.isEmpty ? nil : t
    }
}
