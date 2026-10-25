import Foundation
import CaskIndex
import Inventory
import Net
import Versions

/// Reads an app's own Sparkle appcast and picks the newest item this Mac can run (F3).
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
            case .notHTTPS: "The update feed isn't HTTPS"
            case .unreachable(let why): "Feed not reachable (\(why))"
            case .unreadable: "The update feed couldn't be read"
            case .noUsableItem: "The update feed lists no release for this Mac"
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

    public func check(feed: URL) async throws(Failure) -> Result {
        guard feed.scheme?.lowercased() == "https" else { throw .notHTTPS }
        let response: HTTPResponse
        do {
            response = try await client.get(feed, headers: [:], timeout: Net.feedTimeout)
        } catch {
            throw .unreachable((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        guard response.isSuccess else { throw .unreachable("HTTP \(response.status)") }
        guard let items = try? AppcastParser.parse(response.body) else { throw .unreadable }
        return try select(from: items)
    }

    func select(from items: [AppcastItem]) throws(Failure) -> Result {
        var best: (AppcastItem, Version)?
        var newestIncompatible: (AppcastItem, Version)?

        for item in items {
            // Items on a named channel (beta) are opt-in inside the app; only the default channel counts.
            guard item.channel == nil else { continue }
            if let os = item.enclosure?.os, os.lowercased() != "macos" { continue }
            guard item.enclosure?.url != nil || item.isInformational else { continue }
            guard let raw = item.effectiveVersion, let version = Version(raw) else { continue }

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
            note = item.minimumSystemVersion.map { "Version \(shown) needs macOS \($0) or later" } ?? "Version \(shown) can't run on this Mac"
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
