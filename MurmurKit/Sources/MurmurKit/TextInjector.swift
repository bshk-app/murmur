import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

/// Puts the final transcript into the focused field of the frontmost app.
///
/// Primary path is **paste** (the production standard — Handy, Superwhisper,
/// TypeVox all paste): stash the pasteboard, write the text, synthesize ⌘V, then
/// restore the previous contents. Paste is atomic and reliable across resistant
/// targets (Terminal, Electron, VS Code) where per-key synthetic events drop.
/// Per-character Unicode typing is kept as an opt-in fallback (`type`).
///
/// Both paths post synthetic events, so both need Accessibility trust and both
/// are blocked by **secure input** (password fields / secure-keyboard terminals).
/// We detect that and refuse gracefully rather than silently dropping text.
public enum TextInjector {
    public enum Result: Sendable {
        case pasted              // ⌘V sent into the field; clipboard restored
        case copiedSecureInput   // secure input on → left on the clipboard for manual ⌘V
        case failed              // couldn't synthesize the events
    }

    /// What actually goes on the pasteboard. The trailing space exists to butt the
    /// next utterance against this one; submitting ends the message, so it would
    /// only ever travel as trailing whitespace.
    public static func payload(_ text: String, submit: Bool) -> String {
        submit ? text : text + " "
    }

    /// True when some process has secure event input enabled — synthetic key
    /// events (including ⌘V) are dropped while it is. Anti-keylogger by design;
    /// there is no supported bypass, so callers should surface it, not retry.
    public static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    /// How long after ⌘V we assume the target has acted on it: the Return
    /// that sends a message waits this long.
    ///
    /// A heuristic, not a measurement: there is no observable "paste applied"
    /// signal, and reading the focused element over Accessibility is unreliable
    /// on the web fields this matters most for.
    public static let pasteSettleDelay = 0.12

    /// The user's clipboard stays out of the way at least this long after ⌘V.
    /// An app reads the text when it gets to the event - usually within tens
    /// of milliseconds, but a freshly launched TextEdit on a busy Mac took
    /// 0.17 s, after a fixed 0.12 s had already put the old clipboard back,
    /// and the old clipboard is what it pasted.
    public static let minimumClipboardHold = 0.5
    /// Past this the paste is taken not to have landed, and the clipboard goes
    /// back regardless.
    public static let maximumClipboardHold = 2.0

    /// When to put the user's clipboard back, in seconds after ⌘V, given when
    /// an app first took the text: `pasteSettleDelay` after that, but never
    /// before `minimumClipboardHold` - a clipboard manager or Screen Sharing
    /// may be the first to take it - and never after `maximumClipboardHold`.
    static func clipboardRestoreTime(firstTaken: Double?) -> Double {
        guard let firstTaken else { return maximumClipboardHold }
        return min(max(minimumClipboardHold, firstTaken + pasteSettleDelay), maximumClipboardHold)
    }

    /// Insert `text` by pasting, optionally pressing Return afterwards. Requires
    /// Accessibility trust to post ⌘V. On secure input the text is left on the
    /// clipboard (not pasted, not submitted) so it isn't lost. Call on the main
    /// thread (pasteboard + a short async tail).
    ///
    /// `settled` is called once, on the main thread, for a `.pasted` result:
    /// `true` once the text has been read and `pasteSettleDelay` has passed
    /// since - when Return may go - or `false` if nothing read it, or a later
    /// paste landed first. A read is not proof the target pasted: a clipboard
    /// manager or Screen Sharing may be the reader (on a test Mac something
    /// read every new item within ~0.1 s, transient or not), and Murmur cannot
    /// tell who asked. What keeps Return behind the paste is that it is posted
    /// after ⌘V; the read only ever makes it later, never earlier than
    /// `pasteSettleDelay` after ⌘V, and holds it back when nothing read at all.
    @discardableResult
    public static func paste(_ text: String, submit: Bool = false,
                             settled: (@Sendable (Bool) -> Void)? = nil) -> Result {
        guard !text.isEmpty else { return .failed }
        // Secure input → ⌘V won't reach the field. Leave the text on the clipboard.
        if secureInputActive {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(payload(text, submit: submit), forType: .string)
            return .copiedSecureInput
        }
        return paste(payload(text, submit: submit), submit: submit, on: .general,
                     pressPaste: postPasteShortcut, pressReturn: { postReturn() }, settled: settled)
    }

    /// The restore still to come, if any: the user's clipboard from before
    /// Murmur's paste, and the change count of Murmur's text. A paste that
    /// starts before it carries it on. Main thread only.
    nonisolated(unsafe) private static var pendingRestore: (saved: [NSPasteboardItem]?, mine: Int)?

    /// `paste` on a given pasteboard with given keys, so tests reach it
    /// without the user's clipboard or real keystrokes.
    @discardableResult
    static func paste(_ body: String, submit: Bool, on pb: NSPasteboard,
                      pressPaste: () -> Bool, pressReturn: @escaping @Sendable () -> Void,
                      settled: (@Sendable (Bool) -> Void)? = nil) -> Result {
        // Before the last paste's restore the clipboard holds Murmur's text;
        // the one to bring back is still the user's from before it.
        let saved: [NSPasteboardItem]?
        if let pending = pendingRestore, pb.changeCount == pending.mine {
            saved = pending.saved
        } else {
            saved = snapshot(pb)
        }
        let source = PasteSource(body)
        source.write(to: pb)
        let mine = pb.changeCount
        pendingRestore = (saved, mine)
        guard pressPaste() else {
            // Left for ⌘V by hand, whole: nothing waits to hand it over.
            pb.clearContents()
            pb.setString(body, forType: .string)
            pendingRestore = nil
            return .failed
        }
        let press = submit ? pressReturn : nil
        finish(source, saved: saved, on: pb, mine: mine, postedAt: .now(), landed: { landed in
            if landed { press?() }
            settled?(landed)
        })
        return .pasted
    }

