import Foundation

/// What happened to each app, newest first: updates found, installs, hand-offs, refusals and
/// versions put back. Keyed by bundle ID, the last 50 events per app. Stays on this Mac.
public struct UpdateHistory: Codable, Sendable, Equatable {
    public static let limit = 50
    public private(set) var events: [String: [HistoryEvent]] = [:]

    public init() {}

    public func events(for bundleID: String) -> [HistoryEvent] { events[bundleID] ?? [] }

    public mutating func record(_ kind: HistoryEvent.Kind, for bundleID: String, at date: Date = Date()) {
        var list = events[bundleID] ?? []
        list.insert(HistoryEvent(date: date, kind: kind), at: 0)
        events[bundleID] = Array(list.prefix(Self.limit))
    }

    /// Notes a newly found version once, not on every check that sees it again.
    public mutating func noteFound(version: String, source: String, for bundleID: String, at date: Date = Date()) {
        let seen = events(for: bundleID).contains {
            if case .found(version, _) = $0.kind { true } else { false }
        }
        if !seen { record(.found(version: version, source: source), for: bundleID, at: date) }
    }

    /// Burnish's most recent update of this app, when nothing has been put back since.
    public func latestUpdate(for bundleID: String) -> HistoryEvent? {
        for event in events(for: bundleID) {
            switch event.kind {
            case .updated: return event
            case .restored: return nil
            default: continue
            }
        }
        return nil
    }
}

public struct HistoryEvent: Codable, Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var date: Date
    public var kind: Kind

    public enum Kind: Codable, Sendable, Hashable {
        /// A newer version showed up. `source` is the update source's raw name (`sparkle`, `homebrew`).
        case found(version: String, source: String)
        /// Burnish installed it, and the earlier version went to the Trash at `previousCopy`.
        case updated(from: String, to: String, previousCopy: String?)
        /// An earlier version went back in place; the newer one went to the Trash at `replacedCopy`.
        case restored(to: String, from: String, replacedCopy: String?)
        /// Someone else did the install: `homebrew` or `installer` (Apple's Installer).
        case handedOff(version: String, to: String)
        /// An install Burnish refused, and why.
        case refused(version: String, reason: String)
    }

    public init(date: Date, kind: Kind) {
        self.date = date
        self.kind = kind
    }
}

extension StoreKey {
    public static var history: StoreKey<UpdateHistory> { StoreKey<UpdateHistory>("history.json") }
}
