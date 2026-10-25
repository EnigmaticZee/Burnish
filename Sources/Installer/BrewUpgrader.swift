import Foundation

/// Optional handoff for apps installed by Homebrew: `brew upgrade --cask <token>` (F18).
/// Off unless the person turns it on, so Burnish and Homebrew never fight over an app.
public struct BrewUpgrader: Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        case brewNotFound
        case failed(String)
        case needsPassword(String)

        public var errorDescription: String? {
            switch self {
            case .brewNotFound: String(localized: "Homebrew isn't installed in the usual place")
            case .failed(let detail): String(localized: "brew upgrade failed: \(detail)")
            case .needsPassword(let token): String(localized: "Homebrew needs your password for this one. Run `brew upgrade --cask \(token)` in Terminal.")
            }
        }
    }

    public static let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    public init() {}

    public static var brewPath: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func upgrade(token: String) async throws(Failure) {
        guard let brew = Self.brewPath else { throw .brewNotFound }
        let output: Shell.Output
        do {
            output = try await Shell.run(brew, ["upgrade", "--cask", token])
        } catch {
            throw .failed(error.localizedDescription)
        }
        guard output.succeeded else {
            let text = output.errorText
            if text.contains("sudo") || text.lowercased().contains("password") { throw .needsPassword(token) }
            throw .failed(text.split(separator: "\n").last.map(String.init) ?? "exit \(output.status)")
        }
    }
}
