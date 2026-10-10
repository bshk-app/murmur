import AppKit

/// The live transcript drawn at the caret, as if it were already typed
/// there - KeyType's ghost text, applied to dictation. Nothing reaches the
/// app until the take ends: what is drawn while you speak is the fast lane's
/// draft, the text pasted at the end is the corrected one, and typing the
/// draft in would mean erasing it again inside someone else's field.
///
/// Everything here is geometry and type, so it is tested without a screen;
/// `HUDController` asks Accessibility and `HUDView` draws.

/// A recognised word. Confirmed words are settled; the rest can still change
/// while you speak.
struct GhostWord: Equatable {
    var text: String
    var confirmed: Bool

    /// The HUD's two tiers as words, in reading order.
    static func words(confirmed: String, partial: String) -> [GhostWord] {
        split(confirmed).map { GhostWord(text: $0, confirmed: true) }
            + split(partial).map { GhostWord(text: $0, confirmed: false) }
    }

    private static func split(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }
}

/// What the focused field says about its type. `size` is in the app's own
/// units, which a zoomed web page draws larger than it says.
struct FieldFont: Equatable {
    var name: String?
    var size: CGFloat
}

/// Where the ghost text can go for one caret, in AppKit screen coordinates.
/// Fixed while the caret stays put, so the window under it does not resize
/// with every word.
struct GhostGeometry: Equatable {
    /// The first line starts at `caret.minX`.
    var caret: CGRect
    var lineHeight: CGFloat
    /// The bottom of the caret's line box.
    var baseY: CGFloat
    /// Where wrapped lines start, and where every line ends.
    var leftEdge: CGFloat
    var rightEdge: CGFloat
    /// The caret's line and the ones below it that are on screen.
    var maxLines: Int
    /// Everything a line, backing included, can cover.
    var region: CGRect
}

/// One line of ghost text.
struct GhostLine: Equatable {
    /// Where its text starts, and the bottom of its line box.
    var origin: CGPoint
    var words: [GhostWord]
    /// Leads with an ellipsis: earlier words did not fit.
    var elided: Bool
    /// Ends with the live marker - the bars, or the dots once the microphone
    /// is off - which stands in for the app's own caret.
    var hasMarker: Bool
    /// Text and marker as measured, without the backing's padding.
    var width: CGFloat
    /// The text's width when it does not all fit: it is cut from the left,
    /// keeping the end of what was said.
    var clip: CGFloat? = nil
}

enum GhostText {
    /// Past this the draft scrolls: older words give way to an ellipsis. Three
    /// lines are enough to judge what is being heard without covering the
    /// window.
    static let maxLines = 3
    /// The backing reaches this far past the text on either side.
    static let padding: CGFloat = 4
    static let markerGap: CGFloat = 5
    /// Line length for a field that does not say how wide it is.
    static let fallbackWidth: CGFloat = 520
    static let minLineWidth: CGFloat = 160
    static let ellipsis = "\u{2026}"

    /// `lineHeight` is the field's line pitch (`lineHeight(caret:font:)`).
    /// A `singleLine` field never wraps: its draft keeps to the caret's line,
    /// showing the newest words, rather than spilling over whatever is below.
    static func geometry(caret: CGRect, field: CGRect?, singleLine: Bool = false, lineHeight lh: CGFloat,
                         visible: CGRect) -> GhostGeometry {
        let usable = visible.insetBy(dx: padding, dy: 0)
        let base = min(max((caret.midY - lh / 2).rounded(), visible.minY), visible.maxY - lh)
        var left: CGFloat, right: CGFloat
        if let field, field.width >= minLineWidth {
            // A field's frame includes its padding. A caret close to its left
            // edge is where its lines start; otherwise guess the padding.
            left = caret.minX - field.minX <= 2 * lh ? caret.minX : field.minX + padding
            right = field.maxX - padding
        } else {
            left = caret.minX
            right = caret.minX + fallbackWidth
        }
        // A single line has nowhere else to go: one ending at the caret gets
        // room past the field's edge, as the field would scroll to make.
        if singleLine { right = max(right, caret.minX + minLineWidth) }
        right = min(right, usable.maxX)
        left = max(min(left, caret.minX), usable.minX)
        if right - left < minLineWidth { left = max(usable.minX, right - minLineWidth) }
        let below = Int(((base - visible.minY) / lh).rounded(.down))
        let maxLines = singleLine ? 1 : max(1, min(Self.maxLines, 1 + below))
        let bottom = base - CGFloat(maxLines - 1) * lh
        let minX = min(left, caret.minX) - padding
        let maxX = max(right, caret.minX) + padding
        return GhostGeometry(caret: caret, lineHeight: lh, baseY: base, leftEdge: left, rightEdge: right,
                             maxLines: maxLines,
                             region: CGRect(x: minX, y: bottom, width: maxX - minX, height: base + lh - bottom))
    }

