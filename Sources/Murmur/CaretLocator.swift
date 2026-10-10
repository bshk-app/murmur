import AppKit
import ApplicationServices

/// What a focused text element says about its selection. `AXCaretSource`
/// asks Accessibility; tests answer from a script.
protocol CaretTextSource {
    /// `AXSelectedTextRange`.
    var selectedRange: CFRange? { get }
    /// `AXBoundsForRange`, in Accessibility's top-left screen coordinates.
    func bounds(of range: CFRange) -> CGRect?
    /// `AXStringForRange`.
    func string(in range: CFRange) -> String?
    /// The text-marker selection WebKit and Chromium keep instead.
    var markerSelection: MarkerSelection? { get }
}

struct MarkerSelection {
    var bounds: CGRect
    /// Nothing is selected: the marker range is just the caret.
    var isCollapsed: Bool
}

/// Turns what a text element answers into one caret position.
enum CaretResolver {
    /// Up to this wide, a rect is a caret.
    static let caretWidth: CGFloat = 3

    /// The caret as a zero-width rect in the source's coordinates, or nil
    /// when the element does not say. `isPlausible` weeds out the empty
    /// rects some apps answer with when they have no idea.
    static func caret(in source: CaretTextSource, isPlausible: (CGRect) -> Bool) -> CGRect? {
        if let selection = source.selectedRange {
            let end = selection.location + selection.length
            // Native fields answer an empty range with the caret itself.
            if let r = source.bounds(of: CFRange(location: end, length: 0)), isPlausible(r) {
                return onItsLine(line(at: r.minX, r), at: end, in: source, isPlausible: isPlausible)
            }
            // Others only measure characters: the caret is the right edge of
            // the one before it - unless that is a line break, whose box is on
            // the line above while the caret starts the next one.
            let previous = CFRange(location: end - 1, length: 1)
            if end > 0, source.string(in: previous)?.contains(where: \.isNewline) != true,
               let r = source.bounds(of: previous), r.width > 0, isPlausible(r) {
                return line(at: r.maxX, r)
            }
            if let r = source.bounds(of: CFRange(location: end, length: 1)), isPlausible(r) {
                return line(at: r.minX, r)
            }
        }
        if let marker = source.markerSelection, isPlausible(marker.bounds) {
            let r = marker.bounds
            // Chromium measures a caret with no text beside it - an empty
            // field, an empty line - as that whole line's box, whose right
            // edge is nowhere near it. The caret starts the line. Whether the
            // field is empty cannot be asked instead: Chromium reports a
            // placeholder as the field's value.
            if marker.isCollapsed, r.width > caretWidth { return line(at: r.minX, r) }
            return line(at: r.maxX, r)
        }
        return nil
    }

    /// The empty range's answer, moved onto the caret's line if it is not
    /// on it. TextEdit on macOS 27 answers it one line too high wherever the
    /// caret is - on an empty line, mid-line, at the end - while the boxes of
    /// characters are right. The character after the caret is on its line,
    /// a line break included, unless the caret ends the character before it
    /// on that one's line: the end of a wrapped line. At the very end of the
    /// text the character before it is, unless that is a line break, which
    /// the caret starts the line after. Only the line moves: the answer's x
    /// is right, on whichever side right-to-left text puts it.
    private static func onItsLine(_ caret: CGRect, at end: Int, in source: CaretTextSource,
                                  isPlausible: (CGRect) -> Bool) -> CGRect {
        func box(_ location: Int) -> CGRect? {
            guard location >= 0, let r = source.bounds(of: CFRange(location: location, length: 1)),
                  r.height > 0, isPlausible(r) else { return nil }
            return r
        }
        func isBreak(_ location: Int) -> Bool {
            source.string(in: CFRange(location: location, length: 1))?.contains(where: \.isNewline) == true
        }
        // Overlapping by half the shorter of the two: some apps measure a
        // character by its glyph, shorter than the caret beside it.
        func sharesLine(_ r: CGRect) -> Bool {
            min(caret.maxY, r.maxY) - max(caret.minY, r.minY) >= min(caret.height, r.height) / 2
        }
        func ends(_ r: CGRect) -> Bool { min(abs(caret.minX - r.maxX), abs(caret.minX - r.minX)) <= 2 }
        func moved(to r: CGRect) -> CGRect { CGRect(x: caret.minX, y: r.minY, width: 0, height: caret.height) }

        if let after = box(end) {
            if sharesLine(after) { return caret }
            if let before = box(end - 1), !isBreak(end - 1), sharesLine(before), ends(before) { return caret }
            return moved(to: after)
        }
        guard let before = box(end - 1) else { return caret }
        if isBreak(end - 1) {
            // Nothing is measured on the line after the last break; an answer
            // that starts where the break's own line does is that line.
            return caret.minY <= before.minY + 1 ? caret.offsetBy(dx: 0, dy: caret.height) : caret
        }
        return sharesLine(before) ? caret : moved(to: before)
    }

