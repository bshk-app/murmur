# Murmur — macOS permissions + hotkey API (research, 2026-06-23)

**Symptoms:** (1) any hotkey does nothing; (2) every launch re-prompts for
Accessibility even though it was already granted.

## Executive summary (high confidence)

Both symptoms are **one disease: the dev build is ad-hoc signed.**
`codesign -dvvv Murmur.app` → `Signature=adhoc, TeamIdentifier=not set`.

TCC keys the Accessibility grant to the app's **code-signing identity** (cdhash
for ad-hoc). Every `tuist xcodebuild build` re-signs ad-hoc with a *fresh* cdhash
→ macOS treats each build as a new app → the grant is invalidated → re-prompt
every launch, and `AXIsProcessTrusted()` is effectively false → the CGEvent tap
never receives events → **hotkeys do nothing.** (There's also a known Ventura+
bug where `AXIsProcessTrusted()` returns a stale/wrong value; the robust check is
"did `CGEvent.tapCreate` return non-nil AND do events flow", not the API value.)

## Two independent fixes

### Fix 1 — move the hotkey off Accessibility entirely (Carbon)

Replace our `CGEventTap` hotkey with **Carbon `RegisterEventHotKey`**, via
[`sindresorhus/KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) (SPM, MIT).

- `RegisterEventHotKey` needs **NO Accessibility permission** — Apple considers
  it safe because it's narrowly scoped ("notify me when this exact combo is
  pressed", never sees other input). It also *swallows* the combo system-wide.
- KeyboardShortcuts gives **`onKeyDown` + `onKeyUp`** → push-to-talk for free,
  plus a SwiftUI `Recorder` view with UserDefaults persistence and
  system/menu conflict-checking. Replaces our hand-rolled `HotkeyMonitor` +
  `Hotkey` + `HotkeySettings` + recorder (DRY).
- Trade-offs: self-drawn apps (Zed/Electron-canvas/Warp) can consume the key
  before Carbon sees it (irrelevant for dictation into normal text fields); a
  macOS 15 Option-only-modifier bug existed but was reported fixed (our default
  ⌃⌥Space is unaffected). Sandbox-compatible (not that we're sandboxed).

→ This fixes "hotkeys do nothing" *immediately* and decouples the hotkey from
the whole TCC/signing mess.

### Fix 2 — stable code signing so Accessibility persists (needed for injection)

Text injection (`CGEvent.post` of synthetic keystrokes into other apps) **does
require Accessibility** on all macOS incl. Sequoia 15 (synthetic events are
ignored since Mojave 10.14 unless the app is trusted). So Accessibility can't be
avoided for step D — but the grant must *persist*. Fix the signature:

In `Project.swift` target settings, sign with a **stable identity** instead of
ad-hoc. Available on this machine:

- `Developer ID Application: Aleksandr Beshkenadze (Q8H6GWJ658)` ← most stable, also the notarization identity
- `Apple Development: beshkenadze@gmail.com (6SUFT7RP97)`
- `Apple Development: a@beshkenadze.com (95MF4JG5BH)`

```swift
settings: .settings(base: [
    "SWIFT_VERSION": "5.0",
    "CODE_SIGN_STYLE": "Manual",
    "CODE_SIGN_IDENTITY": "Developer ID Application",
    "DEVELOPMENT_TEAM": "Q8H6GWJ658",
])
```

Then once: `tccutil reset Accessibility dev.beshkenadze.Murmur`, relaunch, grant
once → it now sticks across rebuilds (same designated requirement: bundle id +
team). Keep the **run path stable** (install to `/Applications` or always run the
same DerivedData product) and **bundle id constant** (already `dev.beshkenadze.Murmur`).

## What this means for Murmur's permission model

| Capability | API | Permission |
|---|---|---|
| Global push-to-talk hotkey | Carbon `RegisterEventHotKey` (KeyboardShortcuts) | **none** ✅ |
| Mic capture | AVAudioEngine | Microphone (TCC) |
| Type into focused field (D) | `CGEvent.post` Unicode | **Accessibility** (TCC) — needs stable signing |

So after Fix 1, the **only** TCC grants are Mic + Accessibility, and Accessibility
is needed *only* for injection — with stable signing it persists.

## Confidence & sources

**High** on the root cause (ad-hoc signature confirmed on disk + matches every
documented case) and on RegisterEventHotKey needing no Accessibility. **High** on
injection requiring Accessibility (Mojave-era synthetic-event gate, unchanged
through Sequoia).

- [Accessibility Permission in macOS — jano.dev](https://jano.dev/apple/macos/swift/2025/01/08/Accessibility-Permission.html)
- [Apple Dev Forums — TCC Accessibility not persisting](https://developer.apple.com/forums/thread/703188)
- [Apple Dev Forums — AXIsProcessTrusted returns wrong value](https://developer.apple.com/forums/thread/727984)
- [electrobun #334 — switch NSEvent → RegisterEventHotKey to avoid Accessibility](https://github.com/blackboardsh/electrobun/issues/334)
- [Zed/Carbon global shortcut dispatch deep-dive](https://dev.to/quicopy/the-macos-global-shortcut-that-wont-fire-in-zed-when-a-23-year-old-carbon-api-meets-a-self-drawn-24o9)
- [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)
- [Igor Kulman — Implementing Auto-Type on macOS (CGEvent.post needs Accessibility)](https://blog.kulman.sk/implementing-auto-type-on-macos/)
- [Jamf — Synthetic events & TCC (Mojave gate)](https://www.jamf.com/blog/synthetic-reality/)