    /// The newest words that fit, wrapped like typed text: the first line
    /// from the caret, the rest from the field's left edge. `marker` is the
    /// live marker's width; it always ends the last line.
    static func lines(_ words: [GhostWord], elided: Bool, in g: GhostGeometry, marker: CGFloat,
                      measure: (String) -> CGFloat) -> [GhostLine] {
        let space = measure(" ")
        let ellipsisWidth = measure(ellipsis)
        let widths = words.map { measure($0.text) }
        let first = max(0, g.rightEdge - g.caret.minX)
        let full = g.rightEdge - g.leftEdge

        enum Item: Equatable { case ellipsis, word(Int), marker }
        func width(_ item: Item) -> CGFloat {
            switch item {
            case .ellipsis: ellipsisWidth
            case .word(let i): widths[i]
            case .marker: marker
            }
        }
        func wrap(from start: Int) -> [[Item]]? {
            var items: [Item] = elided || start > 0 ? [.ellipsis] : []
            items += (start ..< words.count).map(Item.word)
            items.append(.marker)
            var lines: [[Item]] = [[]]
            var used: CGFloat = 0
            for item in items {
                let w = width(item)
                let open = lines[lines.count - 1].isEmpty
                let gap: CGFloat = open ? 0 : (item == .marker ? markerGap : space)
                // A new line takes its first item whatever its width: a word
                // longer than a whole line gets one to itself.
                if used + gap + w <= (lines.count == 1 ? first : full) {
                    lines[lines.count - 1].append(item)
                    used += gap + w
                } else {
                    lines.append([item])
                    used = w
                    if lines.count > g.maxLines { return nil }
                }
            }
            return lines
        }

        // Layouts that keep at least the newest word, oldest words first to go.
        let starts = words.isEmpty ? 0 ... 0 : 0 ... words.count - 1
        guard let lines = starts.lazy.compactMap(wrap(from:)).first else {
            guard let last = words.indices.last else {
                // Not even the marker fits (a caret at the screen's edge with
                // no room below): it goes on the caret anyway.
                return [GhostLine(origin: CGPoint(x: g.caret.minX, y: g.baseY), words: [],
                                  elided: false, hasMarker: true, width: marker)]
            }
            // The newest word does not fit beside the marker on any line
            // there is - a long word in a short field. It takes a line anyway,
            // cut from the left: what was just said is never what disappears.
            let onCaretLine = first >= minLineWidth / 2 || g.maxLines == 1
            let room = onCaretLine ? first : full
            let leads = elided || last > 0
            let natural = (leads ? ellipsisWidth + space : 0) + widths[last] + markerGap + marker
            let width = max(min(room, natural), marker)
            return [GhostLine(origin: CGPoint(x: onCaretLine ? g.caret.minX : g.leftEdge,
                                              y: onCaretLine ? g.baseY : g.baseY - g.lineHeight),
                              words: [words[last]], elided: leads, hasMarker: true, width: width,
                              clip: natural > room ? max(0, width - markerGap - marker) : nil)]
        }
        return lines.enumerated().compactMap { index, items in
            guard !items.isEmpty else { return nil }
            var lineWidth: CGFloat = 0
            for (i, item) in items.enumerated() {
                lineWidth += (i == 0 ? 0 : (item == .marker ? markerGap : space)) + width(item)
            }
            return GhostLine(
                origin: CGPoint(x: index == 0 ? g.caret.minX : g.leftEdge,
                                y: g.baseY - CGFloat(index) * g.lineHeight),
                words: items.compactMap { if case .word(let i) = $0 { words[i] } else { nil } },
                elided: items.contains(.ellipsis),
                hasMarker: items.contains(.marker),
                width: lineWidth)
        }
    }

    /// The field's own font while its size agrees with the caret's line;
    /// otherwise - no answer, or a zoomed page - one sized from the line.
    static func font(for field: FieldFont?, caretHeight: CGFloat) -> NSFont {
        let fitted = min(max((caretHeight / 1.3).rounded(), 10), 28)
        guard let field, field.size >= 6, field.size <= 96 else { return .systemFont(ofSize: fitted) }
        let font = field.name.flatMap { NSFont(name: $0, size: field.size) } ?? .systemFont(ofSize: field.size)
        let natural = naturalLineHeight(font)
        if caretHeight >= natural * 0.8, caretHeight <= natural * 1.9 { return font }
        return NSFont(descriptor: font.fontDescriptor, size: fitted) ?? .systemFont(ofSize: fitted)
    }

    /// The caret's height is the field's line pitch, unless it is shorter than
    /// the type, or so tall that it is the whole field rather than a line.
    static func lineHeight(caret: CGFloat, font: NSFont) -> CGFloat {
        let natural = naturalLineHeight(font)
        return min(max(caret.rounded(), natural), natural * 2)
    }

    static func naturalLineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    static func measure(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}
