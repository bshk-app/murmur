# Changelog

All notable changes to Murmur are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

This file is the single source of truth for release notes: the section matching
`VERSION` becomes both the Sparkle update description and the GitHub Release
body. Publishing without a matching section is refused.

release-please drafts each section from conventional commits and opens a release
PR. Rewrite those generated lines in the PR into concise prose a person should
read in an update panel before merging it.

## [0.5.0](https://github.com/bshk-app/murmur/compare/murmur-v0.4.0...murmur-v0.5.0) (2026-10-10)


### Added

* **ios:** animate mascot reactions on tap ([e44cf9d](https://github.com/bshk-app/murmur/commit/e44cf9de03ea09ad699538248666f3e942d1a636))
* **ios:** Speech recognition makes fewer mistakes, especially in Finnish. The new model downloads once; delete "Previous speech recognition model" in Storage to free space ([cbbdf55](https://github.com/bshk-app/murmur/commit/cbbdf55da3003a5d5cb0f7aad2964765a67c0d31))
* **ios:** Translate text in photos ([cae1bfb](https://github.com/bshk-app/murmur/commit/cae1bfbcab99153eb2050078422bce16e38255c4))
* **macos:** Live captions get their own window you can keep on any display and restyle, and the menu can start and stop ([34fd8e8](https://github.com/bshk-app/murmur/commit/34fd8e8da525da61c00a8f950c6b15c0aa385867))
* **macos:** Tap right ⌘ to dictate, then Return to insert or Esc to cancel; push-to-talk now defaults to ⌥Space and warns when macOS uses the same chord ([5473ed7](https://github.com/bshk-app/murmur/commit/5473ed75cdeb45ee15d550e4d8595c0a306daf2b))
* **macos:** The on-screen pill is now a small capsule that stays put while you speak; hold right ⌘ to talk and let go to insert ([e9080cc](https://github.com/bshk-app/murmur/commit/e9080ccaf1fa67d896ef23c7234b37d4df18050d))
* **macos:** While you dictate, the draft is drawn right at your cursor, as if already typed; Return inserts the corrected text in its place ([2266241](https://github.com/bshk-app/murmur/commit/22662418cb734679f62361980df6ce04b3763109))
* **watch:** record voice notes on Apple Watch and get the text back ([30f072d](https://github.com/bshk-app/murmur/commit/30f072de655578923cac4b7e63d9a49b4683d7a9))


### Fixed

* **ios:** Buttons and labels on a note now match the rest of the app ([b89f95b](https://github.com/bshk-app/murmur/commit/b89f95b1d49ae28e547b3952272ea5f7a9ca96a7))
* **ios:** ship the current Bergamot sources in the source offer ([2655455](https://github.com/bshk-app/murmur/commit/2655455503d3930d10ea3283293ef5c38a2f2e2e))
* **ios:** The Translate sheet shows progress while it checks your language packs instead of staying blank ([0272fca](https://github.com/bshk-app/murmur/commit/0272fca47affda61f9724fdee301cafa265dbc12))
* **ios:** track the build inputs the source offer ships ([708d2e9](https://github.com/bshk-app/murmur/commit/708d2e96fdae331f9a852d85f74aeed01ace833e))
* **ios:** Translation in other apps no longer runs out of memory ([ef929bf](https://github.com/bshk-app/murmur/commit/ef929bf7b08650f458c7191897d98532980dc7f3))
* **macos:** A dictation is no longer replaced by whatever was on your clipboard when the app is slow to paste ([48d920c](https://github.com/bshk-app/murmur/commit/48d920c5fc5cbaa61f67448cc291893641bcb061))
* **macos:** The language menu offers only languages the Mac can recognize ([21f4bc7](https://github.com/bshk-app/murmur/commit/21f4bc734d7f234e9bd33c964137749ba436d613))
* **macos:** The mascot holds its final pose after a one-time animation ([dc454d4](https://github.com/bshk-app/murmur/commit/dc454d40d338105cd8ccd2191951cd087a2ef1c2))
* **speech:** A damaged live-dictation model is downloaded again, so the draft no longer silently stays empty ([b9ae6d5](https://github.com/bshk-app/murmur/commit/b9ae6d5299b85667b6c0c27a6410ae82e545ee50))
* **speech:** fail recordings on capture conversion errors ([d1f1347](https://github.com/bshk-app/murmur/commit/d1f1347dbdc4fb94a5aedf357623d11a51bca98e))
* **speech:** preserve capture boundaries and finalization errors ([e903148](https://github.com/bshk-app/murmur/commit/e903148bd81cb11b956744658f30843c018c59f7))
* **speech:** release direct sessions and deferred routes ([e9ea324](https://github.com/bshk-app/murmur/commit/e9ea32491429f5c5f3ebfd5099de3dbcbe3df965))
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