    private static func line(at x: CGFloat, _ r: CGRect) -> CGRect {
        CGRect(x: x, y: r.minY, width: 0, height: r.height)
    }
}

/// A caret, and what its field says about itself.
struct CaretSpot: Equatable {
    /// Zero-width, in AppKit screen coordinates (origin bottom-left).
    var caret: CGRect
    /// The text element's frame, when it says and the frame holds the caret.
    var field: CGRect?
    /// Only asked for when a take starts: its type does not change mid-take.
    var font: FieldFont?
    /// A text field rather than a text area: its text never wraps, however
    /// long. A chat composer is a text area, even while it is one line tall -
    /// it grows as you type.
    var singleLine: Bool

    init(_ caret: CGRect, field: CGRect? = nil, font: FieldFont? = nil, singleLine: Bool = false) {
        self.caret = caret
        self.field = field
        self.font = font
        self.singleLine = singleLine
    }
}

/// Where the caret is in the text field being dictated into, so the live
/// text can be drawn there rather than at the bottom of the screen.
///
/// Only ever asks. Switching an app's accessibility support on
/// (`AXManualAccessibility`, `AXEnhancedUserInterface`) would get answers out
/// of more Electron apps, but VS Code takes either for a screen reader and
/// turns on Screen Reader Optimized mode (vscode#279644). An app that does
/// not answer gets the compact pill.
enum CaretLocator {
    enum Lookup: Equatable {
        case found(CaretSpot)
        case notFound
        /// The app stopped answering. Asking again would freeze Murmur for
        /// the timeout each time, so the caller should stop asking.
        case stalled
    }

    /// Roles that take typing. A focused button, or a web page that keeps a
    /// selection, has a caret-like answer too, but the text would not land
    /// there.
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    /// A responsive app answers a whole lookup in a few milliseconds.
    static let lookupBudget: Duration = .milliseconds(300)

    @MainActor
    static func locate(readingFont: Bool = false) -> Lookup {
        let system = AXUIElementCreateSystemWide()
        // Asked on the main thread: an app that hangs must cost a moment, not
        // the default six seconds. On the system-wide element this sets the
        // timeout for the whole process, and Murmur asks Accessibility
        // nothing else.
        AXUIElementSetMessagingTimeout(system, 0.2)
        // And the whole lookup gets a budget: an app answering each question
        // just inside the timeout, across a dozen ancestors, would otherwise
        // freeze Murmur for seconds. Past it the lookup counts as stalled,
        // and tracking stops asking.
        let deadline = ContinuousClock.now + lookupBudget
        let source = AXCaretSource(element: system, deadline: deadline)
        // The system-wide focus also covers panels that take typing without
        // their app coming to the front (Spotlight, Raycast).
        guard let focused = source.elementValue("AXFocusedUIElement") else {
            return source.stalled ? .stalled : .notFound
        }
        let field = AXCaretSource(element: focused, deadline: deadline)
        guard let role = field.copy("AXRole") as? String, textRoles.contains(role) else {
            return field.stalled ? .stalled : .notFound
        }
        let screens = NSScreen.screens.map(\.frame)
        let primaryTop = screens.first?.maxY ?? 0
        func appKit(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX, y: primaryTop - r.maxY, width: r.width, height: r.height)
        }
        func isPlausible(_ r: CGRect) -> Bool {
            guard r.minX.isFinite, r.minY.isFinite,
                  r.height > 1, r.height < 300, r.width >= 0, r.width < 4000 else { return false }
            let probe = appKit(r).insetBy(dx: -1, dy: -1)
            return screens.contains { $0.intersects(probe) }
        }
        guard let caret = CaretResolver.caret(in: field, isPlausible: isPlausible), !field.stalled else {
            // Stalled while checking the caret's line counts too: the caret
            // may be a line off, and every lookup would wait on it again.
            return field.stalled ? .stalled : .notFound
        }
        // The caret is the answer; the rest only shapes the text drawn there,
        // so an app that stalls on it still gets the caret.
        let frame = Self.frame(field.frame, holding: caret).map(appKit)
        return .found(CaretSpot(appKit(caret), field: frame, font: readingFont ? field.font : nil,
                                singleLine: role != "AXTextArea"))
    }

    /// A field's frame, if it is one around `caret` (both in Accessibility's
    /// coordinates). Some apps answer with the frame of something else - the
    /// window, a zero rect - and lines wrapped to it would land nowhere near
    /// the text.
    static func frame(_ frame: CGRect?, holding caret: CGRect) -> CGRect? {
        guard let frame, frame.width > 0, frame.height > 0, frame.width < 8000,
              frame.insetBy(dx: -4, dy: -4).contains(CGPoint(x: caret.minX, y: caret.midY)) else { return nil }
        return frame
    }
}

