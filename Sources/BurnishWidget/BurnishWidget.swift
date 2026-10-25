import Store
import SwiftUI
import WidgetKit
import WidgetUI

/// The desktop widget extension. Sandboxed: it reads only `widget.json`, which the app writes
/// after every check and then asks WidgetKit to reload.
@main
struct BurnishWidgets: WidgetBundle {
    var body: some Widget {
        UpdatesWidget()
    }
}

struct UpdatesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "io.github.enigmaticzee.Burnish.updates", provider: Provider()) { entry in
            EntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Burnish")
        .description("How many apps have updates waiting, and which.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snapshot: context.isPreview ? .sample : WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The app reloads the widget after each check; the hourly refresh only keeps "Checked …" honest.
        let entry = Entry(date: Date(), snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(3600))))
    }
}

struct EntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        UpdatesWidgetView(snapshot: entry.snapshot, size: family == .systemMedium ? .medium : .small)
    }
}
