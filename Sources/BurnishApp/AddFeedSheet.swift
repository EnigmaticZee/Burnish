import AppKit
import BurnishCore
import Store
import SwiftUI

/// Where an app announces its updates, typed by the person: a Sparkle appcast address or a GitHub
/// repository. Burnish reads such a feed to spot updates and leaves the install to the person,
/// the same as a community-listed feed, because the app itself never named it.
struct AddFeedSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let result: AppCheckResult
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where does \(result.app.name) announce its updates?").font(.headline)
            TextField("https://example.com/appcast.xml, or owner/repository on GitHub", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { add() }
            Text(hint)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Burnish reads the feed to tell you about new versions and opens the developer's page for the download. It never installs from a feed the app didn't name itself.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.userFeed(for: result) != nil {
                    Button("Remove Feed", role: .destructive) {
                        Task { await model.removeFeed(for: result) }
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.userFeed(for: result) == nil ? "Add" : "Change") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if let feed = model.userFeed(for: result) { text = feed.sparkle?.absoluteString ?? feed.github ?? "" }
        }
    }

    private var parsed: CommunityFeed? { Self.parse(text) }

    private var hint: String {
        switch parsed {
        case let feed? where feed.sparkle != nil: String(localized: "A Sparkle appcast at \(feed.label).")
        case let feed? where feed.github != nil: String(localized: "GitHub releases of \(feed.label).")
        default:
            text.trimmingCharacters(in: .whitespaces).isEmpty
                ? String(localized: "Appcast addresses start with https://. Many developers link them from their website or the app's release notes.")
                : String(localized: "That doesn't look like an HTTPS address or a GitHub repository yet.")
        }
    }

    private func add() {
        guard let feed = parsed else { return }
        Task { await model.addFeed(feed, for: result) }
        dismiss()
    }

    /// `owner/name`, a github.com repository link, or any other HTTPS address as an appcast.
    static func parse(_ raw: String) -> CommunityFeed? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let repoPattern = #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#
        if text.range(of: repoPattern, options: .regularExpression) != nil {
            return CommunityFeed(github: text)
        }
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        if host.lowercased() == "github.com" || host.lowercased() == "www.github.com" {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 2, !parts[1].hasSuffix(".xml") {
                var name = parts[1]
                if name.hasSuffix(".git") { name.removeLast(4) }
                return CommunityFeed(github: "\(parts[0])/\(name)")
            }
        }
        return CommunityFeed(sparkle: url)
    }
}

/// A line under the facts for an app whose feed the person added: where it points, and the
/// ways to change it or offer it to everyone.
struct UserFeedSection: View {
    @Environment(AppModel.self) private var model
    let result: AppCheckResult

    var body: some View {
        if let feed = model.userFeed(for: result) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label(feed.sparkle != nil
                          ? String(localized: "Watching the appcast at \(feed.label), which you added.")
                          : String(localized: "Watching the GitHub releases of \(feed.label), which you added."),
                          systemImage: "antenna.radiowaves.left.and.right")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Share This Feed…") { model.shareFeed(result) }
                        Button("Remove") { Task { await model.removeFeed(for: result) } }
                    }
                    .controlSize(.small)
                    Text("Sharing opens a ready-made issue on GitHub, so everyone with this app gets the feed. Burnish is made by one person, so additions land in batches.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }
}
