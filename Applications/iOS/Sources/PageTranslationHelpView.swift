import SwiftUI

struct PageTranslationHelpView: View {
    var body: some View {
        List {
            Text(PageL10n.text("Open a webpage in Safari, tap Share, then choose Murmator."))
            Text(PageL10n.text("Choose languages and translate. Language packs are shared with the app."))
            Text(PageL10n.text("Close restores the original page. Newly loaded content may need another translation."))
            Text(PageL10n.text("Page text is processed on this device.")).foregroundStyle(.secondary)
        }.navigationTitle(PageL10n.text("Translate Safari pages")).navigationBarTitleDisplayMode(.inline)
    }
}
