# Murmur

On-device push-to-talk dictation for macOS. Hold a global hotkey, speak, and the
transcription is typed into the focused field of whatever app you're in — like
[Handy](https://github.com/cjpais/handy), but **fully on-device** via
[MLX](https://github.com/ml-explore/mlx). No cloud, no account, no API keys.

- **Push-to-talk** — hold a global hotkey (default ⌃⌥Space) to dictate, release to finish.
- **Two-tier STT** — a fast low-latency model for live partials, a more accurate
  model for the final text. English + Russian.
- **On-device** — speech recognition runs entirely locally; no audio or
  transcripts ever leave your Mac.
- **Menu-bar agent** — a first-run wizard handles permissions, model download,
  and a quick try-it; then it lives quietly in the menu bar.

## Requirements

- macOS 15 (Sequoia) or later
- Apple Silicon (M1 or newer)

## Install

```bash
brew tap bshk-app/homebrew-tap
brew install --cask murmur
```

The app updates itself in-app via [Sparkle](https://sparkle-project.org).

## Build from source

Murmur is a [Tuist](https://tuist.io) project; the dictation core lives in the
local `MurmurKit/` Swift package and the app (`Sources/Murmur`) is a thin UI over
it.

```bash
make build     # generate the Xcode project + build Release
make run       # build and launch the menu-bar agent
make run-cli   # run the terminal version (same MurmurKit core)
```

Builds are Release — MLX-Swift in Debug is several times slower and not realtime.

## Permissions

- **Microphone** — capture speech while the hotkey is held.
- **Accessibility** — type the transcription into other apps' fields.
- **Input Monitoring** — global push-to-talk hotkey.

## Privacy & analytics

Dictation is fully on-device. Anonymous usage/error analytics
([PostHog](https://posthog.com)) are **opt-in** — off until you enable them on
the first-run Welcome screen (or in Settings), and only anonymous events and
errors are ever sent, never audio or transcripts.

Builds from source ship with analytics **disabled** unless `TUIST_MURMUR_POSTHOG_KEY`
is set at build time, so forks never phone home.

## License

[MIT](./LICENSE) © 2026 Aleksandr Beshkenadze
