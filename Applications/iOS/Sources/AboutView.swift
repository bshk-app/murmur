import SwiftUI

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))"
    }
    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: version)
                Text("Recordings and transcripts are saved on this device.")
                Text("Speech recognition and translation run on your device. Murmator does not upload your recordings, notes or translation text.")
                Text("Language downloads require internet access.")
                Text("You choose what to share using the iOS share sheet. Device backups follow your system settings.")
            } header: { Text("Privacy") }
            Section {
                NavigationLink("Open-source licenses") { LicenseTextView() }
                if let source = Bundle.main.url(forResource: "BergamotSource", withExtension: "zip") {
                    ShareLink(item: source) { Label("Export Bergamot source code", systemImage: "square.and.arrow.up") }
                }
            } header: { Text("Open source") }
        }.navigationTitle("About Murmator").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("about-murmator")
    }
}

private struct LicenseTextView: View {
    @State private var text = ""
    var body: some View {
        LicenseTextContent(text: text).navigationTitle("Open-source licenses").navigationBarTitleDisplayMode(.inline)
            .task {
                guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") else { return }
                text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
    }
}

private struct LicenseTextContent: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true
        view.adjustsFontForContentSizeCategory = true
        view.font = .preferredFont(forTextStyle: .footnote)
        view.textContainerInset = .init(top: 16, left: 16, bottom: 16, right: 16)
        view.accessibilityIdentifier = "license-text"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) { if view.text != text { view.text = text } }
}
