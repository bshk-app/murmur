# macOS text injection for a dictation app — research (2026-06-25)

**Question:** how should Murmur's `TextInjector` put transcribed text into the focused
field of any app? Per-char `CGEvent.post(keyboardSetUnicodeString)` (current) vs
clipboard-paste? Secure-input handling? What do shipping tools do?

## Executive summary

Murmur currently uses the **fragile minority approach** (per-character
`CGEvent.post` Unicode typing). Production dictation tools — **including Handy, the
app Murmur is cloning** — predominantly **paste** (write to the pasteboard, synth
⌘V, restore). Recommendation: make **paste the primary insert for the final text**,
keep type as an option, **detect secure input and refuse gracefully**, and treat
live-into-field typing as the fragile/optional path (the robust product = live view
in the HUD, paste the final on release).

Confidence: high on the paste-vs-type verdict and secure-input behaviour (Apple TN +
multiple tools agree); medium on exact per-app quirks.

## Findings

### 1. Per-char CGEvent typing is fragile
- **Dropped characters** on speed: need inter-keystroke delays so the target's event
  loop keeps up (auto-type guides use up to ~100 ms/char → slow). [kulman]
- `keyboardSetUnicodeString` sidesteps keycode/layout mapping (good for Unicode/RU),
  **but some apps interpret keycode events more reliably than Unicode-string events**;
  per-app testing is required. [Apple docs, kulman]
- Target must be **fully focused/activated** before posting or input is lost.
- Tap choice (`.cghidEventTap` / `.cgSessionEventTap` / `.cgAnnotatedSessionEventTap`)
  changes delivery.

### 2. Secure input BLOCKS synthetic keystrokes (must detect)
- Apple **TN2150**: `EnableSecureEventInput` specifically blocks **CGEvent taps**
  between the HID driver and the Window Server — i.e. exactly Murmur's mechanism.
  Active in **password fields** and terminals with secure keyboard entry
  (iTerm2, Kitty, Ghostty, Chromium, WebKit). [Apple TN2150]
- **Detect** with `IsSecureEventInputEnabled()` (tells you *some* process enabled it
  system-wide, not which). No supported bypass — it's anti-keylogger by design.
- → Murmur should detect this and **show "field is protected" in the HUD**, never
  silently drop.

### 3. Paste is the production standard
- **Handy** (the app Murmur clones) uses **clipboard-based paste** (confirmed via its
  own Linux notes: a focus-stealing overlay breaks "pasting back into the app"). [Handy]
- **TypeVox**: cascade — **clipboard-insert first → Accessibility API → keystroke sim**.
  "Works in Terminal, VS Code, Electron…". [TypeVox]
- **Dictly**: user-selectable **type-out / paste / copy** modes. [Dictly]
- **Superwhisper**: paste-based (e.g. its Claude-Code terminal pipe pastes). [spokenly]
- Trade-off: paste is **more reliable** across resistant fields (Terminal/Electron/VS
  Code) and instant; cost = it **clobbers the clipboard**, so save/restore via
  `NSPasteboard.changeCount` is required. [Eclectic Light]

### 4. Live-append vs paste tension (Murmur-specific)
- Paste is **atomic** — you can't "live-paste" word-by-word without re-clobbering the
  clipboard each time. Murmur's D2 live-append-into-field therefore *requires* the
  fragile per-char type.
- Handy's model: **no live typing** — live view is shown in the overlay/HUD, the field
  receives one paste at the end. This is the robust path and aligns with Murmur's HUD
  redesign + the "HUD only" insert mode.

## Recommendation for Murmur's TextInjector
1. **Primary = paste** for the final text: write to `NSPasteboard`, synth ⌘V, restore
   the previous contents (guard with `changeCount`). Matches Handy/Superwhisper/TypeVox.
2. **Keep type (per-char) as an option** in settings ("Type" vs "Paste"), with
   inter-keystroke pacing if used.
3. **Secure-input guard**: check `IsSecureEventInputEnabled()` before inserting; if on,
   skip and surface "поле защищено" in the HUD.
4. **Optional cascade fallback** (later): paste → Accessibility (`AXUIElement`) → type.
5. **Decide on live-append**: keep it (fragile, the fancy differentiator) **or** go
   Handy-style — live two-tier view in the HUD, paste the final on release (robust).

## Sources
- [Apple — keyboardSetUnicodeString](https://developer.apple.com/documentation/coregraphics/cgevent/1456028-keyboardsetunicodestring)
- [Igor Kulman — Implementing Auto-Type on macOS](https://blog.kulman.sk/implementing-auto-type-on-macos/)
- [Apple TN2150 — Using Secure Event Input Fairly](https://developer.apple.com/library/archive/technotes/tn2150/_index.html)
- [Fig docs — Secure Keyboard Input](https://fig.io/docs/support/secure-keyboard-input)
- [TypeVox — Dictation on Mac guide](https://typevox.app/blog/dictation-on-mac/)
- [Dictly — on-device dictation](https://apps.apple.com/ms/app/dictly-on-device-dictation/id6752733596)
- [Eclectic Light — inside the Pasteboard](https://eclecticlight.co/2020/05/12/cut-copy-paste-inside-the-pasteboard-clipboard/)
- [Handy (cjpais) — GitHub](https://github.com/cjpais/handy)
- [spokenly — Wispr Flow vs Superwhisper vs MacWhisper](https://spokenly.app/blog/wispr-flow-vs-superwhisper-vs-macwhisper)
