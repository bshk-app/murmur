import SwiftUI
import WidgetKit

/// Layout QA of the actual widget view, without inference or fake model state.
struct WidgetPreviewView: View {
    let entry = MurMurEntry(date: .now, state: .init(source: "ru", target: "fi", status: "Inactive"))
    var body: some View {
        VStack(spacing: 24) {
            Text("Murmator widgets").font(.title2.bold())
            MurMurControlsContent(entry: entry, family: .systemSmall)
                .padding(16).frame(width: 170, height: 170).background(Color(red: 0.10, green: 0.08, blue: 0.065), in: RoundedRectangle(cornerRadius: 24))
            MurMurControlsContent(entry: entry, family: .systemMedium)
                .padding(16).frame(width: 360, height: 170).background(Color(red: 0.10, green: 0.08, blue: 0.065), in: RoundedRectangle(cornerRadius: 24))
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray.opacity(0.12))
    }
}
