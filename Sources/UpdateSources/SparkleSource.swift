import Foundation
import CaskIndex
import Inventory
import Net
import Versions

/// Reads an app's own Sparkle appcast and picks the newest item this Mac can run.
public struct SparkleSource: Sendable {
    public struct Result: Sendable {
        public var release: Release?
        /// Set when a newer item exists but needs a newer macOS (or other hardware).
        public var newerButIncompatible: String?

        public init(release: Release?, newerButIncompatible: String? = nil) {
            self.release = release
            self.newerButIncompatible = newerButIncompatible
        }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case notHTTPS
        case unreachable(String)
        case unreadable
        case noUsableItem

        public var errorDescription: String? {
            switch self {
            case .notHTTPS: String(localized: "The update feed isn't HTTPS")
            case .unreachable(let why): String(localized: "Feed not reachable (\(why))")
            case .unreadable: String(localized: "The update feed couldn't be read")
            case .noUsableItem: String(localized: "The update feed lists no release for this Mac")
            }
        }
    }

    let client: HTTPClient
    let system: SystemVersion
    let isARM: Bool
    let language: String?

    public init(client: HTTPClient, system: SystemVersion = .current, isARM: Bool = Platform.currentIsARM, language: String? = Locale.current.language.languageCode?.identifier) {
        self.client = client
        self.system = system
        self.isARM = isARM
        self.language = language
    }

    /// Per-app rules that change which release counts as the newest.
    public struct Preferences: Sendable, Equatable {
        /// Stay on this major version (5 means 5.x).
        public var maximumMajor: Int?
        /// Take releases on a named channel (usually "beta") too.
        public var includeBeta: Bool

        public init(maximumMajor: Int? = nil, includeBeta: Bool = false) {
            self.maximumMajor = maximumMajor
            self.includeBeta = includeBeta
        }
    }

    /// `installed` lets the result list the versions in between, for "what you missed".
    public func check(feed: URL, preferences: Preferences = Preferences(), installed: VersionPair? = nil) async throws(Failure) -> Result {
        guard feed.scheme?.lowercased() == "https" else { throw .notHTTPS }
        let response: HTTPResponse
        do {
            response = try await client.get(feed, headers: [:], timeout: Net.feedTimeout)
        } catch {
            throw .unreachable((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        guard response.isSuccess else { throw .unreachable("HTTP \(response.status)") }
        guard let items = try? AppcastParser.parse(response.body) else { throw .unreadable }
        return try select(from: items, preferences: preferences, installed: installed)
    }

    func select(from items: [AppcastItem], preferences: Preferences = Preferences(), installed: VersionPair? = nil) throws(Failure) -> Result {
        var best: (AppcastItem, Version)?
        var newestIncompatible: (AppcastItem, Version)?
        var newestAboveCap: (AppcastItem, Version)?
        var usable: [(AppcastItem, Version)] = []

        for item in items {
            // Items on a named channel (beta) are opt-in, inside the app or through a Burnish rule.
            guard item.channel == nil || preferences.includeBeta else { continue }
            if let os = item.enclosure?.os, os.lowercased() != "macos" { continue }
            guard item.enclosure?.url != nil || item.isInformational else { continue }
            guard let raw = item.effectiveVersion, let version = Version(raw) else { continue }

            if let cap = preferences.maximumMajor, let major = item.effectiveShortVersion.flatMap(Version.init)?.major, major > cap {
                if newestAboveCap == nil || version > newestAboveCap!.1 { newestAboveCap = (item, version) }
                continue
            }
            let runsHere = system.satisfies(minimum: item.minimumSystemVersion)
                && system.satisfies(maximum: item.maximumSystemVersion)
                && (isARM || !item.hardwareRequirements.contains("arm64"))
            if runsHere {
                usable.append((item, version))
                if best == nil || version > best!.1 { best = (item, version) }
            } else if newestIncompatible == nil || version > newestIncompatible!.1 {
                newestIncompatible = (item, version)
            }
        }

        var note: String?
        if let (item, version) = newestIncompatible, best == nil || version > best!.1 {
            let shown = item.effectiveShortVersion ?? item.effectiveVersion ?? ""
            note = item.minimumSystemVersion.map { String(localized: "Version \(shown) needs macOS \($0) or later") } ?? String(localized: "Version \(shown) can't run on this Mac")
        }
        if let (item, _) = newestAboveCap, let cap = preferences.maximumMajor {
            let shown = item.effectiveShortVersion ?? item.effectiveVersion ?? ""
            note = String(localized: "Version \(shown) is out; you chose to stay on \(cap).x")
        }
        guard let (item, _) = best else {
            if note != nil { return Result(release: nil, newerButIncompatible: note) }
            throw .noUsableItem
        }
        var chosen = release(from: item)
        if let installed, let bestVersion = best?.1 {
            let missed = usable
                .filter { $0.1 < bestVersion }
                .filter { candidate in
                    let pair = VersionPair(short: candidate.0.effectiveShortVersion, build: candidate.0.effectiveVersion)
                    if case .newer = UpdateComparator.compare(installed: installed, available: pair, basis: .bundleVersion) { return true }
                    return false
                }
                .sorted { $0.1 > $1.1 }
                .prefix(10)
                .map { MissedRelease(version: $0.0.effectiveShortVersion ?? $0.0.effectiveVersion ?? "", date: $0.0.pubDate, notes: notes(of: $0.0)) }
            chosen.missed = missed.isEmpty ? nil : Array(missed)
        }
        return Result(release: chosen, newerButIncompatible: note)
    }

    func notes(of item: AppcastItem) -> ReleaseNotes? {
        if let html = AppcastItem.localized(item.descriptions, language: language) {
            return ReleaseNotes(text: html, format: .html, link: AppcastItem.localized(item.releaseNotesLinks, language: language))
        }
        if let link = AppcastItem.localized(item.releaseNotesLinks, language: language) ?? item.fullReleaseNotesLink {
            return ReleaseNotes(text: nil, format: .html, link: link)
        }
        return nil
    }

    func release(from item: AppcastItem) -> Release {
        let notes = notes(of: item)
        let page = item.link.flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil }
        return Release(
            source: .sparkle,
            version: VersionPair(short: item.effectiveShortVersion, build: item.effectiveVersion),
            basis: .bundleVersion,
            downloadURL: item.isInformational ? nil : item.enclosure?.url,
            downloadPage: page,
            releaseNotes: notes,
            minimumOS: item.minimumSystemVersion,
            date: item.pubDate,
            edSignature: item.enclosure?.edSignature,
            length: item.enclosure?.length,
            isInformational: item.isInformational,
            isCritical: item.isCritical,
            installsPkg: ["package", "interactive-package"].contains(item.enclosure?.installationType ?? "")
                || (item.enclosure?.url?.pathExtension.lowercased()).map { ["pkg", "mpkg"].contains($0) } == true,
            minimumAutoupdateVersion: item.minimumAutoupdateVersion
        )
    }
}

extension Platform {
    public static var currentIsARM: Bool { Platform.current.isARM }
}
