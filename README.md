# Murmur

Local push-to-talk dictation for macOS. Hold a global hotkey, speak, and your
words are typed into the focused field of whatever app you're in — like
[Handy](https://github.com/cjpais/handy), but **fully on-device** via MLX
(no cloud, no API keys).

> Working name. Trivially renamed (directory + bundle id) while the repo is young.

## Status

Scaffold only — a menu-bar agent shell that compiles and runs. The dictation
pipeline is not wired yet.

```
swift build          # compiles the menu-bar shell
swift run Murmur      # launches the agent (menu-bar icon, no Dock icon)
```

## Vision

- **Push-to-talk**: hold a global hotkey (default ⌥Space), speak, release.
- **On-device STT**: streaming transcription from the
  [`mlx-audio-swift`](../mlx-audio-swift) stack (Voxtral Realtime / Nemotron /
  Parakeet). EN + RU.
- **System-wide insertion**: the final text is typed into the focused field of
  any app via the Accessibility API.
- **Live HUD** (planned): a small floating overlay shows partials while you hold
  the key; the field only ever receives clean, finalized text.

## Roadmap (progressive, atomic steps)

1. ✅ Menu-bar agent scaffold
2. ☐ Global push-to-talk hotkey (Input Monitoring)
3. ☐ Mic capture while held (AVAudioEngine, 16 kHz mono)
4. ☐ Wire on-device STT (`.package(path: "../mlx-audio-swift")`)
5. ☐ Live HUD overlay for partials
6. ☐ Text injection into the focused field (Accessibility)
7. ☐ Settings: hotkey, language, model, insertion mode
8. ☐ App bundle + permission strings + signing

## Permissions (when bundled)

- **Microphone** — `NSMicrophoneUsageDescription`
- **Input Monitoring** — global hotkey capture
- **Accessibility** — typing into other apps' fields
- `LSUIElement = true` — menu-bar agent, no Dock icon

## License

TBD.
