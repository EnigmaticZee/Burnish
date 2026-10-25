import Foundation
import Net
import Versions

/// Apps built with Tauri ask their updater endpoints the way Tauri does: a static `latest.json`
/// listing every platform, or a server that answers 204 when there's nothing newer. Burnish reads
/// the version and notes; the app installs the update itself, checking its own signature.
public struct TauriSource: Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        case unreachable(String)
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .unreachable(let why): String(localized: "Feed not reachable (\(why))")
            case .unreadable: String(localized: "The update feed couldn't be read")
            }
        }
    }

    let client: HTTPClient
    let isARM: Bool

    public init(client: HTTPClient, isARM: Bool) {
        self.client = client
        self.isARM = isARM
    }

    /// The newest release, or the installed version itself when the server says there's nothing newer.
    public func check(endpoints: [String], installed: VersionPair) async throws(Failure) -> Release {
        let version = installed.short ?? installed.build ?? "0"
        var lastFailure = Failure.unreadable
        for template in endpoints {
            guard let url = Self.expand(template, version: version, isARM: isARM) else { continue }
            do {
                let response = try await client.get(url, headers: ["Accept": "application/json"], timeout: 10)
                if response.status == 204 {
                    return Release(source: .tauri, version: installed, basis: .shortVersion, needsManualInstall: true)
                }
                guard response.isSuccess else { lastFailure = .unreachable("HTTP \(response.status)"); continue }
                guard let release = Self.parse(response.body, isARM: isARM) else { lastFailure = .unreadable; continue }
                return release
            } catch {
                lastFailure = .unreachable((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
        throw lastFailure
    }

    /// Fills in Tauri's template variables. Only HTTPS endpoints are asked.
    static func expand(_ template: String, version: String, isARM: Bool) -> URL? {
        let arch = isARM ? "aarch64" : "x86_64"
        let text = template
            .replacingOccurrences(of: "{{target}}", with: "darwin")
            .replacingOccurrences(of: "{{arch}}", with: arch)
            .replacingOccurrences(of: "{{current_version}}", with: version)
        guard let url = URL(string: text), url.scheme == "https", !text.contains("{{") else { return nil }
        return url
    }

    /// Static files list `platforms`; dynamic servers answer with one release.
    static func parse(_ data: Data, isARM: Bool) -> Release? {
        struct Platform: Decodable { let url: String? }
        struct Payload: Decodable {
            let version: String
            let notes: String?
            let pub_date: String?
            let url: String?
            let platforms: [String: Platform]?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let keys = isARM ? ["darwin-aarch64", "darwin-universal", "darwin"] : ["darwin-x86_64", "darwin-universal", "darwin"]
        if let platforms = payload.platforms, !keys.contains(where: { platforms[$0] != nil }) { return nil }
        var version = payload.version
        if version.hasPrefix("v") { version.removeFirst() }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = payload.pub_date.flatMap { dates.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        return Release(
            source: .tauri, version: VersionPair(short: version), basis: .shortVersion,
            releaseNotes: payload.notes.map { ReleaseNotes(text: $0, format: .plainText) },
            date: date, needsManualInstall: true
        )
    }
}
