# Changelog

All notable changes to Murmur are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

This file is the single source of truth for release notes: the section matching
`VERSION` becomes both the Sparkle update description and the GitHub Release
body. Publishing without a matching section is refused.

release-please drafts each section from conventional commits and opens a release
PR. Rewrite those generated lines in the PR into concise prose a person should
read in an update panel before merging it.

## [0.3.0](https://github.com/bshk-app/murmur/compare/murmur-v0.2.1...murmur-v0.3.0) (2026-08-25)

### Added

- Settings now decides what happens to recordings of your voice. Murmur can keep
  each dictation as an audio file so a bug can be reproduced from the real
  recording — off unless you ask for it, never uploaded, and now visible instead
  of hidden. You can see the files, delete them in one step, and what stays is
  the last twenty for seven days.

### Fixed

- The overlay leaves the moment you stop. Releasing the hotkey used to hold it a
  second longer, and stopping captions held it for four; now the panel goes as
  soon as your words have landed, and while the final wording is being decided it
  says so instead of pretending to still be listening.
- If the text could not be typed — no Accessibility permission, or a password
  field that refuses paste — the overlay stays and says which of the two it was,
  rather than disappearing with your sentence.

## [0.2.1](https://github.com/bshk-app/murmur/compare/murmur-v0.2.0...murmur-v0.2.1) (2026-08-24)

### Changed

- Nothing you can see: this build carries the same code as 0.2.0. The release
  pipeline now pins the speech engine to the exact revision it was tested
  against and restores the app's dependency lock, so every future build is
  reproducible from its tag.

## [0.2.0](https://github.com/bshk-app/murmur/compare/murmur-0.1.1...murmur-v0.2.0) (2026-08-24)

### Added

- Live captions now sharpen themselves phrase by phrase while you keep talking,
  instead of jumping at the end of a sentence.
- A "Dictate and send" shortcut types your words and presses Return for you.
- Choose your microphone in the menu instead of following the system default.

### Fixed

- The dictation overlay stays on the display you are working on, and no longer
  slides out of view during long dictations.
- A recording keeps the microphone and the start/stop gesture it began with,
  even if you change Settings while it runs.
- Text appears as soon as the fast model has it, and no longer takes seconds to
  land after you stop speaking.

## [Unreleased]

## [0.1.1] - 2026-06-27

### Changed

- Refreshed the distributed build and project presentation. No transcription
  behavior changed from 0.1.0.

[Unreleased]: https://github.com/bshk-app/murmur/compare/murmur-v0.1.1...HEAD
[0.1.1]: https://github.com/bshk-app/murmur/releases/tag/murmur-v0.1.1
