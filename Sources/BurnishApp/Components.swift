import AppKit
import BurnishCore
import CaskIndex
import Installer
import SwiftUI
import UpdateSources

/// App icons from Finder, cached by path.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for url: URL) -> NSImage {
        if let cached = cache[url.path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        cache[url.path] = icon
        return icon
    }

    static func forget(_ url: URL) { cache[url.path] = nil }
}

struct AppIconView: View {
    let url: URL
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: AppIcons.icon(for: url))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// "Homebrew", "Developer feed", "App Store", "GitHub".
struct SourceBadge: View {
    let source: SourceKind

    var body: some View {
        Text(source.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(.quaternary.opacity(0.6)))
            .fixedSize()
    }
}

/// A quiet tag, like "May be paid".
struct Tag: View {
    let text: LocalizedStringKey
    var symbol: String?

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let symbol { Image(systemName: symbol) }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(Capsule().strokeBorder(.orange.opacity(0.5)))
        .fixedSize()
    }
}

/// `1.0 → 1.1`, or just the installed version.
struct VersionLine: View {
    let result: AppCheckResult

    var body: some View {
        HStack(spacing: 4) {
            Text(result.app.version.display)
            if let candidate = result.status.candidate {
                Image(systemName: "arrow.right").imageScale(.small)
                Text(candidate.displayVersion).fontWeight(.medium)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// The Update button, or progress, or the result of an install.
struct UpdateControl: View {
    @Environment(AppModel.self) private var model
    let result: AppCheckResult
    var compact = true

    var body: some View {
        switch model.installStates[result.id] {
        case .running(let phase)?:
            HStack(spacing: 6) {
                if let fraction = phase.fraction {
                    ProgressView(value: fraction).frame(width: 46)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(phase.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        case .done(let relaunched)?:
            Label(relaunched ? "Done, relaunched" : "Done", systemImage: "checkmark")
                .font(.caption).foregroundStyle(.secondary)
        case .openedInstaller?:
            Label("Opened in Installer", systemImage: "shippingbox")
                .font(.caption).foregroundStyle(.secondary)
        case .refused(let refusal)?:
            Button("Download Page") {
                if let url = refusal.downloadPage ?? result.downloadPage { NSWorkspace.shared.open(url) }
            }
            .controlSize(.small)
            .help(refusal.message)
        case .failed(let message)?:
            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(message)
        case nil:
            button
        }
    }

    @ViewBuilder
    private var button: some View {
        let action = model.action(for: result)
        switch action {
        case .none:
            EmptyView()
        case .managedByHomebrew(let token):
            Text("Managed by Homebrew")
                .font(.caption).foregroundStyle(.secondary)
                .help("Update with `brew upgrade --cask \(token)`, or turn on Homebrew updates in Settings.")
        default:
            Button(action.buttonTitle) { Task { await model.update(result) } }
                .controlSize(compact ? .small : .regular)
                .disabled(action == .install && !model.isOnline)
                .help(helpText(action))
        }
    }

    private func helpText(_ action: UpdateAction) -> String {
        switch action {
        case .install: String(localized: "Download, verify and install \(result.status.candidate?.displayVersion ?? "")")
        case .openAppStore: String(localized: "Open in the App Store")
        case .openUpdater(let updater): String(localized: "Open \(updater.name), which keeps this app up to date")
        case .openDownloadPage(_, let reason): reason
        case .brewUpgrade(let token): String(localized: "Run brew upgrade --cask \(token)")
        default: ""
        }
    }
}

/// The refusal reason under a row, in plain words.
struct RefusalNote: View {
    @Environment(AppModel.self) private var model
    let result: AppCheckResult

    var body: some View {
        if case .refused(let refusal)? = model.installStates[result.id] {
            Label(refusal.message, systemImage: "exclamationmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension Date {
    var relativeDescription: String {
        let interval = Date().timeIntervalSince(self)
        if interval < 60 { return String(localized: "just now") }
        return RelativeDateTimeFormatter().localizedString(for: self, relativeTo: Date())
    }
}