    /// After ⌘V: `landed(true)` once the text has been read and the settle
    /// delay has passed, `landed(false)` if nothing reads it or a later paste
    /// lands first - Return then would send a field without this text, the
    /// worst thing this could do. (See `paste` for what a read does and does
    /// not prove.) Then the user's clipboard back once `clipboardRestoreTime`
    /// has come, unless the user copied something in the meantime. The
    /// restore never comes before `landed`.
    private static func finish(_ source: PasteSource, saved: [NSPasteboardItem]?, on pb: NSPasteboard, mine: Int,
                               postedAt posted: DispatchTime, landed: (@Sendable (Bool) -> Void)?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let elapsed = seconds(from: posted, to: .now())
            // A clipboard manager may take the text before ⌘V is even sent.
            let taken = source.takenAt.map { max(0, seconds(from: posted, to: $0)) }
            let latest = pendingRestore?.mine == mine
            let restoring = elapsed >= clipboardRestoreTime(firstTaken: taken)
            var landed = landed
            // Read too close to the cap for the settle delay: reported below as
            // not landed, rather than a Return that comes too soon.
            if let report = landed, let taken, elapsed >= taken + pasteSettleDelay {
                report(latest)
                landed = nil
            }
            guard restoring else {
                return finish(source, saved: saved, on: pb, mine: mine, postedAt: posted, landed: landed)
            }
            landed?(false)
            // A later paste took the restore over.
            guard latest else { return }
            pendingRestore = nil
            guard pb.changeCount == mine else { return }
            pb.clearContents()
            if let saved, !saved.isEmpty { pb.writeObjects(saved) }
        }
    }

    private static func seconds(from start: DispatchTime, to end: DispatchTime) -> Double {
        Double(Int64(bitPattern: end.uptimeNanoseconds &- start.uptimeNanoseconds)) / 1_000_000_000
    }

    /// Press Return now, for a send asked for after `paste` had already been
    /// called without one. Call only once `pasteSettleDelay` has passed since a
    /// `paste` that returned `.pasted` - the same rule that keeps `paste` from
    /// sending a message the text never reached.
    public static func pressReturn() { postReturn() }

    /// Deep-copy the current pasteboard items so we can put them back after paste.
    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem]? {
        pb.pasteboardItems?.compactMap { item in
            let copy = NSPasteboardItem()
            var any = false
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type); any = true }
            }
            return any ? copy : nil
        }
    }

    /// Synthesize ⌘V via a private event source (so it doesn't inherit any
    /// physical modifiers still held from the hotkey).
    private static func postPasteShortcut() -> Bool {
        let v = CGKeyCode(kVK_ANSI_V)
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Press Return, to send the message we just pasted. Flags are cleared
    /// explicitly: a Cmd- or Shift-based dictation hotkey may still be physically
    /// held, and ⌘Return or ⇧Return means something else entirely in chat apps.
    private static func postReturn() {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: false)
        else { return }
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Per-character Unicode typing — the fragile fallback, kept for an opt-in
    /// "Type" insert mode. Carries the Unicode payload directly (no keycode
    /// mapping), but some apps drop fast synthetic key events. Blocked by secure
    /// input like paste.
    public static func type(_ text: String) {
        guard !text.isEmpty, !secureInputActive else { return }
        let source = CGEventSource(stateID: .privateState)
        for character in text {
            post(character, source: source)
        }
    }

    private static func post(_ character: Character, source: CGEventSource?) {
        let utf16 = Array(String(character).utf16)
        guard !utf16.isEmpty,
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }

        down.flags = []                                  // clear ambient modifiers
        up.flags = []
        utf16.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

/// The text on the clipboard during a paste, handed over when an app asks
/// for it - which is how Murmur learns it was read: by the app it was meant
/// for, or first by a clipboard manager or Screen Sharing. Once handed over
/// the pasteboard keeps the data, so later readers are not seen.
final class PasteSource: NSObject, NSPasteboardItemDataProvider, Sendable {
    /// "Put here for a moment and about to be restored" (nspasteboard.org):
    /// clipboard managers that follow it neither record the dictation nor
    /// take it before the app it was meant for.
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    let body: String
    /// When an app first asked for the text. Behind a lock: the pasteboard
    /// may ask on another thread than the main one, which reads it.
    private let firstAsked = OSAllocatedUnfairLock<DispatchTime?>(initialState: nil)
    var takenAt: DispatchTime? { firstAsked.withLock { $0 } }

    init(_ body: String) { self.body = body }

    func write(to pb: NSPasteboard) {
        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: [.string])
        item.setData(Data(), forType: Self.transient)
        pb.clearContents()
        pb.writeObjects([item])
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        firstAsked.withLock { if $0 == nil { $0 = .now() } }
        item.setString(body, forType: type)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}
