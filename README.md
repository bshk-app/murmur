# Murmur

Local push-to-talk dictation for macOS. Hold a global hotkey, speak, and your
words are typed into the focused field of whatever app you're in — like
[Handy](https://github.com/cjpais/handy), but **fully on-device** via MLX
(no cloud, no API keys).

> Working name. Trivially renamed (directory + bundle id) while the repo is young.

## Status

Menu-bar agent with global push-to-talk + 16 kHz mic capture, and the on-device
two-tier STT stack (Nemotron + Voxtral) linked in. Transcription wiring is next.

```
make gen     # tuist generate
make build   # build (arm64; Explicit Modules off — Xcode 26 workaround)
make run     # build + launch the menu-bar agent
```

STT comes from the fork's `dev/nemo-mic` branch (Nemotron stream + Voxtral
Realtime + `TwoTierSession`), consumed via Xcode-native SPM from its git worktree
at `/Volumes/DATA/mlx-audio-swift-worktrees/nemotron-session` (see `Project.swift`).

## Vision

- **Push-to-talk**: hold a global hotkey (default ⌃⌥Space), speak, release.
- **On-device STT**: streaming transcription from the
  [`mlx-audio-swift`](../mlx-audio-swift) stack (Voxtral Realtime / Nemotron /
  Parakeet). EN + RU.
- **System-wide insertion**: the final text is typed into the focused field of
  any app via the Accessibility API.
- **Live HUD** (planned): a small floating overlay shows partials while you hold
  the key; the field only ever receives clean, finalized text.

## Roadmap (progressive, atomic steps)

1. ✅ Menu-bar agent scaffold (Tuist `.app`)
2. ✅ Global push-to-talk hotkey (⌃⌥Space, CGEvent tap — swallows the chord; Accessibility)
3. ✅ Mic capture while held (AVAudioEngine → 16 kHz mono) — ported from `Mic.swift`
4. ✅ Wire on-device STT — `mlx-audio-swift` @ `dev/nemo-mic` (`TwoTierEngine` → Nemotron partials + Voxtral finals; live transcript to console, final to menu)
5. ☐ Live HUD overlay for partials (`<…>`)
6. ☐ Text injection into the focused field (Accessibility, append-only)
7. ◐ Settings — ✅ rebindable hotkey (recorder + persistence); ☐ language, model, insertion mode
8. ☐ Code signing + notarization (Developer ID)

## Permissions (when bundled)

- **Microphone** — `NSMicrophoneUsageDescription`
- **Input Monitoring** — global hotkey capture
- **Accessibility** — typing into other apps' fields
- `LSUIElement = true` — menu-bar agent, no Dock icon

## License

TBD.
