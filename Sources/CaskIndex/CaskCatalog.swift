import Foundation

/// Homebrew's casks indexed for matching and search. Built once per refresh.
public final class CaskCatalog: Sendable {
    public let casks: [Cask]
    /// When Burnish last got this data from Homebrew.
    public let dataDate: Date?
    public let platform: Platform

    private let byToken: [String: Int]
    let byQuitID: [String: [Int]]
    let byHintID: [String: [Int]]
    let byAppName: [String: [Int]]
    let byName: [String: [Int]]

    public init(casks: [Cask], dataDate: Date? = nil, platform: Platform = .current) {
        self.casks = casks
        self.dataDate = dataDate
        self.platform = platform
        var byToken: [String: Int] = [:]
        var byQuitID: [String: [Int]] = [:]
        var byHintID: [String: [Int]] = [:]
        var byAppName: [String: [Int]] = [:]
        var byName: [String: [Int]] = [:]
        for (index, cask) in casks.enumerated() {
            byToken[cask.token] = index
            for id in Set(cask.quitBundleIDs.flatMap { $0 }.map { $0.lowercased() }) { byQuitID[id, default: []].append(index) }
            for id in cask.hintBundleIDs { byHintID[id, default: []].append(index) }
            for app in Set((cask.appNames + cask.uninstallAppNames).map { $0.lowercased() }) { byAppName[app, default: []].append(index) }
            for name in Set((cask.names + [cask.baseToken]).map(Self.normalize).filter { !$0.isEmpty }) {
                byName[name, default: []].append(index)
            }
        }
        self.byToken = byToken
        self.byQuitID = byQuitID
        self.byHintID = byHintID
        self.byAppName = byAppName
        self.byName = byName
    }

    public var count: Int { casks.count }

    public func cask(_ token: String) -> Cask? {
        byToken[token].map { casks[$0] }
    }

    /// Token, name or app-name search for the "pick a different cask" sheet.
    public func search(_ query: String, limit: Int = 30) -> [Cask] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let normalized = Self.normalize(q)
        func rank(_ cask: Cask) -> Int? {
            if cask.token == q { return 0 }
            if cask.token.hasPrefix(q) { return 1 }
            if cask.names.contains(where: { Self.normalize($0) == normalized }) { return 1 }
            if cask.names.contains(where: { $0.lowercased().contains(q) }) { return 2 }
            if cask.token.contains(q) { return 3 }
            if cask.appNames.contains(where: { $0.lowercased().contains(q) }) { return 3 }
            return nil
        }
        var ranked: [(cask: Cask, rank: Int)] = []
        for cask in casks {
            if let r = rank(cask) { ranked.append((cask, r)) }
        }
        ranked.sort { a, b in a.rank != b.rank ? a.rank < b.rank : a.cask.token < b.cask.token }
        return Array(ranked.prefix(limit).map(\.cask))
    }

    /// Lowercase letters and digits only, so "Google Chrome", "google-chrome" and "GoogleChrome" agree.
    public static func normalize(_ name: String) -> String {
        var s = name
        if s.lowercased().hasSuffix(".app") { s.removeLast(4) }
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var out = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) {
            out.append(scalar)
        }
        return String(out)
    }
}
