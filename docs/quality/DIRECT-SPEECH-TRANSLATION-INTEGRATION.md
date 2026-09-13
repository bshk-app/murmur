# Direct speech translation integration report

Status: implemented on `feat/canary-batching`; standalone test UI removed.

## Product behavior

The Speech settings contain one option, **Use direct translation where
available**, disabled by default. No model names or route badges are shown in
recording, keyboard, notes, downloads, errors, notifications, or exports.

When enabled, a supported English↔X voice request uses direct speech recognition
and translation for the entire utterance. Other pairs use the existing speech
recognition followed by text translation. The decision is captured when the
utterance begins; changing the preference affects the next recording. Text
translation, Safari translation, and transcription-only audio imports are
unchanged.

The standalone **Test speech translation** screen, its Settings row, sheet state,
deep link, controller, and view have been removed. Direct translation remains
available only in normal voice translation and keyboard dictation.

## Language matrix

The authoritative internal set contains 25 language codes:

`bg, hr, cs, da, nl, en, et, fi, fr, de, el, hu, it, lv, lt, mt, pl, pt, ro, sk, sl, es, sv, ru, uk`

Direct translation contains exactly 48 directed pairs: English to each of the
other 24 languages and each of those languages to English. RU↔EN and FI↔EN are
included. RU↔FI, English↔Irish, Arabic↔English, Norwegian↔English, unknown codes,
and equal source/target pairs are excluded. The qualification check compares the
runtime set to an independent literal, visits all 625 combinations, counts the
48 accepted pairs, and verifies every tokenizer language token.

## Runtime integration

`DirectSpeechSession` owns model preparation, bounded PCM delivery, audio-file
finalization, interruption handling, and serial batch results. Normal recording
uses foreground CPU/GPU execution. The keyboard prepares a CPU-only runtime in
the containing app before it backgrounds, keeps the microphone armed between
utterances, discards idle samples, and opens each WAV at an atomic capture
boundary.

The live PCM queue is capped at 128 frames (about 32.8 seconds or 2 MiB of Float
PCM). Processing awaits each inference and persistence callback before accepting
the next result. Overflow, capture conversion errors, decoder failures, WAV
finalization failures, interruption, and cancellation preserve the audio and
completed sections while marking the note incomplete. A failed direct
preparation before recording falls back to translation through text and reports
a neutral explanation.

Only one model owner is active at a time. Moving to text translation, language
preparation, keyboard preparation, or another direct recording unloads the
previous owner first. Direct setup does not mark conventional speech or text
translation packs as downloaded.

## Stored data and compatibility

Notes retain the actual route in the existing internal `model` field using the
neutral identifier `direct-speech-translation`; there is no database migration.
The optional `translationMethod` field in keyboard state is backward compatible
with previously saved states. User exports contain only transcription and
translation text.

## Verification

- 150 MurmurCore tests passed, including repeated-section assembly and decoding
  keyboard state written before `translationMethod` existed.
- 92 translation tests passed; 4 environment-dependent tests were skipped.
- Six audio-file transcription tests passed; one fixture-dependent test skipped.
- Standalone asset, language, PCM, tokenizer, atomic publication, corruption,
  cancellation, and decoder-bound checks passed.
- Signed iPhone and unsigned simulator Debug builds passed, as did the UI host.
- The real simulator app processed the same 36.06-second RU→EN file through both
  routes. Both notes completed with three sections and no incomplete translation;
  their translated output differed as expected.
- The shared CPU-only path processed an 8.64-second RU→EN fixture on Apple M1 Max
  in 7.64 seconds and returned both source and translated text. This validates the
  execution profile, not physical-device latency.
- Repeated Codex review covered ownership, cancellation, capture boundaries,
  persistence, preparation fallback, and navigation. All findings were fixed;
  the final cycle reported no actionable regressions.

## Remaining qualification limits

Direct translation remains experimental and opt-in. The current evidence does
not establish a general quality, latency, energy, or memory advantage over text
translation. Physical keyboard behavior still needs a short end-to-end check in
another app. Long stress, paired phone measurements, and bilingual scored review
remain release-qualification work rather than prerequisites for the opt-in test.
