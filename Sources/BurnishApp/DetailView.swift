import AppKit
import BurnishCore
import CaskIndex
import SwiftUI
import UpdateSources

/// Versions, source and match confidence, release notes, and every action for one app (F9).
struct DetailView: View {
    @Environment(AppModel.self) private var model
    let result: AppCheckResult
    @State private var showingPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                confirmation
                facts
                notes
                ReleaseNotesSection(result: result)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.app.url]) }
            if let homepage = result.homepage {
                Button("Open Developer's Site") { NSWorkspace.shared.open(homepage) }
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
        let lines = result.notes + (result.cask?.isUnmaintained == true && !result.notes.contains("No longer maintained in Homebrew")
                                    ? ["No longer maintained in Homebrew"] : [])
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

    private func label(_ text: String) -> some View {
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

    private var statusText: String {
        switch result.status {
        case .outdated: "Update available"
        case .upToDate(let note): note.map { "Up to date. \($0)" } ?? "Up to date"
        case .needsConfirmation: "Needs your confirmation"
        case .cantCheck(let reason): "Can't check: \(reason)"
        case .ignored(.app, _): "Ignored"
        case .ignored(.version(let v), _): "Ignoring version \(v)"
        }
    }

    private func confidenceText(_ match: CaskMatch) -> String {
        switch match.confidence {
        case .confirmed: "confirmed"
        case .high: "high confidence"
        case .medium: "medium confidence"
        case .low: "low confidence"
        }
    }

    private func evidenceText(_ match: CaskMatch) -> String {
        let parts = match.evidence.map { e -> String in
            switch e {
            case .bundleIDQuit, .bundleIDHint: "bundle ID"
            case .fileName: "file name"
            case .displayName: "name"
            case .userChoice: "your choice"
            case .communityChoice: "community fix"
            case .caskroom: "installed by Homebrew"
            }
        }
        return "Matched by " + ListFormatter.localizedString(byJoining: Array(NSOrderedSet(array: parts)) as? [String] ?? parts)
    }

    private var signatureText: String {
        let s = result.app.signature
        switch s.kind {
        case .developerID: return s.authority?.replacingOccurrences(of: "Developer ID Application: ", with: "") ?? "Developer ID \(s.teamID ?? "")"
        case .appStore: return "Mac App Store"
        case .apple: return "Apple"
        case .development: return "Development certificate (not distributed)"
        case .adHoc: return "Not signed by a developer (Burnish won't replace it)"
        case .unsigned: return "Unsigned (Burnish won't replace it)"
        case .other: return s.teamID.map { "Team \($0)" } ?? "\(s.authority ?? "Unknown") — no Team ID, so Burnish won't replace it"
        }
    }
}

/// Release notes from the source, rendered as plain SwiftUI text, never as a web page.
struct ReleaseNotesSection: View {
    @Environment(AppModel.self) private var model
    let result: AppCheckResult
    @State private var fetched: ReleaseNotesDocument?
    @State private var loading = false

    var body: some View {
        if let release = result.status.candidate?.release {
            VStack(alignment: .leading, spacing: 8) {
                Text("What's New").font(.headline)
                if let doc = fetched ?? release.releaseNotes.flatMap(ReleaseNotesDocument.from), !doc.isEmpty {
                    ReleaseNotesView(document: doc)
                } else if loading {
                    ProgressView().controlSize(.small)
                } else if release.source == .homebrew {
                    Text("Homebrew doesn't carry release notes.").foregroundStyle(.secondary)
                } else {
                    Text("The developer didn't publish notes for this version.").foregroundStyle(.secondary)
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
        guard release.source == .sparkle, release.releaseNotes?.text == nil, let link = release.releaseNotes?.link else { return }
        loading = true
        fetched = await model.engine.releaseNotes(at: link)
        loading = false
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
                        Text(ordered.map { "\($0)." } ?? "•").foregroundStyle(.secondary)
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
                    Text("\(cask.token) · \(cask.version)\(cask.disabled ? " · no longer maintained" : "")")
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
