# Changelog

All notable changes to Murmur are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

This file is the single source of truth for release notes: the section matching
`VERSION` becomes both the Sparkle update description and the GitHub Release
body. Publishing without a matching section is refused.

release-please drafts each section from conventional commits and opens a release
PR. Rewrite those generated lines in the PR into concise prose a person should
read in an update panel before merging it.

## [0.5.0](https://github.com/bshk-app/murmur/compare/murmur-v0.4.0...murmur-v0.5.0) (2026-09-15)


### Added

* integrate qualified translation profiles and bound model verification memory ([552a43c](https://github.com/bshk-app/murmur/commit/552a43cc401986d8c9ebe84252417c04c1272fcf))
* **ios:** animate mascot reactions on tap ([e44cf9d](https://github.com/bshk-app/murmur/commit/e44cf9de03ea09ad699538248666f3e942d1a636))
* **speech:** add bounded batching and experimental Canary recording ([6a2050f](https://github.com/bshk-app/murmur/commit/6a2050f97f3a7177ea2cc3c25aea65b6b531a270))
* **speech:** add optional direct voice translation ([b8f5e6c](https://github.com/bshk-app/murmur/commit/b8f5e6c703c120cbde1e253e071ed5f49f76adcb))
* **watch:** record voice notes on Apple Watch and get the text back ([30f072d](https://github.com/bshk-app/murmur/commit/30f072de655578923cac4b7e63d9a49b4683d7a9))


### Fixed

* **ios:** Buttons and labels on a note now match the rest of the app ([b89f95b](https://github.com/bshk-app/murmur/commit/b89f95b1d49ae28e547b3952272ea5f7a9ca96a7))
* **ios:** ship the current Bergamot sources in the source offer ([2655455](https://github.com/bshk-app/murmur/commit/2655455503d3930d10ea3283293ef5c38a2f2e2e))
* **ios:** track the build inputs the source offer ships ([708d2e9](https://github.com/bshk-app/murmur/commit/708d2e96fdae331f9a852d85f74aeed01ace833e))
* **speech:** fail recordings on capture conversion errors ([d1f1347](https://github.com/bshk-app/murmur/commit/d1f1347dbdc4fb94a5aedf357623d11a51bca98e))
* **speech:** isolate direct route readiness ([ee32d8f](https://github.com/bshk-app/murmur/commit/ee32d8f854a22c57db559bfeb95ce0859a192f4a))
* **speech:** preserve capture boundaries and finalization errors ([e903148](https://github.com/bshk-app/murmur/commit/e903148bd81cb11b956744658f30843c018c59f7))
* **speech:** release direct sessions and deferred routes ([e9ea324](https://github.com/bshk-app/murmur/commit/e9ea32491429f5c5f3ebfd5099de3dbcbe3df965))
* **speech:** surface direct session failures promptly ([fa4c785](https://github.com/bshk-app/murmur/commit/fa4c785f893879559eb2788e4e5169cd6e2aa4fe))
* **ui:** remove translation route badges ([17c193a](https://github.com/bshk-app/murmur/commit/17c193ac051dce3ada9d51b3e494e40628cc5859))


### Changed

* **ui:** remove standalone speech translation test ([ff18361](https://github.com/bshk-app/murmur/commit/ff18361189ecff8deea57063ebf0b9d02fc0ae31))

## [0.4.0](https://github.com/bshk-app/murmur/compare/murmur-v0.3.1...murmur-v0.4.0) (2026-09-05)


### Added

* **captions:** translate a talk as it is spoken ([010449e](https://github.com/bshk-app/murmur/commit/010449e423699c3a0b892778af7c4c0da74814e0))
* **dictation:** describe the session as a protocol ([c24ce43](https://github.com/bshk-app/murmur/commit/c24ce43e3002477f0aedc5113914b17709302eef))
* **engine:** make the engine configurable and report what the mic heard ([ffc19fe](https://github.com/bshk-app/murmur/commit/ffc19fe637b6f121b5a280fc9b4998ddaf03abb1))
* **hud:** show the translation under what you said ([3eee4b0](https://github.com/bshk-app/murmur/commit/3eee4b0992c6651b81cc9d1e6206ce1a2af8ceda))
* **translation:** a quality tier that translates the finished text ([d196202](https://github.com/bshk-app/murmur/commit/d1962021a9eac255e13e2502f591e4f851dd9aea))
* **translation:** dictate in one language, paste in another ([a415bd6](https://github.com/bshk-app/murmur/commit/a415bd6d4e057caa1f5921251d8ad421b00933d9))


### Fixed

* **analytics:** report the lane that ran, not the one that was requested ([7f04e8c](https://github.com/bshk-app/murmur/commit/7f04e8cbeaff12ad694cb66e48cb5b76d32ba901))
* **translation:** translate what you actually said, not what the menu says now ([27caa14](https://github.com/bshk-app/murmur/commit/27caa144061c8ad67555f9273db1b1daff417a95))


### Changed

* **dictation:** hold the session through the protocol ([ae1b066](https://github.com/bshk-app/murmur/commit/ae1b0660ff21b2ff3e6bc84f96662a8d5f5f9c32))

## [0.3.1](https://github.com/bshk-app/murmur/compare/murmur-v0.3.0...murmur-v0.3.1) (2026-08-25)


### Fixed

* **accessibility:** menu segments work with VoiceOver ([84a23e0](https://github.com/bshk-app/murmur/commit/84a23e08858be2234bcc9363ef6d9549f21dae35))
* **captions:** silence stops redrawing the overlay ([3c97bbf](https://github.com/bshk-app/murmur/commit/3c97bbf6902362a51667a67adb64ca9b081d69bb))

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
