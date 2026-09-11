import SwiftUI
import MurmurCore

struct ConversationLogView: View {
    let conversation: RecordingTranscript
    let translations: [UtteranceTranslation]
    let translated: Bool
    let identifier: String
    @AppStorage("liveTranscriptFontSize") private var fontSize = 24.0
    @State private var following = true
    @State private var nearBottom = true
    @State private var userScrolled = false
    @State private var unread = false
    @Environment(\.colorScheme) private var scheme
    private var ready: [RecordedUtterance] {
        Array(conversation.utterances.prefix { $0.settled && (!translated || $0.translation != nil || $0.translationFailed == true) })
    }
    private var pendingText: String {
        let pending = conversation.utterances.dropFirst(ready.count)
        if !translated { return (pending.map(\.text) + [conversation.provisional]).filter { !$0.isEmpty }.joined(separator: " ") }
        let previews = Dictionary(translations.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        let text = pending.compactMap { utterance in previews[utterance.id].flatMap { $0.source == utterance.text ? $0.text : nil } }
        return (text + [previews[.max]?.text ?? ""]).filter { !$0.isEmpty }.joined(separator: " ")
    }
    var body: some View {
        let p = MurmurPalette(scheme: scheme)
        ScrollViewReader { proxy in
            VStack(spacing: 8) {
                HStack {
                    Button {
                        following = false; unread = false
                        if let first = ready.first { proxy.scrollTo(first.id, anchor: .top) }
                    } label: { Label("Beginning", systemImage: "arrow.up.to.line").frame(minHeight: 44).contentShape(Rectangle()) }.accessibilityIdentifier("transcript-beginning")
                    Spacer()
                    Menu {
                        Picker("Text size", selection: $fontSize) {
                            Text("Small").tag(20.0); Text("Medium").tag(24.0)
                            Text("Large").tag(28.0); Text("Extra large").tag(32.0)
                        }
                    } label: { Label("Text size", systemImage: "textformat.size").frame(minHeight: 44) }.accessibilityIdentifier("transcript-font-size")
                }.font(.footnote).frame(minHeight: 44).zIndex(1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(ready) { utterance in
                            UtteranceRow(utterance: utterance, translated: translated, size: fontSize,
                                         identifier: utterance.id == ready.first?.id ? identifier : "\(identifier)-utterance-\(utterance.id)")
                                .id(utterance.id)
                        }
                    }.padding(.trailing, 8).padding(.vertical, 8)
                }.contentShape(Rectangle()).clipped().accessibilityIdentifier("transcript-reader")
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.containerSize.height >= $0.contentSize.height + $0.contentInsets.bottom - 44 } action: { _, value in nearBottom = value }
                    .onScrollPhaseChange { _, phase in
                        if phase == .tracking || phase == .interacting { following = false; userScrolled = true }
                        if phase == .idle && userScrolled { following = nearBottom; userScrolled = false }
                    }
                    .onChange(of: ready.last?.id) {
                        if !following { unread = true }
                        Task { @MainActor in
                            await Task.yield()
                            if following, let last = ready.last { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                Button {
                    following = true; unread = false
                    if let last = ready.last { proxy.scrollTo(last.id, anchor: .bottom) }
                } label: {
                    Label(following ? "Following live text" : "Back to live text", systemImage: following ? "dot.radiowaves.left.and.right" : "arrow.down.to.line")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.font(.footnote).buttonStyle(.bordered).accessibilityIdentifier("transcript-latest")
                    .accessibilityValue(L10n.text(following ? "Following live text" : "Reading earlier text"))
                if unread && !following { Text("New text below").font(.caption).foregroundStyle(p.secondary).accessibilityIdentifier("transcript-unread") }
                // The revisable phrase has its own fixed viewport. It cannot move the log.
                if !pendingText.isEmpty {
                ScrollView {
                    Text(pendingText).font(.system(size: fontSize)).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).accessibilityIdentifier("pending-utterance-text")
                }.frame(maxWidth: .infinity).frame(height: 112).contentShape(Rectangle()).clipped()
                    .defaultScrollAnchor(.bottom, for: .sizeChanges)
                    .background(p.card2, in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(p.secondary)
                    .accessibilityIdentifier("current-utterance")
                }
            }
            .onAppear { if ![20.0, 24, 28, 32].contains(fontSize) { fontSize = 24 } }
        }
    }
}

struct UtteranceRow: View {
    let utterance: RecordedUtterance
    let translated: Bool
    var size: CGFloat = 24
    var identifier = "utterance"
    @ScaledMetric(relativeTo: .body) private var scale = 1.0
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(AudioImportJob.time(Double(utterance.startSample) / 16_000)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if translated && utterance.translationFailed == true { Text("Translation unavailable").font(.caption).foregroundStyle(.secondary) }
            Text(translated ? (utterance.translation ?? utterance.text) : utterance.text)
                .font(.system(size: size * scale)).lineSpacing(5).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
        }.padding(.vertical, 8)
    }
}
