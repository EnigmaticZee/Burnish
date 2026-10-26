import Foundation
import Inventory
import Store
import UpdateSources

/// What Burnish can vouch for about one update, like the marks an assayer stamps on silver: some
/// it knows now, some it checks during the install, and some aren't available, which it says
/// plainly instead of rounding up to "safe".
public struct Hallmark: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case source, signature, checksum, sameDeveloper, gatekeeper, runsHere, version, wayBack, installedBy

        /// How the history names a check that passed.
        public var checkName: String {
            switch self {
            case .source: String(localized: "trusted source")
            case .signature: String(localized: "developer's signature")
            case .checksum: String(localized: "checksum")
            case .sameDeveloper: String(localized: "same developer")
            case .gatekeeper: String(localized: "Gatekeeper")
            case .runsHere: String(localized: "built for this Mac")
            case .version: String(localized: "newer version")
            case .wayBack: String(localized: "way back")
            case .installedBy: String(localized: "installer")
            }
        }
    }

    public enum State: Sendable, Hashable {
        /// Already confirmed from what the source and the app say.
        case confirmed
        /// Checked after the download, before the installed app is touched.
        case checkedAtInstall
        /// Someone else installs it and does the checking (Apple, Homebrew, the developer's updater).
        case handedOff
        /// The source doesn't offer this; the other checks carry the weight.
        case notAvailable
        /// Something worth knowing before updating.
        case caution
    }

    public var id: Kind { kind }
    public let kind: Kind
    public let state: State
    public let title: String
    public let detail: String
}

extension AppCheckResult {
    /// The hallmarks for the update this result offers, in the order a careful person would ask.
    public func hallmarks(homebrew: HomebrewHandling) -> [Hallmark] {
        guard let candidate = status.candidate else { return [] }
        let release = candidate.release
        let action = action(homebrew: homebrew)
        var marks: [Hallmark] = [sourceMark(release)]

        switch action {
        case .openAppStore:
            marks.append(Hallmark(kind: .installedBy, state: .handedOff, title: String(localized: "Installed by the App Store"),
                                  detail: String(localized: "Apple delivers, checks and installs App Store updates.")))
        case .brewUpgrade, .managedByHomebrew:
            marks.append(Hallmark(kind: .installedBy, state: .handedOff, title: String(localized: "Installed by Homebrew"),
                                  detail: String(localized: "Homebrew checks the download against its published checksum.")))
        case .openUpdater(let updater) where updater.path == app.url.path:
            marks.append(Hallmark(kind: .installedBy, state: .handedOff, title: String(localized: "Installed by \(app.name) itself"),
                                  detail: String(localized: "The app checks the update's signature with the key it ships with.")))
        case .openUpdater(let updater):
            marks.append(Hallmark(kind: .installedBy, state: .handedOff, title: String(localized: "Installed by \(updater.name)"),
                                  detail: String(localized: "The developer's own updater handles and checks it.")))
        case .openDownloadPage(_, let reason):
            marks.append(Hallmark(kind: .installedBy, state: .caution, title: String(localized: "Download it from the developer"),
                                  detail: reason))
        case .install:
            marks += installMarks(release)
        case .none:
            break
        }

        marks.append(versionMark(candidate))
        if action == .install {
            marks.append(Hallmark(kind: .wayBack, state: .confirmed, title: String(localized: "A way back"),
                                  detail: String(localized: "Your current version goes to the Trash, and Put Back returns it.")))
        }
        return marks
    }

    /// The checks an install will have run, for the history once it succeeds.
    public func installChecks(_ release: Release) -> [Hallmark.Kind] {
        var checks: [Hallmark.Kind] = [.source]
        if release.source == .sparkle, app.sparklePublicEDKey != nil, release.edSignature != nil { checks.append(.signature) }
        if release.sha256 != nil || release.sha512 != nil { checks.append(.checksum) }
        checks += [.sameDeveloper, .gatekeeper, .runsHere]
        return checks
    }

    private func sourceMark(_ release: Release) -> Hallmark {
        let host = release.downloadURL?.host ?? release.downloadPage?.host
        let secure = release.downloadURL.map { $0.scheme?.lowercased() == "https" } ?? true
        guard secure else {
            return Hallmark(kind: .source, state: .caution, title: String(localized: "Not over HTTPS"),
                            detail: String(localized: "Burnish only installs downloads that arrive over HTTPS."))
        }
        let place = host.map { String(localized: "From \($0), over HTTPS.") } ?? ""
        if release.listedByCommunity == true {
            return Hallmark(kind: .source, state: .notAvailable, title: String(localized: "A feed listed by the community"),
                            detail: String(localized: "Burnish reads it to spot updates and leaves the install to you."))
        }
        switch release.source {
        case .sparkle, .electron, .tauri:
            return Hallmark(kind: .source, state: .confirmed, title: String(localized: "The developer's own update feed"), detail: place)
        case .homebrew:
            return Hallmark(kind: .source, state: .confirmed, title: String(localized: "Homebrew's catalogue"), detail: place)
        case .github:
            return Hallmark(kind: .source, state: .confirmed, title: String(localized: "The developer's GitHub releases"), detail: place)
        case .appStore:
            return Hallmark(kind: .source, state: .confirmed, title: String(localized: "The Mac App Store"),
                            detail: String(localized: "Apple's public lookup."))
        }
    }

