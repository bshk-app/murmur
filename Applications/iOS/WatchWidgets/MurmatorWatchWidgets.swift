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

/// A watch face renders a complication as a mask, not as artwork: colours are the
/// face's to choose and anything filled collapses into a solid shape. The mascot
/// is a filled disc, so it reads as a blob here and stays inside the app. A
/// symbol is what this rendering mode is built for, and it survives every face.
struct MurmatorComplicationView: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                Label("Record a note", systemImage: "mic.fill")
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .accessoryCorner:
                Image(systemName: "mic.fill")
                    .font(.system(size: 20))
                    .widgetLabel { Text("Record a note") }
            default:
                // The ring is the brand at a glance; the face tints it with the
                // rest of the complication rather than taking our accent.
                Image(systemName: "mic.fill")
                    .font(.system(size: 22))
                    .padding(7)
                    .background(Circle().strokeBorder(lineWidth: 3).opacity(0.55))
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
