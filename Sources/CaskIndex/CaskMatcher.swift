import Foundation
import Inventory
import Versions

/// How sure Burnish is that a cask describes an installed app (F5).
public struct CaskMatch: Sendable, Hashable, Codable {
    public enum Confidence: Int, Sendable, Codable, Comparable, CustomStringConvertible {
        /// Name only. Never raises an alert; shown under Needs your confirmation.
        case low = 0
        /// File name and display name agree, or a `.pkg` cask quits this bundle ID.
        case medium
        /// A bundle ID from the cask matches and nothing contradicts it.
        case high
        /// The user, the community overrides file, or Homebrew's own Caskroom said so.
        case confirmed

        public static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }

        public var description: String {
            switch self {
            case .low: "low"
            case .medium: "medium"
            case .high: "high"
            case .confirmed: "confirmed"
            }
        }
    }

    public enum Evidence: String, Sendable, Codable {
        case bundleIDQuit, bundleIDHint, fileName, displayName
        case userChoice, communityChoice, caskroom
    }

    public let token: String
    public let confidence: Confidence
    public let evidence: [Evidence]
    /// Other casks that matched as well, such as `firefox@beta` next to `firefox`.
    public let alternatives: [String]
    /// Several channels fit equally well and Burnish couldn't tell which one is installed.
    public let channelUnsure: Bool

    public init(token: String, confidence: Confidence, evidence: [Evidence], alternatives: [String] = [], channelUnsure: Bool = false) {
        self.token = token
        self.confidence = confidence
        self.evidence = evidence
        self.alternatives = alternatives
        self.channelUnsure = channelUnsure
    }

    /// Only high- or medium-confidence matches that aren't channel-ambiguous can say "Update available".
    public var canRaiseAlert: Bool { confidence >= .medium && !channelUnsure }
}

/// Corrections that win over scoring: the user's, then the community file's (F17).
public struct MatchOverrides: Sendable, Hashable, Codable {
    /// Bundle ID → cask token.
    public var chosen: [String: String]
    /// Bundle ID → tokens marked "not this app".
    public var rejected: [String: Set<String>]
    /// Bundle IDs known to have no cask.
    public var noCask: Set<String>

    public init(chosen: [String: String] = [:], rejected: [String: Set<String>] = [:], noCask: Set<String> = []) {
        self.chosen = chosen
        self.rejected = rejected
        self.noCask = noCask
    }

    public static let none = MatchOverrides()
}

public struct CaskMatcher: Sendable {
    public let catalog: CaskCatalog
    public let user: MatchOverrides
    public let community: MatchOverrides

    public init(catalog: CaskCatalog, user: MatchOverrides = .none, community: MatchOverrides = .none) {
        self.catalog = catalog
        self.user = user
        self.community = community
    }

    public func match(_ app: InstalledApp) -> CaskMatch? {
        let id = app.bundleID
        if let token = user.chosen[id], catalog.cask(token) != nil {
            return CaskMatch(token: token, confidence: .confirmed, evidence: [.userChoice])
        }
        if user.noCask.contains(id) { return nil }
        let rejected = user.rejected[id] ?? []
        if let token = app.caskroomToken, !rejected.contains(token), catalog.cask(token) != nil {
            return CaskMatch(token: token, confidence: .confirmed, evidence: [.caskroom])
        }
        if let token = community.chosen[id], !rejected.contains(token), catalog.cask(token) != nil {
            return CaskMatch(token: token, confidence: .confirmed, evidence: [.communityChoice])
        }
        if community.noCask.contains(id) { return nil }

        let scored = candidates(for: app).filter { !rejected.contains(catalog.casks[$0.index].token) }
        guard let bestConfidence = scored.map(\.confidence).max() else { return nil }
        let top = scored.filter { $0.confidence == bestConfidence }
        let others = scored.filter { $0.confidence != bestConfidence }.map { catalog.casks[$0.index].token }

        let ranked = top.map { ($0, channelScore(catalog.casks[$0.index], for: app)) }.sorted { $0.1 > $1.1 }
        let winner = ranked[0]
        let tied = ranked.filter { $0.1 == winner.1 }
        let alternatives = ranked.dropFirst().map { catalog.casks[$0.0.index].token } + others
        return CaskMatch(
            token: catalog.casks[winner.0.index].token,
            confidence: bestConfidence,
            evidence: winner.0.evidence,
            alternatives: alternatives,
            channelUnsure: tied.count > 1
        )
    }

