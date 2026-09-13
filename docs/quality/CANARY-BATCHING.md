# Canary and bounded audio processing

Implemented 2026-09-12. Canary remains an internal experimental engine and does
not replace the normal dictation model. Its former standalone test screen and
deep link were removed on 2026-09-13. Models download once, with immutable
revision and SHA256 checks. Recordings and completed text sections are saved in
Notes through the ordinary voice and keyboard flows.

Updated 2026-09-13: the user interface does not expose model names. The general
Speech setting **Use direct translation where available** is off by default. When on,
supported English↔X voice recording and keyboard sessions use direct ASR+AST;
other pairs retain translation through text. The selected route is fixed for an
utterance and stored internally in note/session metadata. Working screens do not
show an additional route badge or test tool; the preference lives only in Settings.

`DirectSpeechTranslation.supportedLanguages` is the authoritative 25-language
set from the upstream model card. Its exhaustive check compares against an
independent literal set, visits all 625 source/target combinations, verifies 48
directed English↔X translation pairs and checks every tokenizer language token.

## Processing behavior

- `AudioBatchProcessor` is shared by ordinary audio-file transcription and
  Canary. It awaits each inference and result callback before reading more PCM.
- Canary accepts at most 240,000 mono 16 kHz samples per inference. VAD chooses
  silence boundaries; continuous speech is cut at the last full 4096-sample
  frame within the limit (14.848 seconds). The final tail is preserved.
- Windows do not overlap. No text deduplication removes legitimate repetitions.
  A forced boundary can split a word; this remains a quality limitation.
- Recording sends bounded PCM frames to the processor while preserving the full
  WAV. The live queue holds at most 128 frames (about 32.8 seconds / 2 MiB of
  Float PCM). If processing falls behind, recording stops with an explicit error;
  existing audio and completed sections remain saved.
- Stop drains the remaining captured audio. Cancel preserves completed sections
  and marks the note incomplete. Closing/backgrounding cancels and unloads
  models. Capture interruptions finish the captured input.
- English ↔ the other 24 supported Canary languages uses direct speech translation:
  one encoder pass, then transcription and translation decoder passes. Other
  supported target pairs use Canary transcription → OPUS through the existing
  quality translation service. Source text is saved before OPUS runs.

Physical iOS devices below 5 GiB RAM are refused by the experimental screen,
following the previous iPhone XS process-limit termination. This conservative
floor is not a device qualification result. Batching bounds PCM and queued work;
it does not shrink model weights or the fixed 15-second encoder tensors.

## Validation and comparison

On Apple M1 Max, the real runtime returned both transcription and direct
translation for EN ↔ RU/FI/DE/FR (eight routes). ASR+AST calls took 1.74–2.62 s
after loading in that short-fixture run. OPUS was also run on those actual Canary
transcripts. There is no overall quality winner: direct DE→EN recovered T-Rex
where ASR+OPUS retained T-Wex; direct FR→EN weakened “malicious fire”; direct
RU→EN lost part of the size comparison. No blind bilingual evaluation was done.

The public `CanaryTranscriber` file path passed these execution checks:

| Input | Route | Result |
| --- | --- | --- |
| 36.06 s, three repeated clips with pauses | RU→EN direct | Three windows, all repetitions retained; 5.27 s processing |
| 23.04 s, synthetic concatenation without added silence | RU→EN direct | Two adjacent windows covering samples 0…368640; 6.08 s processing |
| 16.92 s natural fixture, including silence | RU→FI via OPUS | Source and Finnish translation returned; 2.78 s processing |

These are Mac execution checks, not phone latency, memory or translation-quality
qualification. Raw reports, fixture metadata, model hashes and exact output texts
are under `/Volumes/DATA/Murmur-models/canary-batching/`: `direct-matrix.json`,
`comparison.json`, `long-ru-en.json`, `continuous-ru-en.json`, `fallback-ru-fi.json`.

Core tests cover VAD tails, forced limits, exact sample ranges, resume boundaries,
bounded live buffering, overflow and cancellation. Canary standalone checks cover
all language pairs, invalid PCM, decoder limits, corrupt cached assets, verified
retry and atomic model publication. Both iOS device and simulator Debug builds
pass. In the real simulator app, Files import of the 36.06-second fixture saved
all three utterances and translations; SQLite records confirmed completed
transcription, closed capture and no incomplete translation. The full app screen
also exposed a case-sensitive container-path error (`Murmur` versus the existing
`MurMur`), which was fixed and the import rerun successfully. See
`simulator-complete.png` and `simulator-persistence.json` in the artifact directory.
The simulator used real models and a public fixture, with no injected result text.
Cancelling a second, 360.6-second synthetic import while inference was active kept
four completed utterances, their translations and the full copied audio. SQLite
confirmed `transcriptionComplete=false`, `translationIncomplete=true` and
`captureClosed=true`; controls became available again. See `simulator-cancelled.png`.

Reproduce the file execution path after building `murmur-cli`:

```sh
murmur-cli --canary-batch-probe --wav input.wav --source ru --target en \
  --json-out /tmp/canary-direct.json
murmur-cli --canary-batch-probe --wav input.wav --source ru --target fi \
  --translation-models /path/to/translation-models --json-out /tmp/canary-opus.json
bash Engine/Speech/Scripts/test-canary-qualification.sh
```
