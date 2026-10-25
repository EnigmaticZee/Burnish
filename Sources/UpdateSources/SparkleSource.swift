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

    public func check(feed: URL, preferences: Preferences = Preferences()) async throws(Failure) -> Result {
        guard feed.scheme?.lowercased() == "https" else { throw .notHTTPS }
        let response: HTTPResponse
        do {
            response = try await client.get(feed, headers: [:], timeout: Net.feedTimeout)
        } catch {
            throw .unreachable((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        guard response.isSuccess else { throw .unreachable("HTTP \(response.status)") }
        guard let items = try? AppcastParser.parse(response.body) else { throw .unreadable }
        return try select(from: items, preferences: preferences)
    }

    func select(from items: [AppcastItem], preferences: Preferences = Preferences()) throws(Failure) -> Result {
        var best: (AppcastItem, Version)?
        var newestIncompatible: (AppcastItem, Version)?
        var newestAboveCap: (AppcastItem, Version)?

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
        return Result(release: release(from: item), newerButIncompatible: note)
    }

    func release(from item: AppcastItem) -> Release {
        let notes: ReleaseNotes?
        if let html = AppcastItem.localized(item.descriptions, language: language) {
            notes = ReleaseNotes(text: html, format: .html, link: AppcastItem.localized(item.releaseNotesLinks, language: language))
        } else if let link = AppcastItem.localized(item.releaseNotesLinks, language: language) ?? item.fullReleaseNotesLink {
            notes = ReleaseNotes(text: nil, format: .html, link: link)
        } else {
            notes = nil
        }
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
