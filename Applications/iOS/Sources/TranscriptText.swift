import SwiftUI
import MurmurCore

struct TranscriptText: View {
    let text: String
    var size: CGFloat = 20
    var weight: Font.Weight = .regular
    var identifier = "transcript-text"
    @ScaledMetric(relativeTo: .body) private var scale = 1.0
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(TranscriptContent.blocks(text)) { block in
                Text(block.text).font(.system(size: size * scale, weight: weight))
                    .lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(block.id == 0 ? identifier : "\(identifier)-block-\(block.id)")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TranscriptPreview: View {
    let text: String
    let identifier: String
    @ScaledMetric(relativeTo: .body) private var textSize = 16.0
    var body: some View {
        let blocks = TranscriptContent.blocks(text)
        ScrollViewReader { proxy in
            VStack(spacing: 4) {
                HStack {
                    Button("Beginning") { if let first = blocks.first { proxy.scrollTo(first.id, anchor: .top) } }.accessibilityIdentifier(identifier + "-beginning-button")
                    Spacer()
                    Button("End") { if let last = blocks.last { proxy.scrollTo(last.id, anchor: .bottom) } }.accessibilityIdentifier(identifier + "-end-button")
                }.font(.caption).buttonStyle(.borderless).frame(minHeight: 44).zIndex(1)
                ScrollView {
                    // This small nested reader needs measured heights for exact start/end jumps.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(blocks) { block in
                            Text(block.text).font(.system(size: textSize)).lineSpacing(5).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier(block.id == 0 ? identifier : "\(identifier)-block-\(block.id)")
                                .id(block.id)
                        }
                    }.padding(.trailing, 10)
                }.frame(height: 180).contentShape(Rectangle()).clipped()
                    .defaultScrollAnchor(.top, for: .initialOffset)
            }
        }
    }
}

/// A user-controlled reading position. New speech only moves the viewport while following.
struct LiveTranscriptReader: View {
    let text: String
    var display: CorrectionDisplay?
    let identifier: String
    @AppStorage("liveTranscriptFontSize") private var fontSize = 20.0
    @State private var followsLatest = true
    @State private var nearBottom = true
    @State private var userScrolled = false
    @State private var hasUnreadText = false
    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 6) {
                HStack {
                    Button {
                        followsLatest = false
                        hasUnreadText = false
                        proxy.scrollTo("start", anchor: .top)
                    } label: { Label("Beginning", systemImage: "arrow.up.to.line") }
                        .accessibilityIdentifier("transcript-beginning")
                    Spacer()
                    Menu {
                        Picker("Text size", selection: $fontSize) {
                            Text("Small").tag(18.0)
                            Text("Medium").tag(20.0)
                            Text("Large").tag(24.0)
                            Text("Extra large").tag(28.0)
                        }
                    } label: { Label("Text size", systemImage: "textformat.size") }
                        .accessibilityIdentifier("transcript-font-size")
                }.font(.footnote).buttonStyle(.borderless).frame(minHeight: 44)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        Color.clear.frame(height: 1).id("start")
                        if let display {
                            CorrectedTranscriptView(display: display, size: fontSize, identifier: identifier)
                        } else if text.isEmpty {
                            ProgressView("Waiting for translation…").padding(.vertical, 24)
                        } else {
                            TranscriptText(text: text, size: fontSize, identifier: identifier)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }.padding(.trailing, 10).padding(.vertical, 8)
                }
                .accessibilityIdentifier("transcript-reader")
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height + geometry.contentInsets.bottom - 44
                } action: { _, value in nearBottom = value }
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting { followsLatest = false; userScrolled = true }
                    if phase == .idle && userScrolled { followsLatest = nearBottom; userScrolled = false }
                }
                .onChange(of: text) {
                    if !followsLatest { hasUnreadText = true }
                    Task { @MainActor in
                        await Task.yield()
                        if followsLatest { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
                Button {
                    followsLatest = true
                    hasUnreadText = false
                    proxy.scrollTo("end", anchor: .bottom)
                } label: {
                    Label(followsLatest ? "Following live text" : "Back to live text", systemImage: followsLatest ? "dot.radiowaves.left.and.right" : "arrow.down.to.line")
                        .font(.footnote.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered).accessibilityIdentifier("transcript-latest")
                    .accessibilityValue(L10n.text(followsLatest ? "Following live text" : "Reading earlier text"))
                if hasUnreadText && !followsLatest {
                    Text("New text below").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("transcript-unread")
                }
            }
        }
    }
}
