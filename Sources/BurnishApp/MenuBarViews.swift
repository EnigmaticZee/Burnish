import AppKit
import BurnishCore
import SwiftUI

/// The menu bar item: an outline icon, the count beside it in the normal text colour (never red),
/// a gentle animation while checking, and a small dot when something needs the person.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.outdated.count
        HStack(spacing: 3) {
            Image(nsImage: MenuBarIcon.image(checking: model.isChecking, frame: model.animationFrame, dot: model.needsAppManagement))
            if count > 0 { Text("\(count)").monospacedDigit() }
        }
        .accessibilityLabel(count > 0 ? "Burnish, \(count) updates" : "Burnish")
        .modifier(WindowOpenerBridge())
    }
}

enum MenuBarIcon {
    /// The app icon's service bell as a template image, so macOS tints it for light, dark and
    /// highlighted menu bars. While checking, the bell rings: its arcs build up frame by frame.
    @MainActor
    static func image(checking: Bool, frame: Int, dot: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { rect in
            NSColor.black.set()
            // Base, dome and knob.
            NSBezierPath(roundedRect: NSRect(x: 2, y: 1.5, width: 14, height: 2), xRadius: 1, yRadius: 1).fill()
            let dome = NSBezierPath()
            dome.appendArc(withCenter: NSPoint(x: 9, y: 4.4), radius: 5.4, startAngle: 0, endAngle: 180)
            dome.close()
            dome.fill()
            NSBezierPath(rect: NSRect(x: 8.4, y: 9.4, width: 1.2, height: 1.6)).fill()
            NSBezierPath(ovalIn: NSRect(x: 7.1, y: 10.6, width: 3.8, height: 1.7)).fill()

            // Ringing: no arcs, then the inner pair, then both pairs.
            let rings = checking ? frame % 3 : 0
            for (index, radius) in [CGFloat(7.4), 9.2].enumerated() where index < rings {
                for (start, end) in [(CGFloat(32), CGFloat(58)), (122, 148)] {
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: NSPoint(x: 9, y: 5.6), radius: radius, startAngle: start, endAngle: end)
                    arc.lineWidth = 1.3
                    arc.lineCapStyle = .round
                    arc.stroke()
                }
            }

            // Something needs the person (App Management): a small dot at the bottom right.
            if dot {
                NSBezierPath(ovalIn: NSRect(x: rect.width - 5, y: 0, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Burnish"
        return image
    }
}

/// The popover under the menu bar item.
struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            banners
            content
            Divider()
            footer
        }
        .frame(width: 360)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Settings…") { NSApp.activate(ignoringOtherApps: true); openSettings() }
                Button("Check for Burnish Updates…") { SelfUpdater.shared.checkForUpdates() }
                Divider()
                Button("Quit Burnish") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .padding(12)
    }

    private var title: String {
        if model.isChecking && model.results.isEmpty { return "Checking…" }
        let count = model.outdated.count
        switch count {
        case 0: return "Up to date"
        case 1: return "1 update"
        default: return "\(count) updates"
        }
    }

    private var subtitle: String {
        if model.isChecking { return "Checked \(model.checkedCount) of \(model.totalCount) apps" }
        guard let last = model.lastCheck else { return "Not checked yet" }
        return "Checked \(last.relativeDescription)"
    }

    @ViewBuilder
    private var banners: some View {
        if let version = model.justUpdatedTo {
            Banner(text: "Burnish updated itself to \(version).", symbol: "bell", action: ("What's New", {
                NSWorkspace.shared.open(URL(string: "https://github.com/EnigmaticZee/Burnish/releases")!)
                model.justUpdatedTo = nil
            }))
        }
        if let offline = model.offlineBanner {
            Banner(text: offline, symbol: "wifi.slash")
        }
        if model.needsAppManagement {
            Banner(text: "Burnish needs App Management to replace apps.", symbol: "lock", action: ("Open Settings", Permissions.openAppManagement))
        }
        AppStoreBanner()
        if model.isChecking, model.totalCount > 0 {
            ProgressView(value: Double(model.checkedCount), total: Double(max(model.totalCount, 1)))
                .progressViewStyle(.linear)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var content: some View {
        let outdated = model.outdated
        if outdated.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text(model.isChecking ? "Looking for updates" : "Everything's up to date")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(outdated) { result in
                        PopoverRow(result: result)
                        if result.id != outdated.last?.id { Divider().padding(.leading, 50) }
                    }
                }
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: outdated.count < 6)
        }
    }

    private var footer: some View {
        HStack {
            Button("Update All") { Task { await model.updateAll() } }
                .disabled(!model.canUpdateAll)
                .help(UpdateAllHelp.text)
            Spacer()
            Button("Open Burnish") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            Button {
                Task { await model.check() }
            } label: {
                Label("Check Now", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
            }
            .disabled(model.isChecking)
            .help("Check Now")
        }
        .controlSize(.small)
        .padding(10)
    }
}

struct PopoverRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let result: AppCheckResult

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            AppIconView(url: result.app.url, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(result.app.name).font(.callout).lineLimit(1).layoutPriority(1)
                    if let source = result.status.candidate?.source { SourceBadge(source: source) }
                }
                HStack(spacing: 6) {
                    VersionLine(result: result).layoutPriority(1)
                    if result.status.candidate?.isMajorUpgrade == true { Tag(text: "May be paid") }
                }
                RefusalNote(result: result)
            }
            Spacer(minLength: 8)
            UpdateControl(result: result)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Show Details") {
                NSApp.activate(ignoringOtherApps: true)
                model.selectedID = result.id
                openWindow(id: "main")
            }
            Button("Ignore This Version") { Task { await model.ignoreVersion(result) } }
            Button("Ignore App") { Task { await model.ignoreApp(result) } }
        }
    }
}

struct Banner: View {
    let text: String
    let symbol: String
    var action: (String, () -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let action { Button(action.0, action: action.1).controlSize(.small) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4))
    }
}

/// Several App Store updates waiting: one trip to the App Store's Updates page instead of one per app.
struct AppStoreBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.appStoreUpdates.count
        if count >= 2 {
            Banner(text: "\(count) updates are waiting in the App Store.", symbol: "bag",
                   action: ("Open App Store", model.openAppStoreUpdates))
        }
    }
}

enum UpdateAllHelp {
    static let text = "Installs everything Burnish can update itself, except major upgrades that may be paid, then opens the App Store for App Store apps"
}

enum Permissions {
    /// System Settings → Privacy & Security → App Management.
    static func openAppManagement() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles") {
            NSWorkspace.shared.open(url)
        }
    }
}
