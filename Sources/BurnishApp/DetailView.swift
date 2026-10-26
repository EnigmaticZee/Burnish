import AppKit
import BurnishCore
import CaskIndex
import Store
import SwiftUI
import UpdateSources
import Versions

/// Versions, source and match confidence, release notes, and every action for one app.
struct DetailView: View {
    @Environment(AppModel.self) private var model
    let result: AppCheckResult
    @State private var showingPicker = false
    @State private var confirmingPutBack = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                confirmation
                supportRequest
                facts
                HallmarksSection(result: result)
                notes
                ReleaseNotesSection(result: result)
                RulesSection(result: result)
                HistorySection(result: result, putBack: model.restorableVersion(result).map { _ in { confirmingPutBack = true } })
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert(putBackTitle, isPresented: $confirmingPutBack) {
            Button("Put Back") { Task { await model.restore(result) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(result.app.version.display) goes to the Trash, and Burnish skips that version until a newer one comes out.")
        }
        .sheet(isPresented: $showingPicker) {
            CaskPicker(result: result) { token in
                showingPicker = false
                if let token { Task { await model.confirmMatch(result, token: token) } }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            AppIconView(url: result.app.url, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.app.name).font(.title2.weight(.semibold))
                Text(result.app.bundleID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 8) {
                    if result.status.isOutdated { UpdateControl(result: result, compact: false) }
                    actionsMenu
                }
                .padding(.top, 4)
                RefusalNote(result: result)
            }
            Spacer()
        }
    }

    private var actionsMenu: some View {
        Menu("More") {
            if case .ignored = result.status {
                Button("Stop Ignoring") { Task { await model.stopIgnoring(result) } }
            } else {
                if result.status.candidate != nil {
                    Button("Ignore This Version") { Task { await model.ignoreVersion(result) } }
                }
                Button("Ignore App") { Task { await model.ignoreApp(result) } }
            }
            if let version = model.restorableVersion(result) {
                Button("Put Back \(version)…") { confirmingPutBack = true }
            }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.app.url]) }
            if let updater = result.vendorUpdater {
                Button("Open \(updater.name)") { NSWorkspace.shared.open(updater.url) }
            }
            if let homepage = result.homepage {
                Button("Open Developer's Site") { NSWorkspace.shared.open(homepage) }
            }
            if result.canRequestSupport {
                Divider()
                Button("Request Support on GitHub…") { model.requestSupport(result) }
            }
            if !result.app.isAppStore {
                Divider()
                Menu("Wrong Match?") {
                    Button("Choose a Different Homebrew App…") { showingPicker = true }
                    if result.match != nil {
                        Button("Not This App") { Task { await model.rejectMatch(result) } }
                    }
                    Divider()
                    Button("Report a Wrong Match on GitHub…") { model.reportWrongMatch(result) }
                }
            }
        }
        .fixedSize()
    }

    /// For an app Burnish can't check: ask for it to be covered, ideally with where it posts updates.
    @ViewBuilder
    private var supportRequest: some View {
        if result.canRequestSupport {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Know where \(result.app.name) announces its updates? Ask for it to be added, and say where if you can.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Request Support on GitHub…") { model.requestSupport(result) }
                    Text("Opens a ready-made issue in your browser with the app's name, bundle ID and version. Nothing is sent until you submit it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    private var putBackTitle: String {
        String(localized: "Put back \(result.app.name) \(model.restorableVersion(result) ?? "")?")
    }

    @ViewBuilder
    private var confirmation: some View {
        if case let .needsConfirmation(match) = result.status {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(match.channelUnsure
                         ? "Several Homebrew entries fit \(result.app.name). Which one is installed?"
                         : "Is \(result.app.name) the app Homebrew calls “\(result.cask?.name ?? match.token)” (\(match.token))?")
                    HStack {
                        Button("Yes, That's It") { Task { await model.confirmMatch(result, token: match.token) } }
                            .keyboardShortcut(.defaultAction)
                        Button("No") { Task { await model.rejectMatch(result) } }
                        if !match.alternatives.isEmpty {
                            Menu("Other…") {
                                ForEach(match.alternatives.prefix(8), id: \.self) { token in
                                    Button(token) { Task { await model.confirmMatch(result, token: token) } }
                                }
                                Divider()
                                Button("Search Homebrew…") { showingPicker = true }
                            }
                            .fixedSize()
                        }
                    }
                    Text("Burnish only alerts you about updates once it's sure which app this is.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                label("Installed")
                Text(versionText(result.app.version.short, result.app.version.build)).monospacedDigit().textSelection(.enabled)
            }
            if let candidate = result.status.candidate {
                GridRow {
                    label("Latest")
                    HStack(spacing: 6) {
                        Text(versionText(candidate.version.short, candidate.version.build)).monospacedDigit().textSelection(.enabled)
                        if candidate.isMajorUpgrade { Tag(text: "Major upgrade, may be paid") }
                        if candidate.release.isCritical { Tag(text: "Security update", symbol: "exclamationmark.shield") }
                    }
                }
                if let date = candidate.release.date {
                    GridRow {
                        label("Released")
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                    }
                }
            }
            GridRow {
                label("Status")
                Text(statusText).fixedSize(horizontal: false, vertical: true)
            }
            if let automatic = automaticText {
                GridRow {
                    label("Automatic")
                    Text(automatic).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let source = result.status.candidate?.source ?? result.decidedBy {
                GridRow {
                    label("Source")
                    SourceBadge(source: source)
                }
            }
            if let match = result.match {
                GridRow {
                    label("Homebrew match")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(match.token) · \(confidenceText(match))")
                        Text(evidenceText(match)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let runsOn {
                GridRow {
                    label("Runs on")
                    Text(runsOn).foregroundStyle(result.app.isIntelOnly && model.isAppleSilicon ? .orange : .secondary)
                }
            }
            GridRow {
                label("Signed by")
                Text(signatureText).foregroundStyle(.secondary)
            }
            GridRow {
                label("Location")
                Text(result.app.url.deletingLastPathComponent().path).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var notes: some View {
        let lines = result.notes + (result.cask?.isUnmaintained == true && !result.notes.contains(String(localized: "No longer maintained in Homebrew"))
                                    ? [String(localized: "No longer maintained in Homebrew")] : [])
        if !lines.isEmpty || result.app.isManagedByHomebrew {
            VStack(alignment: .leading, spacing: 6) {
                if let token = result.app.caskroomToken {
                    Label("Managed by Homebrew. Burnish leaves updates to `brew upgrade --cask \(token)` unless you turn that on in Settings.",
                          systemImage: "shippingbox")
                }
                ForEach(lines, id: \.self) { Label($0, systemImage: "info.circle") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func versionText(_ short: String?, _ build: String?) -> String {
        switch (short, build) {
        case let (s?, b?) where s != b: "\(s) (\(b))"
        case let (s?, _): s
        case let (nil, b?): b
        default: "–"
        }
    }

    private var runsOn: String? {
        guard let archs = result.app.architectures, !archs.isEmpty else { return nil }
        let arm = archs.contains("arm64"), intel = archs.contains("x86_64")
        switch (arm, intel) {
        case (true, true): return String(localized: "Apple silicon and Intel")
        case (true, false): return String(localized: "Apple silicon")
        case (false, true): return model.isAppleSilicon ? String(localized: "Intel only, through Rosetta") : String(localized: "Intel")
        default: return nil
        }
    }

    /// When this update installs on its own, or why it won't; nothing when automatic updates are off for it.
    private var automaticText: String? {
        let rule = model.appRules.rule(for: result.app.bundleID)
        guard result.status.isOutdated, rule.updates == .automatic || (rule.updates == .followSettings && model.settings.autoUpdate)
        else { return nil }
        switch model.autoUpdateDecision(for: result) {
        case .install: return String(localized: "Installs on its own after the next check")
        case .wait(let until): return String(localized: "Installs on its own from \(until.formatted(date: .abbreviated, time: .omitted))")
        case .skip(let why): return String(localized: "Waits for you: \(why.lowercasedFirst)")
        }
    }

    private var statusText: String {
        switch result.status {
        case .outdated: String(localized: "Update available")
        case .upToDate(let note): note.map { String(localized: "Up to date. \($0)") } ?? String(localized: "Up to date")
        case .needsConfirmation: String(localized: "Needs confirmation")
        case .cantCheck(let reason): String(localized: "Can't check: \(reason)")
        case .ignored(.app, _): String(localized: "Ignored")
        case .ignored(.version(let v), _): String(localized: "Ignoring version \(v)")
        }
    }

    private func confidenceText(_ match: CaskMatch) -> String {
        switch match.confidence {
        case .confirmed: String(localized: "confirmed")
        case .high: String(localized: "high confidence")
        case .medium: String(localized: "medium confidence")
        case .low: String(localized: "low confidence")
        }
    }

    private func evidenceText(_ match: CaskMatch) -> String {
        let parts = match.evidence.map { e -> String in
            switch e {
            case .bundleIDQuit, .bundleIDHint: String(localized: "bundle ID")
            case .fileName: String(localized: "file name")
            case .displayName: String(localized: "name")
            case .userChoice: String(localized: "your choice")
            case .communityChoice: String(localized: "community fix")
            case .caskroom: String(localized: "installed by Homebrew")
            }
        }
        let list = ListFormatter.localizedString(byJoining: Array(NSOrderedSet(array: parts)) as? [String] ?? parts)
        return String(localized: "Matched by \(list)")
    }

    private var signatureText: String {
        let s = result.app.signature
        switch s.kind {
        case .developerID:
            return s.authority?.replacingOccurrences(of: "Developer ID Application: ", with: "")
                ?? String(localized: "Developer ID \(s.teamID ?? "")")
        case .appStore: return String(localized: "Mac App Store")
        case .apple: return String(localized: "Apple")
        case .development: return String(localized: "Development certificate (not distributed)")
        case .adHoc: return String(localized: "Not signed by a developer (Burnish won't replace it)")
        case .unsigned: return String(localized: "Unsigned (Burnish won't replace it)")
        case .other:
            if let team = s.teamID { return String(localized: "Team \(team)") }
            let who = s.authority ?? String(localized: "Unknown")
            return String(localized: "\(who) — no Team ID, so Burnish won't replace it")
        }
    }
}

/// Release notes from the source, rendered as plain SwiftUI text, never as a web page.
struct ReleaseNotesSection: View {
    @Environment(AppModel.self) private var model
    let result: AppCheckResult
    @State private var fetched: ReleaseNotesDocument?
    @State private var loading = false
    @State private var showFull = false

    var body: some View {
        if let release = result.status.candidate?.release {
            VStack(alignment: .leading, spacing: 10) {
                Text("What's New").font(.headline)
                if let doc = fetched ?? release.releaseNotes.flatMap(ReleaseNotesDocument.from), !doc.isEmpty {
                    let digest = ReleaseDigest.make(doc)
                    if let digest { QuickRead(digest: digest) }
                    DisclosureGroup(isExpanded: $showFull) {
                        ReleaseNotesView(document: doc).padding(.top, 6)
                    } label: {
                        Text(digest == nil ? "Release notes" : "Full release notes").font(.callout.weight(.medium))
                    }
                } else if loading {
                    ProgressView().controlSize(.small)
                } else if release.source == .homebrew {
                    Text("Homebrew doesn't carry release notes.").foregroundStyle(.secondary)
                } else {
                    Text("The developer didn't publish notes for this version.").foregroundStyle(.secondary)
                }
                if let missed = release.missed, !missed.isEmpty {
                    MissedVersions(missed: missed)
                }
                if let link = release.releaseNotes?.link ?? release.downloadPage, ["http", "https"].contains(link.scheme ?? "") {
                    Link(release.source == .homebrew ? "Open the developer's site" : "Open in browser", destination: link)
                        .font(.callout)
                }
            }
            .task(id: result.status.candidate?.displayVersion) { await fetchIfNeeded(release) }
        }
    }

    private func fetchIfNeeded(_ release: Release) async {
        fetched = nil
        showFull = false
        guard release.source == .sparkle, release.releaseNotes?.text == nil, let link = release.releaseNotes?.link else { return }
        loading = true
        fetched = await model.engine.releaseNotes(at: link)
        loading = false
    }
}

/// The summary card: a count of what changed and the first line of each kind, marked as
/// Burnish's reading of the developer's notes rather than the notes themselves.
struct QuickRead: View {
    let digest: ReleaseDigest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Quick read")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color(red: 0.80, green: 0.51, blue: 0.17).opacity(0.18)))
                    .foregroundStyle(Color(red: 0.70, green: 0.42, blue: 0.10))
                Text("Summary").font(.caption).foregroundStyle(.secondary)
            }
            Text(verbatim: digest.headline).font(.callout.weight(.semibold))
            ForEach(digest.highlights, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: Self.symbol(line.kind)).foregroundStyle(.secondary).frame(width: 16)
                    Text(verbatim: line.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Sorted from the developer's notes by Burnish; the full notes are below.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    static func symbol(_ kind: ReleaseDigest.Kind) -> String {
        switch kind {
        case .security: "lock.shield"
        case .new: "plus.circle"
        case .fix: "ladybug"
        case .improvement: "arrow.up.circle"
        }
    }
}

/// "What you missed": every version between the installed one and the newest, with its notes.
struct MissedVersions: View {
    let missed: [MissedRelease]

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(missed) { release in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Version \(release.version)").font(.callout.weight(.semibold))
                            if let date = release.date {
                                Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let doc = release.notes.flatMap(ReleaseNotesDocument.from), !doc.isEmpty {
                            ReleaseNotesView(document: doc)
                        } else if let link = release.notes?.link {
                            Link("Read the notes", destination: link).font(.callout)
                        } else {
                            Text("No notes for this version.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("You also skipped \(missed.count) versions").font(.callout.weight(.medium))
        }
    }
}

struct ReleaseNotesView: View {
    let document: ReleaseNotesDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, runs):
                    Text(attributed(runs)).font(level <= 2 ? .headline : .subheadline.weight(.semibold)).padding(.top, 4)
                case let .paragraph(runs):
                    Text(attributed(runs)).fixedSize(horizontal: false, vertical: true)
                case let .listItem(ordered, depth, runs):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: ordered.map { "\($0)." } ?? "•").foregroundStyle(.secondary)
                        Text(attributed(runs)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(depth) * 14)
                case let .code(text):
                    Text(text).font(.callout.monospaced()).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                case .rule:
                    Divider()
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private func attributed(_ runs: [ReleaseNotesDocument.Inline]) -> AttributedString {
        var out = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.bold { intent.insert(.stronglyEmphasized) }
            if run.italic { intent.insert(.emphasized) }
            if run.code { intent.insert(.code) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if let link = run.link { piece.link = link }
            out += piece
        }
        return out
    }
}

/// Search Homebrew's list and pick the right cask for an app.
struct CaskPicker: View {
    @Environment(AppModel.self) private var model
    let result: AppCheckResult
    let done: (String?) -> Void
    @State private var query = ""
    @State private var catalog: CaskCatalog?
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which Homebrew app is \(result.app.name)?").font(.headline)
            TextField("Search by name or token", text: $query).textFieldStyle(.roundedBorder)
            List(matches, id: \.token, selection: $selection) { cask in
                VStack(alignment: .leading, spacing: 2) {
                    Text(cask.names.first ?? cask.token)
                    (cask.disabled ? Text("\(cask.token) · \(cask.version) · no longer maintained") : Text("\(cask.token) · \(cask.version)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(cask.token)
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Use This App") { done(selection) }.keyboardShortcut(.defaultAction).disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 440, height: 400)
        .task {
            query = result.app.name
            catalog = await model.engine.catalog()
        }
    }

    private var matches: [Cask] { catalog?.search(query) ?? [] }
}

/// What Burnish has done with this app, newest first. Kept on this Mac.
struct HistorySection: View {
    @Environment(AppModel.self) private var model
    let result: AppCheckResult
    /// Offered when the latest update's earlier version can still be put back.
    let putBack: (() -> Void)?

    var body: some View {
        let events = model.history.events(for: result.app.bundleID)
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("History").font(.headline)
                    Spacer()
                    if let putBack, let version = model.restorableVersion(result) {
                        Button("Put Back \(version)…", action: putBack).controlSize(.small)
                    }
                }
                ForEach(events.prefix(12)) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: Self.symbol(event.kind)).foregroundStyle(.secondary).frame(width: 16)
                        Text(Self.text(event.kind)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(event.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }

    static func text(_ kind: HistoryEvent.Kind) -> String {
        switch kind {
        case let .found(version, source):
            String(localized: "Found \(version) (\(SourceKind(rawValue: source)?.label ?? source))")
        case let .updated(from, to, _, automatic, checks):
            updatedText(from: from, to: to, automatic: automatic == true, checks: checks ?? [])
        case let .restored(to, from, _):
            String(localized: "Put back \(to). \(from) went to the Trash and is skipped.")
        case let .handedOff(version, "homebrew"):
            String(localized: "Updated to \(version) with Homebrew")
        case let .handedOff(version, _):
            String(localized: "Opened the \(version) installer package in Installer")
        case let .refused(version, reason):
            String(localized: "Didn't install \(version): \(reason)")
        }
    }

    static func updatedText(from: String, to: String, automatic: Bool, checks: [String]) -> String {
        let names = checks.compactMap { Hallmark.Kind(rawValue: $0)?.checkName }
        let verified = names.isEmpty ? "" : " " + String(localized: "Checked: \(ListFormatter.localizedString(byJoining: names)).")
        return (automatic
            ? String(localized: "Updated \(from) → \(to) automatically.")
            : String(localized: "Updated \(from) → \(to).")) + verified
    }

    static func symbol(_ kind: HistoryEvent.Kind) -> String {
        switch kind {
        case .found: "bell"
        case .updated: "arrow.down.circle"
        case .restored: "arrow.uturn.backward.circle"
        case .handedOff: "shippingbox"
        case .refused: "exclamationmark.shield"
        }
    }
}

/// What Burnish vouches for about this update, before and during the install.
struct HallmarksSection: View {
    @Environment(AppModel.self) private var model
    let result: AppCheckResult
    @State private var showAll = false

    var body: some View {
        let marks = result.hallmarks(homebrew: model.settings.homebrewHandling).inOrder
        if !marks.isEmpty {
            let leading = marks.leading()
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Hallmarks").font(.headline)
                    Spacer()
                    if marks.count > leading.count {
                        Button(showAll ? String(localized: "Show fewer") : String(localized: "Show all \(marks.count)")) {
                            withAnimation(.easeInOut(duration: 0.2)) { showAll.toggle() }
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                    }
                }
                if showAll {
                    ForEach(Hallmark.Group.allCases, id: \.self) { group in
                        let inGroup = marks.filter { $0.group == group }
                        if !inGroup.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: group.title)
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(inGroup) { MarkRow(mark: $0, showsDetail: true) }
                            }
                        }
                    }
                } else {
                    ForEach(leading) { MarkRow(mark: $0, showsDetail: false) }
                }
            }
            .onChange(of: result.id) { _, _ in showAll = false }
        }
    }

    /// One mark: its seal and title, with the explanation underneath once the list is open, or
    /// on hover while it's folded.
    private struct MarkRow: View {
        let mark: Hallmark
        let showsDetail: Bool

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: HallmarksSection.symbol(mark.state))
                    .foregroundStyle(HallmarksSection.tint(mark.state))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: mark.title).font(.callout.weight(showsDetail ? .medium : .regular))
                    if showsDetail, !mark.detail.isEmpty {
                        Text(verbatim: mark.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .help(mark.detail.isEmpty ? HallmarksSection.stateText(mark.state) : mark.detail)
            .accessibilityElement(children: .combine)
            .accessibilityValue(HallmarksSection.stateText(mark.state))
        }
    }

    static func symbol(_ state: Hallmark.State) -> String {
        switch state {
        case .confirmed: "checkmark.seal.fill"
        case .checkedAtInstall: "checkmark.seal"
        case .handedOff: "arrow.right.circle"
        case .notAvailable: "minus.circle"
        case .caution: "exclamationmark.triangle"
        }
    }

    static func tint(_ state: Hallmark.State) -> Color {
        switch state {
        case .confirmed, .checkedAtInstall: Color(red: 0.80, green: 0.51, blue: 0.17)
        case .handedOff, .notAvailable: .secondary
        case .caution: .orange
        }
    }

    static func stateText(_ state: Hallmark.State) -> String {
        switch state {
        case .confirmed: String(localized: "Confirmed")
        case .checkedAtInstall: String(localized: "Checked during the install")
        case .handedOff: String(localized: "Checked by whoever installs it")
        case .notAvailable: String(localized: "Not offered by this source")
        case .caution: String(localized: "Worth knowing")
        }
    }
}

/// Choices for this app alone: install automatically or just tell me, stay on a major version,
/// follow betas. Nothing to choose for App Store apps or Apple's own.
struct RulesSection: View {
    @Environment(AppModel.self) private var model
    let result: AppCheckResult

    var body: some View {
        if !result.app.isAppStore, !result.app.isApple {
            let rule = model.appRules.rule(for: result.app.bundleID)
            let installedMajor = (result.app.version.short ?? result.app.version.build).flatMap(Version.init)?.major
            VStack(alignment: .leading, spacing: 8) {
                Text("Rules for this app").font(.headline)
                Picker("Updates", selection: binding(rule, \.updates)) {
                    ForEach(AppRule.Updates.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
                }
                .fixedSize()
                // Rapid-release apps (Firefox 158, Chrome 156) have no major worth staying on.
                if let major = rule.stayOnMajor ?? installedMajor, (1..<50).contains(major) {
                    Toggle("Stay on \(major).x", isOn: Binding(
                        get: { rule.stayOnMajor != nil },
                        set: { on in update(rule) { $0.stayOnMajor = on ? major : nil } }))
                }
                Toggle("Include beta releases", isOn: binding(rule, \.followBeta))
            }
            .font(.callout)
        }
    }

    private func binding<Value>(_ rule: AppRule, _ path: WritableKeyPath<AppRule, Value>) -> Binding<Value> {
        Binding(get: { rule[keyPath: path] }, set: { value in update(rule) { $0[keyPath: path] = value } })
    }

    private func update(_ rule: AppRule, _ change: (inout AppRule) -> Void) {
        var changed = rule
        change(&changed)
        Task { await model.setRule(changed, for: result) }
    }
}

extension String {
    /// "The app is open" → "the app is open", for joining after a colon.
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
