import SwiftUI
import WidgetKit

struct MurMurControlsView: View {
    let entry: MurMurEntry
    @Environment(\.widgetFamily) private var family
    var body: some View { MurMurControlsContent(entry: entry, family: family) }
}
struct MurMurControlsContent: View {
    let entry: MurMurEntry
    let family: WidgetFamily
    private let accent = Color(red: 224/255, green: 122/255, blue: 47/255)
    var body: some View {
        Group {
            if family == .accessoryCircular {
                Image(systemName: "waveform").font(.title2).accessibilityLabel("Record a note")
            } else if family == .accessoryRectangular {
                VStack(alignment: .leading) { Label("Record a note", systemImage: "waveform").bold(); Text(entry.state.source.uppercased() + " → " + entry.state.target.uppercased()).font(.caption) }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(uiImage: UIImage(named: "MascotMark") ?? UIImage()).resizable().scaledToFit().frame(width: 18, height: 18).accessibilityHidden(true)
                        Text("Murmator").font(.system(size: 14, weight: .bold))
                        Spacer(minLength: 0)
                        if family == .systemMedium {
                            HStack(spacing: 3) { Text("Last update"); Text(entry.state.updatedAt, style: .time) }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    if family == .systemMedium { Text(LocalizedStringKey(entry.state.status)).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.72)).lineLimit(1) }
                    HStack(spacing: 7) {
                        action("Dictate", route: "record", primary: true)
                        action("Translate", route: "translate")
                        if family == .systemMedium { action("Keyboard", route: "keyboard") }
                    }
                    HStack(spacing: 7) {
                        action("Unload in Murmator", route: "release-memory")
                        if family == .systemMedium { action("Languages", route: "languages") }
                        action("Settings", route: "settings")
                    }
                }
            }
        }.containerBackground(Color(red: 23/255, green: 18/255, blue: 15/255), for: .widget)
            .foregroundStyle(.white).widgetURL(URL(string: "murmur://record"))
    }
    private func action(_ title: String, route: String, primary: Bool = false) -> some View {
        Link(destination: URL(string: "murmur://" + route)!) {
            VStack(alignment: .leading, spacing: 5) {
                Circle().fill(primary ? Color(red: 36/255, green: 31/255, blue: 28/255) : .white.opacity(0.34)).frame(width: primary ? 7 : 4, height: primary ? 7 : 4).accessibilityHidden(true)
                Text(LocalizedStringKey(title)).font(.system(size: 10, weight: .semibold)).lineLimit(title == "Unload in Murmator" ? 2 : 1).minimumScaleFactor(0.7).allowsTightening(true).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, minHeight: family == .systemMedium ? 31 : 36, alignment: .leading).padding(8)
                .foregroundStyle(primary ? Color(red: 36/255, green: 31/255, blue: 28/255) : .white)
                .background(primary ? accent : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
        }
    }
}
