import SwiftUI
import WatchKit

/// The watch half of the Murmator palette: the dark branch of the phone's tokens,
/// plus one colour the phone has no use for.
enum WatchPalette {
    static let accent = Color(red: 0.878, green: 0.478, blue: 0.184)
    static let accentText = Color(red: 0.941, green: 0.643, blue: 0.412)
    /// Recording. Deliberately not the system red: white on it measures 4.67:1
    /// against 3.1:1, and the label has to be read at a glance mid-sentence.
    static let recording = Color(red: 0.859, green: 0.196, blue: 0.153)
    static let onAccent = Color(red: 0.141, green: 0.122, blue: 0.110)
    static let background = Color(red: 0.082, green: 0.067, blue: 0.055)
    static let ink = Color.white.opacity(0.95)
    static let secondary = Color.white.opacity(0.68)
    static let muted = Color.white.opacity(0.46)
    static let card = Color.white.opacity(0.07)
    static let border = Color.white.opacity(0.12)
    static let track = Color.white.opacity(0.14)
    /// Always-On: the fill goes to an outline so the button is visible without lighting up.
    static let dimmedBorder = Color.white.opacity(0.24)
}

/// The design draws two columns, 205 pt for the 49 mm Ultra and 176 pt for 41 mm.
/// Everything between rounds to the nearer of the two rather than interpolating,
/// because the button heights are tuned against the screen, not scaled from it.
struct WatchMetrics {
    let wide: Bool
    init(width: CGFloat) { wide = width >= 190 }
    static var current: WatchMetrics { .init(width: WKInterfaceDevice.current().screenBounds.width) }

    var side: CGFloat { wide ? 12 : 10 }
    var bottom: CGFloat { wide ? 14 : 11 }
    var radius: CGFloat { wide ? 18 : 16 }
    /// The whole action zone when nothing sits under the button.
    var tallButton: CGFloat { wide ? 96 : 76 }
    /// Shortened to make room for a hint or an error underneath.
    var shortButton: CGFloat { wide ? 76 : 62 }
    var actionMinimum: CGFloat { wide ? 72 : 64 }
    var recordLabel: CGFloat { wide ? 19 : 17 }
    var stopLabel: CGFloat { wide ? 17 : 16 }
    var timer: CGFloat { wide ? 44 : 34 }
    var sentTimer: CGFloat { wide ? 34 : 28 }
    var dot: CGFloat { wide ? 9 : 8 }
    var hint: CGFloat { wide ? 13 : 12 }
    var hintSide: CGFloat { wide ? 16 : 14 }
    var transcriptTitle: CGFloat { wide ? 12 : 11 }
    var transcriptBody: CGFloat { wide ? 15 : 14 }
    var sendingLabel: CGFloat { wide ? 14 : 13 }
    var pillLabel: CGFloat { wide ? 16 : 15 }
    var mascot: CGFloat { wide ? 34 : 30 }
}

/// The microphone that sits above the label on the record button. Drawn rather
/// than taken from SF Symbols so its proportions match the design at every size.
struct MicrophoneGlyph: View {
    var height: CGFloat = 18
    private var capsuleWidth: CGFloat { height * 10 / 18 }
    private var cradleWidth: CGFloat { height }
    var body: some View {
        VStack(spacing: 0) {
            Capsule().frame(width: capsuleWidth, height: height)
            Cradle()
                .stroke(style: StrokeStyle(lineWidth: max(1.5, height / 9), lineCap: .round))
                .frame(width: cradleWidth, height: height * 8 / 18)
                .offset(y: -height * 4 / 18)
        }
        .accessibilityHidden(true)
    }
    private struct Cradle: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                              control: CGPoint(x: rect.midX, y: rect.maxY * 2))
            return path
        }
    }
}