    struct Scored {
        let index: Int
        let confidence: CaskMatch.Confidence
        let evidence: [CaskMatch.Evidence]
    }

    func candidates(for app: InstalledApp) -> [Scored] {
        let id = app.bundleID.lowercased()
        let fileName = app.fileName.lowercased()
        // A renamed copy (`Chrome 2.app`) still carries its real name in Info.plist.
        let bundleFileNames = Set(app.bundleNames.map { ($0 + ".app").lowercased() })
        let names = Set(([app.name] + app.bundleNames).map(CaskCatalog.normalize).filter { !$0.isEmpty })

        var pool = Set<Int>()
        pool.formUnion(catalog.byQuitID[id] ?? [])
        pool.formUnion(catalog.byHintID[id] ?? [])
        pool.formUnion(catalog.byAppName[fileName] ?? [])
        for name in names { pool.formUnion(catalog.byName[name] ?? []) }

        return pool.sorted().compactMap { index in
            let cask = catalog.casks[index]
            let quitIDs = cask.quitBundleIDs.flatMap { $0 }.map { $0.lowercased() }
            let quitHead = cask.quitBundleIDs.contains { $0.first?.lowercased() == id }
            let idQuit = quitIDs.contains(id)
            let idHint = cask.hintBundleIDs.contains(id)
            let caskApps = Set((cask.appNames + cask.uninstallAppNames).map { $0.lowercased() })
            let fileMatch = caskApps.contains(fileName)
            let bundleFileMatch = !caskApps.isDisjoint(with: bundleFileNames)
            let caskNames = Set((cask.names + [cask.baseToken]).map(CaskCatalog.normalize))
            let nameMatch = !caskNames.isDisjoint(with: names)
            let hasApps = !caskApps.isEmpty

            var evidence: [CaskMatch.Evidence] = []
            if idQuit { evidence.append(.bundleIDQuit) } else if idHint { evidence.append(.bundleIDHint) }
            if fileMatch || ((idQuit || idHint) && bundleFileMatch) { evidence.append(.fileName) }
            if nameMatch { evidence.append(.displayName) }
            guard !evidence.isEmpty else { return nil }

            // A cask that says which bundle IDs it quits, none of them this app's, describes another app.
            let quitsSomethingElse = !quitIDs.isEmpty && !idQuit && !idHint

            let confidence: CaskMatch.Confidence
            if (idQuit || idHint) && (fileMatch || bundleFileMatch) {
                confidence = .high
            } else if quitHead && !hasApps && nameMatch {
                confidence = .high
            } else if fileMatch && nameMatch && !quitsSomethingElse {
                confidence = .medium
            } else if quitHead && !hasApps {
                // A plug-in's .pkg may quit its host app too; only the first ID counts.
                confidence = .medium
            } else {
                confidence = .low
            }
            return Scored(index: index, confidence: confidence, evidence: evidence)
        }
    }

    /// Picks between channels of the same app (stable, beta, ESR): the one whose version line
    /// matches the installed version wins, then a stable, maintained cask.
    func channelScore(_ cask: Cask, for app: InstalledApp) -> Int {
        var score = 0
        let installed = app.version.short.flatMap(Version.init) ?? app.version.build.flatMap(Version.init)
        let installedBuild = app.version.build.flatMap(Version.init)
        let available = cask.versionPair.short.flatMap(Version.init)
        if let installed, let available {
            if available == installed || available == installedBuild { score += 3 }
            if available.major == installed.major { score += 2 }
            if cask.isPrereleaseChannel == installed.isPrerelease { score += 1 }
        } else if cask.isPrereleaseChannel == false {
            score += 1
        }
        if cask.channel == nil { score += 1 }
        if cask.disabled { score -= 2 }
        if cask.deprecated { score -= 1 }
        return score
    }
}
