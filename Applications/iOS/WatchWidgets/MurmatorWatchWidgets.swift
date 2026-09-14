import SwiftUI
import WidgetKit

struct MurmatorComplicationEntry: TimelineEntry { let date: Date }

/// Nothing on this complication changes on its own. It offers one action, so the
/// timeline is a single entry that never needs refreshing.
struct MurmatorComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> MurmatorComplicationEntry { .init(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (MurmatorComplicationEntry) -> Void) {
        completion(.init(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MurmatorComplicationEntry>) -> Void) {
        completion(Timeline(entries: [.init(date: .now)], policy: .never))
    }
}

struct MurmatorComplicationView: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            if family == .accessoryRectangular {
                Label("Record a note", systemImage: "mic.fill")
            } else {
                Image(systemName: "mic.fill")
            }
        }
        // A tap on the face opens the app, which is the one behaviour every
        // watchOS version guarantees. An embedded button would be bypassed by
        // the launch on exactly the quick taps this complication exists for.
        .widgetURL(URL(string: "murmur://record"))
    }
}

struct MurmatorRecordComplication: Widget {
    let kind = "MurmatorWatchRecord"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MurmatorComplicationProvider()) { _ in
            MurmatorComplicationView().containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Record on Apple Watch")
        .description("Start a recording from the watch face.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular])
    }
}

@main struct MurmatorWatchWidgets: WidgetBundle {
    var body: some Widget { MurmatorRecordComplication() }
}
