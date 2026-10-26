import AppKit
import BurnishCore
import SwiftUI

/// Burnish's own release notes, from the copy of HISTORY.md inside the app: the short version up
/// front, the full notes folded away, and earlier versions below. Nothing is fetched.
struct WhatsNewView: View {
    private let history = ReleaseHistory.bundled()
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    @State private var showFull = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("What's New in Burnish").font(.title2.weight(.semibold))
                        if let entry {
                            Text("Version \(entry.version) · \(Self.day(entry.date))").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                if let entry {
                    if !entry.headline.isEmpty {
                        Text(Self.inline(entry.headline)).font(.title3)
                    }
                    if !entry.short.isEmpty {
                        ShortVersion(lines: entry.short)
                    }
                    DisclosureGroup(isExpanded: $showFull) {
                        EntryNotes(entry: entry).padding(.top, 8)
                    } label: {
                        Text(entry.short.isEmpty ? "The notes" : "The full notes").font(.callout.weight(.medium))
                    }
                    if !earlier.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(earlier) { old in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(verbatim: "\(old.version) · \(Self.day(old.date))").font(.callout.weight(.semibold))
                                        if !old.headline.isEmpty { Text(Self.inline(old.headline)).foregroundStyle(.secondary) }
                                        EntryNotes(entry: old)
                                    }
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            Text("Earlier versions").font(.callout.weight(.medium))
                        }
                    }
                } else {
                    Text("This copy of Burnish doesn't include its release notes.").foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 540, height: 600)
        .modifier(RegularWhileOpen())
    }

    private var entry: ReleaseHistory.Entry? { history?.entry(for: version) }
    private var earlier: [ReleaseHistory.Entry] { (history?.entries ?? []).filter { $0.version != entry?.version } }

    /// "2026-10-25" as this Mac writes dates.
    static func day(_ iso: String) -> String {
        guard let date = try? Date(iso, strategy: .iso8601.year().month().day()) else { return iso }
        // Parsed as midnight UTC, so formatted in UTC too, or the day slips west of Greenwich.
        return date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: .gmt))
    }

    /// HISTORY.md's bold, italics, code and links.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// The "+ " lines: a few plain sentences for people who only skim.
private struct ShortVersion: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The short version")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color(red: 0.80, green: 0.51, blue: 0.17).opacity(0.18)))
                .foregroundStyle(Color(red: 0.70, green: 0.42, blue: 0.10))
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark.seal").foregroundStyle(.secondary).frame(width: 16)
                    Text(WhatsNewView.inline(line)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
    }
}

/// One version's items and closing paragraphs.
private struct EntryNotes: View {
    let entry: ReleaseHistory.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(entry.items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "•").foregroundStyle(.secondary)
                    Text(WhatsNewView.inline(item)).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(entry.paragraphs, id: \.self) { paragraph in
                Text(WhatsNewView.inline(paragraph)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }
}

/// While any of Burnish's windows is open, Burnish shows in the Dock and the app switcher like
/// any other app; with all of them closed it goes back to living in the menu bar.
struct RegularWhileOpen: ViewModifier {
    @MainActor private static var open = 0

    func body(content: Content) -> some View {
        content
            .onAppear {
                Self.open += 1
                NSApp.setActivationPolicy(.regular)
            }
            .onDisappear {
                Self.open = max(0, Self.open - 1)
                if Self.open == 0 { NSApp.setActivationPolicy(.accessory) }
            }
    }
}

/// Brings a window Burnish just asked SwiftUI to open in front of everything, which a menu bar
/// app otherwise can't count on: the window can appear behind the app you were using.
@MainActor
enum WindowFront {
    static func bring(_ matches: @escaping @MainActor (NSWindow) -> Bool) {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            for _ in 0..<10 {
                if let window = NSApp.windows.first(where: { $0.isVisible && matches($0) }) {
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    static func bring(id: String) {
        bring { $0.identifier?.rawValue == id }
    }

    /// SwiftUI gives its Settings window an identifier of its own making.
    static func bringSettings() {
        bring { $0.identifier?.rawValue.contains("Settings") == true || $0.frameAutosaveName.contains("Settings") }
    }
}