/// `CaretTextSource` over a live element. Gives up after the first call the
/// app does not answer in time, or once the lookup's budget is spent, so a
/// slow app costs a moment, not one timeout per question.
private final class AXCaretSource: CaretTextSource {
    let element: AXUIElement
    private let deadline: ContinuousClock.Instant
    private(set) var stalled = false

    init(element: AXUIElement, deadline: ContinuousClock.Instant) {
        self.element = element
        self.deadline = deadline
    }

    /// Whether another question may be asked.
    private func mayAsk() -> Bool {
        if !stalled, ContinuousClock.now >= deadline { stalled = true }
        return !stalled
    }

    func copy(_ attribute: String, of target: AXUIElement? = nil) -> CFTypeRef? {
        guard mayAsk() else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(target ?? element, attribute as CFString, &value)
        if error == .cannotComplete { stalled = true }
        return error == .success ? value : nil
    }

    private func copy(_ attribute: String, of target: AXUIElement? = nil, _ argument: CFTypeRef) -> CFTypeRef? {
        guard mayAsk() else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            target ?? element, attribute as CFString, argument, &value)
        if error == .cannotComplete { stalled = true }
        return error == .success ? value : nil
    }

    func elementValue(_ attribute: String, of target: AXUIElement? = nil) -> AXUIElement? {
        guard let value = copy(attribute, of: target), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    var selectedRange: CFRange? {
        Self.unwrap(copy("AXSelectedTextRange"), .cfRange, CFRange())
    }

    func bounds(of range: CFRange) -> CGRect? {
        guard let argument = Self.wrap(range) else { return nil }
        return Self.unwrap(copy("AXBoundsForRange", argument), .cgRect, CGRect.zero)
    }

    func string(in range: CFRange) -> String? {
        guard let argument = Self.wrap(range) else { return nil }
        return copy("AXStringForRange", argument) as? String
    }

    var markerSelection: MarkerSelection? {
        // Kept on the field in some apps, on the enclosing web area in others.
        var node: AXUIElement? = element
        for _ in 0 ..< 12 {
            guard let current = node else { return nil }
            if let marker = copy("AXSelectedTextMarkerRange", of: current) {
                guard let bounds = Self.unwrap(copy("AXBoundsForTextMarkerRange", of: current, marker),
                                               .cgRect, CGRect.zero) else { return nil }
                let text = copy("AXStringForTextMarkerRange", of: current, marker) as? String
                return MarkerSelection(bounds: bounds, isCollapsed: text?.isEmpty ?? false)
            }
            node = elementValue("AXParent", of: current)
        }
        return nil
    }

    /// `AXPosition` and `AXSize`.
    var frame: CGRect? {
        guard let origin = Self.unwrap(copy("AXPosition"), .cgPoint, CGPoint.zero),
              let size = Self.unwrap(copy("AXSize"), .cgSize, CGSize.zero) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// The type of the character before the caret - or of the first one, at
    /// the very start - from `AXAttributedStringForRange`. Most apps answer
    /// with an `AXFont` dictionary, AppKit ones with an `NSFont`.
    var font: FieldFont? {
        guard let selection = selectedRange,
              let argument = Self.wrap(CFRange(location: max(0, selection.location + selection.length - 1),
                                               length: 1)),
              let string = copy("AXAttributedStringForRange", argument) as? NSAttributedString,
              string.length > 0 else { return nil }
        if let font = string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            return FieldFont(name: font.fontName, size: font.pointSize)
        }
        guard let info = string.attribute(NSAttributedString.Key("AXFont"), at: 0, effectiveRange: nil)
                as? [String: Any],
              let size = info["AXFontSize"] as? NSNumber else { return nil }
        return FieldFont(name: info["AXFontName"] as? String, size: CGFloat(truncating: size))
    }

    private static func wrap(_ range: CFRange) -> AXValue? {
        var range = range
        return AXValueCreate(.cfRange, &range)
    }

    private static func unwrap<T>(_ value: CFTypeRef?, _ type: AXValueType, _ initial: T) -> T? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == type else { return nil }
        var out = initial
        return withUnsafeMutablePointer(to: &out) { AXValueGetValue(axValue, type, $0) } ? out : nil
    }
}
