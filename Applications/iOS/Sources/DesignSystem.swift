import SwiftUI
import MurmurCore

extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255, opacity: 1) }
}
struct MurmurPalette {
    let scheme: ColorScheme
    static let accent = Color(hex: 0xe07a2f)
    var accentText: Color { Color(hex: scheme == .dark ? 0xf0a469 : 0xc9722c) }
    var sheet: Color { Color(hex: scheme == .dark ? 0x1e1916 : 0xfffdf9) }
    var background: Color { Color(hex: scheme == .dark ? 0x15110e : 0xfaf7f2) }
    var card: Color { scheme == .dark ? Color.white.opacity(0.07) : Color(hex: 0xfffdf9) }
    var ink: Color { scheme == .dark ? .white.opacity(0.95) : Color(hex: 0x2a2520) }
    var secondary: Color { scheme == .dark ? .white.opacity(0.68) : Color(hex: 0x4a3e34).opacity(0.74) }
    var muted: Color { scheme == .dark ? .white.opacity(0.46) : Color(hex: 0x4a3e34).opacity(0.52) }
    var card2: Color { scheme == .dark ? .white.opacity(0.1) : Color(hex: 0x3c2814).opacity(0.07) }
    var border: Color { scheme == .dark ? .white.opacity(0.12) : Color(hex: 0x3c2814).opacity(0.11) }
}
struct MurmurCard: ViewModifier {
    var radius: CGFloat = 15
    var padding: CGFloat = 14
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let palette = MurmurPalette(scheme: scheme)
        content.padding(padding).background(palette.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(palette.border, lineWidth: 1))
    }
}
extension View { func murmurCard(radius: CGFloat = 15, padding: CGFloat = 14) -> some View { modifier(MurmurCard(radius: radius, padding: padding)) } }

struct PrimaryButton: View {
    let title: LocalizedStringKey
    var symbol: String? = nil
    var quiet = false
    let action: () -> Void
    var body: some View { DesignButton(title: title, symbol: symbol, kind: quiet ? .secondary : .primary, action: action) }
}

enum DesignTone { case neutral, accent, success, error }
struct StatusTag: View {
    private let label: Text
    var tone = DesignTone.neutral
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .caption) private var size = 11.5
    init(title: LocalizedStringKey, tone: DesignTone = .neutral) { label = Text(title); self.tone = tone }
    /// For values the app formats itself — durations, counts — which must not go through the strings table.
    init(value: String, tone: DesignTone = .neutral) { label = Text(value); self.tone = tone }
    private var color: Color {
        let p = MurmurPalette(scheme: scheme)
        switch tone { case .neutral: return p.secondary; case .accent: return p.accentText; case .success: return scheme == .dark ? Color(hex: 0x8dcca1) : Color(hex: 0x1f6640); case .error: return scheme == .dark ? Color(hex: 0xf0a194) : Color(hex: 0xa52a17) }
    }
    var body: some View { label.font(.system(size: size, weight: .semibold)).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 9).padding(.vertical, 4).foregroundStyle(color).background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 6)) }
}
/// The button chrome on its own, so controls that cannot be a Button — a Menu label — still look like one.
struct DesignButtonSurface: ViewModifier {
    var kind = DesignButton.Kind.primary
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @ScaledMetric(relativeTo: .body) private var size = 15.0
    func body(content: Content) -> some View {
        let p = MurmurPalette(scheme: scheme)
        let destructiveText = Color(hex: scheme == .dark ? 0xf0a194 : 0xc0341f)
        content
            .font(.system(size: size, weight: .semibold)).multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 13).frame(maxWidth: .infinity, minHeight: kind == .link ? 44 : 48)
            .foregroundStyle(!enabled ? p.muted : kind == .primary ? Color(hex: 0x241f1c) : kind == .destructive ? destructiveText : kind == .link ? p.accentText : p.ink)
            .background(enabled && kind == .primary ? MurmurPalette.accent : kind == .link || kind == .destructive ? .clear : p.card2, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(kind == .destructive ? destructiveText.opacity(0.32) : kind == .secondary || !enabled ? p.border : .clear))
    }
}
extension View {
    func designButtonSurface(_ kind: DesignButton.Kind = .primary) -> some View { modifier(DesignButtonSurface(kind: kind)) }
}
struct DesignButton: View {
    enum Kind { case primary, secondary, destructive, link }
    let title: LocalizedStringKey
    var symbol: String? = nil
    var kind = Kind.primary
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) { if let symbol { Image(systemName: symbol) }; Text(title).fixedSize(horizontal: false, vertical: true) }
                .designButtonSurface(kind)
        }.buttonStyle(.plain)
    }
}
struct ProgressTrack: View {
    var value: Double?
    var tone = DesignTone.accent
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(MurmurPalette(scheme: scheme).card2)
                if let value {
                    Capsule().fill(tone == .success ? Color(hex: 0x2e7a4a) : tone == .error ? Color(hex: 0xc0341f) : MurmurPalette.accent).frame(width: proxy.size.width * min(1, max(0, value)))
                } else {
                    TimelineView(.animation(minimumInterval: 0.04, paused: reduceMotion)) { tick in
                        let phase = reduceMotion ? 0.35 : (sin(tick.date.timeIntervalSinceReferenceDate * .pi / (tone == .neutral ? 1.5 : 0.75)) + 1) / 2
                        Capsule().fill(tone == .neutral ? MurmurPalette(scheme: scheme).secondary : MurmurPalette.accent).frame(width: proxy.size.width * 0.3).offset(x: proxy.size.width * 0.7 * phase)
                    }
                }
            }
        }.frame(height: 8).accessibilityElement(children: .ignore).accessibilityLabel("Transcription progress")
            .accessibilityValue(value.map { String(Int($0 * 100)) + "%" } ?? L10n.text("Preparing…"))
    }
}
struct NoteBadge: View {
    let text: String
    @ScaledMetric(relativeTo: .caption) private var size = 11.5
    var body: some View { Text(text).font(.system(size: size, weight: .medium)).tracking(size * 0.05).foregroundStyle(MurmurPalette.accent).padding(.horizontal, 9).padding(.vertical, 5).background(MurmurPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6)) }
}
enum AppLanguages {
    static var all: [(code: String, name: String)] {
        (SpeechModelChoice.parakeetLanguages.union(SpeechModelChoice.whisperLanguages).union(["ar"])).sorted().map { code in
            (code, Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code.uppercased())
        }
    }
    static func name(_ code: String) -> String { Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code.uppercased() }
}

struct PackStatusBadge: View {
    let title: LocalizedStringKey
    var ready = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text(title).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(ready ? MurmurPalette.accent : MurmurPalette(scheme: scheme).secondary)
            .background(ready ? MurmurPalette.accent.opacity(0.14) : MurmurPalette(scheme: scheme).card2, in: RoundedRectangle(cornerRadius: 8))
    }
}