    private func installMarks(_ release: Release) -> [Hallmark] {
        var marks: [Hallmark] = []
        if release.source == .sparkle, app.sparklePublicEDKey != nil {
            marks.append(release.edSignature != nil
                ? Hallmark(kind: .signature, state: .checkedAtInstall, title: String(localized: "Signed by the developer"),
                           detail: String(localized: "The download must carry a signature made with the key \(app.name) trusts."))
                : Hallmark(kind: .signature, state: .caution, title: String(localized: "Missing the developer's signature"),
                           detail: String(localized: "\(app.name) expects signed updates and this one isn't, so Burnish will refuse it.")))
        } else {
            marks.append(Hallmark(kind: .signature, state: .notAvailable, title: String(localized: "No update signing key"),
                                  detail: String(localized: "\(app.name) doesn't pin one, so the other checks carry the weight.")))
        }
        if release.sha256 != nil || release.sha512 != nil {
            marks.append(Hallmark(kind: .checksum, state: .checkedAtInstall, title: String(localized: "Matches the published checksum"),
                                  detail: String(localized: "The download must match it byte for byte.")))
        } else {
            marks.append(Hallmark(kind: .checksum, state: .notAvailable, title: String(localized: "No checksum published"),
                                  detail: String(localized: "The new copy still has to be code-signed by the same developer.")))
        }
        let who = app.signature.authority?.replacingOccurrences(of: "Developer ID Application: ", with: "") ?? app.teamID ?? ""
        marks.append(Hallmark(kind: .sameDeveloper, state: .checkedAtInstall, title: String(localized: "Same developer as your copy"),
                              detail: String(localized: "Signed by \(who), with the same bundle ID.")))
        marks.append(Hallmark(kind: .gatekeeper, state: .checkedAtInstall, title: String(localized: "Accepted by Gatekeeper"),
                              detail: String(localized: "macOS checks the new copy the way it checks anything you download.")))
        marks.append(Hallmark(kind: .runsHere, state: .checkedAtInstall, title: String(localized: "Built for this Mac"),
                              detail: String(localized: "The new copy must run on this Mac's chip and macOS version, and natively if yours does.")))
        return marks
    }

    private func versionMark(_ candidate: UpdateCandidate) -> Hallmark {
        let line = "\(app.version.display) → \(candidate.displayVersion)"
        if candidate.isMajorUpgrade {
            return Hallmark(kind: .version, state: .caution, title: String(localized: "A major upgrade: \(line)"),
                            detail: String(localized: "It may be paid, so it's never part of Update All."))
        }
        if candidate.release.isCritical {
            return Hallmark(kind: .version, state: .confirmed, title: String(localized: "A security update: \(line)"),
                            detail: String(localized: "The developer marked this one as important."))
        }
        return Hallmark(kind: .version, state: .confirmed, title: String(localized: "Newer than yours: \(line)"),
                        detail: String(localized: "Burnish never installs an older version."))
    }
}

extension Hallmark {
    /// The headings of the full list: anything worth knowing first, then what's settled, what the
    /// install checks, what someone else checks, what this source can't offer, and last the way
    /// back, which is about afterwards.
    public enum Group: Int, Sendable, CaseIterable, Comparable {
        case worthKnowing, confirmed, checkedAtInstall, handedOff, notOffered, afterwards

        public static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }

        public var title: String {
            switch self {
            case .worthKnowing: String(localized: "Worth knowing")
            case .confirmed: String(localized: "Confirmed now")
            case .checkedAtInstall: String(localized: "Checked before it goes in")
            case .handedOff: String(localized: "Checked by whoever installs it")
            case .notOffered: String(localized: "Not offered by this source")
            case .afterwards: String(localized: "If you change your mind")
            }
        }
    }

    public var group: Group {
        if kind == .wayBack { return .afterwards }
        switch state {
        case .caution: return .worthKnowing
        case .confirmed: return .confirmed
        case .checkedAtInstall: return .checkedAtInstall
        case .handedOff: return .handedOff
        case .notAvailable: return .notOffered
        }
    }
}

extension Hallmark.Kind {
    /// The order a careful person asks in: where from, which version, who installs it, the
    /// install's own checks, then the way back.
    var step: Int {
        switch self {
        case .source: 0
        case .version: 1
        case .installedBy: 2
        case .signature: 3
        case .checksum: 4
        case .sameDeveloper: 5
        case .gatekeeper: 6
        case .runsHere: 7
        case .wayBack: 8
        }
    }

    /// Which marks earn a place up front when the list is folded.
    var weight: Int {
        switch self {
        case .source: 0
        case .installedBy: 1
        case .sameDeveloper: 2
        case .signature: 3
        case .version: 4
        case .checksum: 5
        case .gatekeeper: 6
        case .runsHere: 7
        case .wayBack: 8
        }
    }
}

extension Array where Element == Hallmark {
    /// Grouped under their headings, and in the order of the install within each group.
    public var inOrder: [Hallmark] {
        sorted { ($0.group.rawValue, $0.kind.step) < ($1.group.rawValue, $1.kind.step) }
    }

    /// The marks shown before "Show all": everything worth knowing, then the most telling of the
    /// rest, never one the source can't offer.
    public func leading(_ count: Int = 3) -> [Hallmark] {
        let cautions = filter { $0.state == .caution }
        let rest = filter { $0.state != .caution && $0.state != .notAvailable }.sorted { $0.kind.weight < $1.kind.weight }
        return (cautions + rest.prefix(Swift.max(0, count - cautions.count))).inOrder
    }
}
