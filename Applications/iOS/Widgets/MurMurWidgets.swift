import SwiftUI
import WidgetKit
import ActivityKit

struct MurMurProvider: TimelineProvider {
    func placeholder(in context: Context) -> MurMurEntry { MurMurEntry(date: .now, state: .init()) }
    func getSnapshot(in context: Context, completion: @escaping (MurMurEntry) -> Void) { completion(MurMurEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MurMurEntry>) -> Void) {
        completion(Timeline(entries: [MurMurEntry(date: .now)], policy: .after(.now.addingTimeInterval(900))))
    }
}
struct RecordWidget: Widget {
    let kind = "MurMurRecord"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MurMurProvider()) { MurMurControlsView(entry: $0) }
            .configurationDisplayName("Murmator controls")
            .description("Start dictation, translate, unload models, or change your languages. Controls open Murmator.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .systemSmall, .systemMedium])
    }
}
struct RecordingActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for:RecordingAttributes.self) { context in
            HStack(spacing:16) {
                Image(systemName:"waveform").font(.title2).foregroundStyle(.orange)
                VStack(alignment:.leading) {Text("Murmator").bold();Text(context.state.phase).font(.caption)}
                Spacer()
                Text(context.attributes.startedAt,style:.timer).monospacedDigit()
            }.padding().activityBackgroundTint(Color(red:0.08,green:0.07,blue:0.05)).activitySystemActionForegroundColor(.orange)
                .widgetURL(URL(string: context.attributes.keyboard == true ? "murmur://keyboard" : "murmur://record"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {Image(systemName:"waveform").foregroundStyle(.orange)}
                DynamicIslandExpandedRegion(.trailing) {Text(context.attributes.startedAt,style:.timer).monospacedDigit()}
                DynamicIslandExpandedRegion(.bottom) {Text("Murmator · \(context.state.phase)")}
            } compactLeading: {Image(systemName:"waveform").foregroundStyle(.orange)}
              compactTrailing: {Text(context.attributes.startedAt,style:.timer).monospacedDigit().frame(width:42)}
              minimal: {Image(systemName:"waveform").foregroundStyle(.orange)}
                .widgetURL(URL(string: context.attributes.keyboard == true ? "murmur://keyboard" : "murmur://record"))
        }
    }
}
@main struct MurMurWidgetBundle: WidgetBundle {
    var body: some Widget {RecordWidget();RecordingActivityWidget()}
}
