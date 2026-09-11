import SwiftUI
import MurmurCore

struct CorrectedTranscriptView: View {
    let display: CorrectionDisplay
    var size: CGFloat = 25
    var identifier = "corrected-transcript"
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flash = false
    @ScaledMetric(relativeTo: .title2) private var textScale: CGFloat = 1
    private var styled: AttributedString {
        let palette = MurmurPalette(scheme: scheme)
        var result = AttributedString()
        for run in display.runs {
            var part = AttributedString(run.text)
            part.foregroundColor = run.tone == .changed && flash ? MurmurPalette.accent : run.tone == .draft ? palette.secondary.opacity(0.6) : palette.ink
            part.font = .system(size: size * textScale, weight: run.tone == .draft ? .regular : .medium)
            result.append(part)
        }
        return result
    }
    private struct StyledBlock: Identifiable {
        let id: Int
        let text: AttributedString
    }
    private var blocks: [StyledBlock] {
        let value = styled
        var start = value.startIndex
        return TranscriptContent.blocks(display.text).map { block in
            let end = value.characters.index(start, offsetBy: block.text.count)
            defer { start = end }
            return StyledBlock(id: block.id, text: AttributedString(value[start..<end]))
        }
    }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                Text(block.text).lineSpacing(size * textScale * 0.35).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(block.id == 0 ? identifier : "\(identifier)-block-\(block.id)")
            }
        }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: flash)
            .task(id: display.correctionRevision) {
                flash = display.hasChanges
                do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
                flash = false
            }
    }
}
