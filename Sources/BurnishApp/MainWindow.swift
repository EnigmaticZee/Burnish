import AppKit
import BurnishCore
import SwiftUI

enum SortOrder: String, CaseIterable, Identifiable {
    case name, date
    var id: String { rawValue }
    var label: String { self == .name ? String(localized: "Name") : String(localized: "Date") }
}

/// Sidebar with the five tabs and counts, a sortable list, and the detail pane.
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @AppStorage("sortOrder") private var sort: SortOrder = .name

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(StatusTab.allCases, selection: $model.selectedTab) { tab in
                Label(tab.title, systemImage: tab.symbol)
                    .badge(model.count(tab))
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 215)
        } content: {
            ResultList(tab: model.selectedTab ?? .updates, search: search, sort: sort)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        } detail: {
            if let id = model.selectedID, let result = model.results.first(where: { $0.id == id }) {
                DetailView(result: result)
            } else {
                ContentUnavailableView("No App Selected", systemImage: "app.dashed")
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search apps")
        .toolbar {
            ToolbarItemGroup {
                Picker("Sort", selection: $sort) {
                    ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Sort by name or by date")
                Button {
                    Task { await model.check() }
                } label: {
                    Label("Check Now", systemImage: "arrow.clockwise")
                }
                .disabled(model.isChecking)
                Button {
                    Task { await model.updateAll() }
                } label: {
                    Label("Update All", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(!model.canUpdateAll)
                .help(UpdateAllHelp.text)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let offline = model.offlineBanner { Banner(text: offline, symbol: "wifi.slash") }
                if model.needsAppManagement {
                    Banner(text: String(localized: "Burnish needs App Management to replace apps."), symbol: "lock", action: (String(localized: "Open Settings"), Permissions.openAppManagement))
                }
                AppStoreBanner()
                if model.intelOnlyCount > 0 {
                    Banner(text: String(localized: "\(model.intelOnlyCount) apps only run on Intel chips, through Rosetta, which Apple is retiring for most apps after macOS 27."),
                           symbol: "cpu")
                }
                if model.isChecking {
                    Banner(text: String(localized: "Checked \(model.checkedCount) of \(model.totalCount) apps"), symbol: "arrow.clockwise")
                }
            }
        }
        .frame(minWidth: 820, minHeight: 480)
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

struct ResultList: View {
    @Environment(AppModel.self) private var model
    let tab: StatusTab
    let search: String
    let sort: SortOrder

    var body: some View {
        @Bindable var model = model
        let items = filtered
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: tab.symbol)
                } description: {
                    Text(emptyDescription)
                }
            } else {
                List(items, selection: $model.selectedID) { result in
                    ResultRow(result: result).tag(result.id)
                }
            }
        }
        .navigationTitle(tab.title)
        .navigationSubtitle(model.lastCheck.map { String(localized: "Checked \($0.relativeDescription)") } ?? "")
    }

    private var filtered: [AppCheckResult] {
        var items = model.results(in: tab)
        if !search.isEmpty {
            items = items.filter {
                $0.app.name.localizedCaseInsensitiveContains(search) || $0.app.bundleID.localizedCaseInsensitiveContains(search)
            }
        }
        switch sort {
        case .name:
            items.sort { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
        case .date:
            func date(_ r: AppCheckResult) -> Date { r.status.candidate?.release.date ?? r.app.modificationDate ?? .distantPast }
            items.sort { date($0) > date($1) }
        }
        return items
    }

    private var emptyTitle: String {
        switch tab {
        case .updates: String(localized: "Everything's up to date")
        case .upToDate: String(localized: "Nothing here yet")
        case .needsConfirmation: String(localized: "Nothing to confirm")
        case .cantCheck: String(localized: "Every app has a source")
        case .ignored: String(localized: "Nothing ignored")
        }
    }

    private var emptyDescription: String {
        switch tab {
        case .updates: model.lastCheck.map { String(localized: "Checked \($0.relativeDescription).") } ?? String(localized: "Burnish hasn't checked yet.")
        case .upToDate: String(localized: "Apps with no update waiting show here.")
        case .needsConfirmation: String(localized: "When Burnish isn't sure which Homebrew entry is an app, it asks here.")
        case .cantCheck: String(localized: "Apps Burnish can't find an update source for show here, with the reason.")
        case .ignored: String(localized: "Apps and versions you ignore show here.")
        }
    }
}

struct ResultRow: View {
    @Environment(AppModel.self) private var model
    let result: AppCheckResult

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(url: result.app.url, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(result.app.name).lineLimit(1).layoutPriority(1)
                    if let source = result.status.candidate?.source ?? result.decidedBy { SourceBadge(source: source) }
                }
                HStack(spacing: 6) {
                    VersionLine(result: result).layoutPriority(1)
                    if result.status.candidate?.isMajorUpgrade == true, result.status.isOutdated { Tag(text: "May be paid") }
                    if model.isAppleSilicon, result.app.isIntelOnly { Tag(text: "Intel", symbol: "cpu") }
                    if result.app.isManagedByHomebrew { Text("Installed by Homebrew").font(.caption).foregroundStyle(.secondary) }
                }
                if let line = secondaryLine {
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                RefusalNote(result: result)
            }
            Spacer(minLength: 8)
            if result.status.isOutdated { UpdateControl(result: result) }
        }
        .padding(.vertical, 3)
    }

    private var secondaryLine: String? {
        switch result.status {
        case .cantCheck(let reason): reason
        case .needsConfirmation(let match): String(localized: "Is this Homebrew's \(match.token)?")
        case .ignored(.version(let v), _): String(localized: "Ignoring version \(v)")
        case .ignored(.app, _): String(localized: "Ignored")
        case .upToDate(let note): note
        case .outdated: nil
        }
    }
}
