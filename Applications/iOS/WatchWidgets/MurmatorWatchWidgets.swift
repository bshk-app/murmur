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

private enum ComplicationPalette {
    /// The ring is the brand at a glance; at complication sizes a filled shape
    /// would read as a blob, so the accent lives in the stroke.
    static let ring = Color(red: 0.878, green: 0.478, blue: 0.184).opacity(0.55)
    static let mark = Color.white.opacity(0.95)
    static let plate = Color.white.opacity(0.07)
}

private struct ComplicationMark: View {
    var size: CGFloat
    var body: some View {
        Image("MascotMark")
            .resizable().scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(ComplicationPalette.mark)
    }
}

struct MurmatorComplicationView: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                HStack(spacing: 11) {
                    ComplicationMark(size: 26)
                    Text("Record a note")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(ComplicationPalette.mark)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 11).padding(.horizontal, 12)
                .background(ComplicationPalette.plate, in: RoundedRectangle(cornerRadius: 14))
            case .accessoryCorner:
                ComplicationMark(size: 20)
                    .widgetLabel { Text("Record a note") }
            default:
                ComplicationMark(size: 22)
                    .padding(6)
                    .background(Circle().strokeBorder(ComplicationPalette.ring, lineWidth: 3))
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
