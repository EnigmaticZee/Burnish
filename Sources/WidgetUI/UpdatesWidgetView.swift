import AppKit
import Store
import SwiftUI

/// The desktop widget: how many apps have updates, and in the medium size the first three.
/// Shared by the widget extension and the app's preview renderer.
public struct UpdatesWidgetView: View {
    public enum Size { case small, medium }

    let snapshot: WidgetSnapshot?
    let size: Size

    public init(snapshot: WidgetSnapshot?, size: Size) {
        self.snapshot = snapshot
        self.size = size
    }

    /// Brass, from the app icon.
    static let brass = Color(red: 0.80, green: 0.51, blue: 0.17)

    public var body: some View {
        if let snapshot {
            HStack(alignment: .top, spacing: 16) {
                summary(snapshot)
                if size == .medium, !snapshot.top.isEmpty {
                    list(snapshot)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "bell").font(.title2).foregroundStyle(Self.brass)
                Spacer(minLength: 0)
                Text("Open Burnish to check your apps").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func summary(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: snapshot.updateCount > 0 ? "bell" : "checkmark.circle")
                .font(.title2)
                .foregroundStyle(snapshot.updateCount > 0 ? Self.brass : .secondary)
            Spacer(minLength: 0)
            if snapshot.updateCount > 0 {
                Text(snapshot.updateCount, format: .number)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                // The number sits big above, so this line leaves it out. Catalogs can't pluralise a
                // string without its number, so one and several are separate strings.
                (snapshot.updateCount == 1 ? Text("update waiting") : Text("updates waiting"))
                    .font(.callout.weight(.medium))
            } else {
                Text("Up to date").font(.title3.weight(.semibold))
            }
            if let lastCheck = snapshot.lastCheck {
                Text("Checked \(lastCheck.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: size == .medium ? 130 : .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func list(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(snapshot.top) { item in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.appPath))
                        .resizable()
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: item.name).font(.callout.weight(.medium)).lineLimit(1)
                        Text(verbatim: "\(item.installed) → \(item.latest)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            }
            if snapshot.updateCount > snapshot.top.count {
                Text("and \(snapshot.updateCount - snapshot.top.count) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension WidgetSnapshot {
    /// What the widget gallery shows before a real check.
    public static let sample = WidgetSnapshot(
        updateCount: 4,
        top: [
            Item(name: "Firefox", installed: "157.0.2", latest: "158.0.1", appPath: "/Applications/Firefox.app"),
            Item(name: "Discord", installed: "0.0.416", latest: "0.0.419", appPath: "/Applications/Discord.app"),
            Item(name: "Figma", installed: "126.9.16", latest: "126.10.11", appPath: "/Applications/Figma.app"),
        ],
        lastCheck: Date().addingTimeInterval(-25 * 60)
    )
}
