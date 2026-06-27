<img width="1280" height="640" alt="murmur-og" src="https://github.com/user-attachments/assets/cf9ea362-4b7a-4b98-9264-8ee2f141f1e3" />


# Murmur

> **Just talk. Murmur types it.**

A tiny menu-bar cat that turns your voice into text — instantly, on the fly, in
any app and ~30 languages. Everything runs right on your Mac: no accounts, no
cloud, nothing recorded.

**[⬇ Download for Mac](https://github.com/bshk-app/murmur/releases/latest)** · Free &
open source · powered by [MLX](https://github.com/ml-explore/mlx)

---

## Install

```bash
brew tap bshk-app/homebrew-tap
brew install --cask murmur
```

…or grab the latest `.app` from [Releases](https://github.com/bshk-app/murmur/releases/latest).
Murmur keeps itself up to date in-app via [Sparkle](https://sparkle-project.org).
On first launch a one-time setup downloads the two on-device models (~3.6 GB).

## Three keys, no friction

1. **Hold the shortcut.** One global hotkey (default ⌃⌥Space), anywhere in macOS — the
   menu-bar cat wakes up and starts listening.
2. **Just speak.** Talk naturally. Murmur catches every word in real time — no
   "processing" spinner, no waiting.
3. **It's typed for you.** Words land straight in whatever field has focus — Slack,
   Notes, your terminal, a code comment.

### Fast first, then perfect

The dual-model trick: a lightweight model types an instant draft so you never wait,
and a split second later an accurate model catches up and quietly sharpens each word —
fixing names, punctuation, and homophones in place. You watch it tidy itself up.

### Speaks your language

Auto-detects what you're speaking — around 30 languages, from global majors to most of
Europe — and even handles code-switching between two in one breath.

## Private by design

Your voice never leaves your Mac. Both models run locally, so dictation works on a
plane, in a tunnel, or fully offline.

- **100% offline** — no audio upload, nothing stored, no accounts.
- **Optional diagnostics** — anonymous usage/error analytics
  ([PostHog](https://posthog.com)) are **opt-in**: off until you enable them on the
  Welcome screen (or in Settings), and only anonymous events are ever sent — never
  your audio or transcripts. Builds from source ship with analytics off entirely.

## Requirements

- **macOS 15 (Sequoia)** or later
- **Apple Silicon** (M1 or newer) — speech runs on MLX / Metal

## Permissions

- **Microphone** — to hear you while you hold the shortcut.
- **Accessibility** — to type the text into other apps. Optional: without it,
  dictation still shows live in a HUD.

## Build from source

Murmur is a [Tuist](https://tuist.io) project; the dictation core lives in `MurmurKit/`
and the app (`Sources/Murmur`) is a thin UI over it.

```bash
make build   # generate the Xcode project + build Release
make run     # build and launch the menu-bar agent
```

Builds are Release — MLX-Swift in Debug is several times slower and not realtime.
Analytics stay off in source builds unless `TUIST_MURMUR_POSTHOG_KEY` is set at build time.

## Built on

On-device speech via **[mlx-audio-swift](https://github.com/beshkenadze/mlx-audio-swift)**
(`MurmurKit` → MLXAudioSTT / VAD / Core) on **[MLX](https://github.com/ml-explore/mlx-swift)**;
models from the Hugging Face Hub via
**[swift-huggingface](https://github.com/huggingface/swift-huggingface)**; the global
hotkey via **[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)**;
in-app updates via **[Sparkle](https://github.com/sparkle-project/Sparkle)**; optional
diagnostics via **[PostHog](https://github.com/PostHog/posthog-ios)**.

## License

[MIT](./LICENSE) © 2026 Aleksandr Beshkenadze
