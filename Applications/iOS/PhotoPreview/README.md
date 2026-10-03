# Static photo translation — 2026-09-18

The current source integrates photo translation into **Translate → Photo**, alongside Text and Voice. The separate Notes-list entry has been removed following the user's placement correction. Uploaded build 27 predates this correction. The standalone `MurmatorPhotoPreview` target installs as **Murmator Photo** (`app.bshk.murmur.photo-preview`) and uses the same screen and engines, with its own model cache.

The screen imports a library image or a camera photo, normalizes orientation, recognizes text locally, groups nearby lines, translates with the existing local translation engine, and overlays translated blocks. Users can inspect the original, correct recognized text, translate again, rotate the photo, change languages, cancel processing and share the translated text. Recognition models download on demand with SHA256 validation. Photos and text are not uploaded for recognition or translation.

## Verification

- Main app and preview: Debug arm64 Simulator builds passed; preview signed device build/install passed.
- Six grouping unit tests passed.
- Two UI tests passed: opening/closing from Notes; actual OCR/translation, original toggle, block correction, retranslating, rotation and cancellation.
- Public Finnish photo: `TERVETULOA` → `WELCOME`, correct. Simulator full pipeline 2.75 seconds; this is a single smoke test, not an iPhone benchmark.
- Public Russian photo: ground truth `НЕ КУРИТЬ!`; recognized `OНE КУРИТЬ`, translated `SEN OSTA`, incorrect. The small, distant lettering remains a quality regression fixture. A completed pipeline does not imply a correct translation.
- Final iPhone 15 Pro preview completed English → Finnish twice after process relaunch: all 20 blocks processed, `didOCR=true`, no runtime error. Full-pipeline times were **3.65 s and 2.37 s**, with already-downloaded models; these include image preparation, OCR, translation and translator unload. Peak physical footprint was **445.0 and 446.9 MiB**; immediately after unload it was **202.6 and 205.7 MiB**. Two runs are smoke measurements, not a latency distribution or a cold-install benchmark. Raw results: `Prototypes/OCRBenchmark/results/photo-preview-device-final.json` and `photo-preview-device-repeat.json`.
- Device quality remains imperfect: `Downloading` was recognized as `Dowmloading`, and `connecting` as `conmecting`, with the latter leading to an incorrect Finnish translation. Successful processing is distinct from language accuracy. Earlier recorded 0.076-second repeat reused results and is **not** a valid full-pipeline timing; the final build disables redundant translation and restricts diagnostics to the explicit initial test fixture.

Photo sources: [Tervetuloa kotiin](https://commons.wikimedia.org/wiki/File:Tervetuloa_kotiin_(3389869614).jpg), Dave_S. / David E Smith, CC BY 2.0; [Не курить](https://commons.wikimedia.org/wiki/File:Не_курить_-_panoramio.jpg), S Petr, CC BY 3.0. Original fixtures, attribution metadata, JSON results and screenshot are under `Prototypes/OCRBenchmark/data/commons` and `Prototypes/OCRBenchmark/results` (local research artifacts, not bundled assets).

## Build and next checks

Run `Engine/OCR/Scripts/prepare.sh`, then generate the iOS workspace with Tuist. Build `MurMurMobile` for the integrated app or `MurmatorPhotoPreview` for the independent device test. Native artifact preparation requires Xcode, CocoaPods, Ruby/xcodeproj and uv. Clean bootstrap has not yet been independently qualified.

Debug smoke tests accept `--photo-translation-probe`, read `Documents/photo-probe.jpg`, and write `Documents/photo-probe-result.json`. The preview accepts `PHOTO_PROBE_SOURCE` and `PHOTO_PROBE_TARGET`; defaults are English → Finnish. These diagnostics are not captured for subsequently selected personal photos.

The 34-language catalog expresses model coverage, not validated accuracy. Next: fix and measure small-text Cyrillic recognition on a labeled photo set, broaden Arabic/Greek/Latin coverage, complete repeated physical-device latency/memory runs and exercise the camera shutter on device. Live camera tracking is not implemented. The production app's device signing/release build is separate from the successfully installed preview.

## Simulator small-text investigation

The agent-runnable regression harness is `Tests/scene-smoke.rb`. It launches the installed preview with the original full photo, waits for a fresh result, and checks the expected transcription (including phrases split across adjacent regions). It fails on spurious letters within a region, rather than accepting a substring. Models must already be present; the harness times out after 120 seconds.

```sh
ruby Applications/iOS/PhotoPreview/Tests/scene-smoke.rb Prototypes/OCRBenchmark/data/commons/ru.jpg ru fi 'НЕ КУРИТЬ' /tmp/ru-result.json
OCR_PROBE_DILATE=0 ruby Applications/iOS/PhotoPreview/Tests/scene-smoke.rb Prototypes/OCRBenchmark/data/cb26499cae74775c.jpg en fi 'Go back (connecting will continue)' /tmp/en-result.json
```

The first command remains red (`OНE КУРИТЬ`); the second passes. Visual inspection revealed that the extra O is a **black tire beside the red lettering**, included in the detected text region. It is not simply a hallucinated letter or a low-resolution failure.

| Experiment (one variable at a time) | Russian sign | English screen |
| --- | --- | --- |
| Baseline, 2048px, dilation enabled | Fails; tire included | `Dowmloading`, `conmectung` |
| Preserve up to 4096px | Fails; tire still included | Not tested |
| Unclip ratio 1.2 instead of 1.6 | Fails | `Dowmioading`, `conmecting` |
| Unclip ratio 1.0 | Fails | Not tested |
| Disable 2×2 detector-mask dilation | Fails | `Downloading`, `connecting` correct |

Finnish `TERVETULOA` also passes with dilation disabled. English produced 22 regions rather than 21; this requires recall/false-positive review on a broader corpus before promotion. The successful English run took 2.30 seconds and Finnish 0.99 seconds on the simulator; these are not device performance estimates. Simulator and device baselines differ in region grouping/transcription, so simulator gains still require later device validation.

Experimental controls are restricted to the explicit simulator probe (`PHOTO_PROBE_MAX_PIXELS=2048|4096`, `OCR_PROBE_UNCLIP=1.0…2.0`, `OCR_PROBE_DILATE=0`). Normal app defaults and the installed phone build are unchanged. No text-specific correction or forced deletion of O was added. Next diagnostic step: test higher-resolution/local redetection to separate nearby non-text objects, and evaluate mask changes on more labeled scenes before changing defaults.

### Local redetection experiment — rejected for default use

Implemented `OCR_PROBE_REDETECT=1`, restricted to the simulator probe. It takes a source-image neighborhood around each small detected region, scales it into the existing fixed detector shape, reruns detection, and maps candidates back to the original image. It uses the same detector/model, not a text-specific correction. Work is limited to scenes with at most 30 initial regions and regions no taller than 100 pixels; large text retains its original detection. Empty local results also retain the original region.

| Fixture | Result with local redetection | Full pipeline on simulator |
| --- | --- | --- |
| Russian sign | Fail: `ОНЕ КУРИТЬ`; tire remains included | 1.61 s |
| English screen | Fail: extra symbols, overlapping fragments, `Comectung` | 4.57 s |
| Finnish sign | Pass: `TERVETULOA`; large region bypasses refinement | 1.08 s |

Combining redetection with disabled dilation still fails on Russian (`ОНЕ КУРИТЬ`, 1.05 s). Raw outputs are `ru-redetect-regression.json`, `en-redetect-regression.json`, `fi-redetect-regression.json`, and `ru-redetect-nodilate-regression.json` under the local benchmark results directory. These single-run simulator timings are diagnostic only.

Conclusion: increasing local scale with the same detector does not resolve the tire/text confusion on this fixture, and independent per-region redetection introduces overlap problems on dense scenes. The experiment remains opt-in, with no change to normal app behavior or the phone build. Before any production use it would need ownership/deduplication of overlapping regions and broader quality evaluation. The next useful comparison is a different detector on the same labeled fixtures; merely increasing resolution or tuning padding has not fixed this scene.

### Alternate detectors — no replacement selected

Compared existing benchmark weights for **PP-OCRv6 Small** and **PP-OCRv5 Mobile** against the bundled v6 Tiny. Recognizers, original full images, 2048px preparation, letterboxing, detector input dimensions, FP16 treatment and postprocessing were held constant. Local redetection was disabled. These are controlled comparisons in this pipeline, not official model accuracy scores.

| Detector | Russian sign | English `Go back (connecting will continue)` | Finnish |
| --- | --- | --- | --- |
| v6 Tiny baseline | Extra O | Incorrect transcription | Pass |
| v6 Tiny, dilation disabled (earlier test) | Extra O | Pass | Pass |
| v6 Small | `О НЕ КУРИТЬ!` — extra O remains | `Go back (conmecting wili continue)` | Pass |
| v5 Mobile | `О НЕ КУРИТЬ!` — extra O remains | Entire target line absent | Pass |

v6 Small with dilation disabled also retains the extra O. One-run full pipeline times (Russian/English/Finnish) were 1.29/2.31/1.06 seconds for v6 Small and 3.94/3.38/2.07 seconds for v5 Mobile. Cache/first-load effects are not controlled, so these numbers must not be used to rank model speed. Native model outputs were obtained on the arm64 simulator, not substituted or mocked.

Reproduction: export with `Tests/prepare_detector_probe.py SOURCE_ONNX OUTPUT_DIRECTORY [v6-small|v5-mobile]`, copy output files into the preview container's `Documents/probe-detectors`, then run `scene-smoke.rb` with `OCR_PROBE_DETECTOR=v6-small` or `v5-mobile`. The exporter checks pinned source SHA256 values and records exported hashes. Models stay outside shipped resources; the override is Debug/simulator-only. Raw results are `ru/en/fi-v6small-regression.json`, `ru/en/fi-v5mobile-regression.json`, and `ru-v6small-nodilate-regression.json` in the local benchmark results directory.

No replacement was promoted. The tire is a shared scene ambiguity for these detectors; this experiment does not establish that a larger detector will solve it. Next priority is broader labeled-scene testing of tiny without dilation and separating recognition errors from detection errors, rather than tuning the pipeline around one tire. User correction remains available for this unresolved example. The physical phone was not modified during this comparison.

### Paired 12-photo validation of dilation

Completed **24 real simulator launches** on the existing deterministic TextOCR selection: four sparse, four medium and four dense images. Selection predates these experiments and is independent of OCR results. Image checksums were verified. Source/target stayed English → Finnish, with the bundled tiny detector and recognizer; only mask dilation changed. Execution order alternated by image. This is a small diagnostic sample, not qualification of 34 languages.

| Measure | Baseline dilation | No dilation |
| --- | ---: | ---: |
| Reference word tokens | 347 | 347 |
| Exact normalized word matches | 134 | 146 |
| Reference recovery proxy | 38.6% | 42.1% |
| All predicted tokens | 327 | 367 |
| Matched / predicted proxy | 41.0% | 39.8% |
| Matches also near reference location | 127 | 135 |
| Images with no text detected | 1 | 1 |
| Translation decoding-limit failures | 0 | 1 |

No dilation gained exact matches on six images and tied on six. With the location constraint, one dense scene regressed from 58 to 57 matches despite its bag-of-words gain. On the English screen it recovered 30/30 reference tokens, compared with 28/30 at baseline, but also produced one unmatched token. Overall unmatched predictions increased from 193 to 221. These are **not pure false-positive counts**: they include incorrect words, text annotated illegible, and potentially unannotated text. Likewise unmatched reference tokens do not distinguish missed detection from wrong transcription.

The translation failure on `cd3f9f7c7ccf7552` reproduced in a separate launch. Eight blocks translated before a noisy OCR paragraph caused the local translation decoder to reach its 512-token limit without EOS; remaining blocks were left untranslated. The app returned an error rather than crashing. This is a user-visible regression in the complete pipeline, despite improved word recovery, and blocks promoting no-dilation as the default.

Reproduce with `Tests/compare_dilation.py OUTPUT_DIRECTORY` using the existing Python environment through uv. It launches the real preview via `scene-smoke.rb`, saves each raw response, and writes `comparison.json`. The scoring code has four passing unit tests covering duplicate occurrences, spatial mismatch, illegible annotations and empty detection. It uses NFC/casefold word tokens and multiset overlap; the spatial check requires an annotation's center within the predicted block plus a 1% image margin. It is not official TextOCR accuracy, CER or WER.

Local artifacts: `Prototypes/OCRBenchmark/results/photo-dilation-comparison/comparison.json`, the 24 per-image responses, and `translation-failure-repeat.json`. No app defaults or physical-device build changed. Decision: retain the candidate for further work, but first handle failure of an individual translation block so one noisy paragraph does not stop the rest, then broaden accuracy validation. The overall recovery remains too low on difficult scenes to claim the photo feature is ready for general release.

### Independent translation failures — implemented and verified

Translation now catches failures per block and continues with subsequent blocks. Cancellation still ends the job, and model preparation/OCR failures remain whole-job errors. Failed blocks retain their original text, show a localized explanation, and offer a per-block retry. Users can edit a block and translate it independently; already translated blocks are skipped. Starting a new photo or changing the source/target clears obsolete failure state. The general Translate photo button retries remaining untranslated blocks.

On the same real failing fixture (`cd3f9f7c7ccf7552`, tiny with dilation disabled), the updated simulator preview produced **20 translated blocks and one explicitly marked failure**, compared with eight translated blocks followed by an aborted run previously. All 12 blocks after the failed paragraph were translated. The run took 14.18 seconds, including the unsuccessful decoding attempt; this is resilience verification, not a speed improvement. OCR/translations of badly recognized paragraphs can still be incorrect.

Validation:

- `Tests/assert_partial_result.py` rejects the saved pre-fix response and passes `Prototypes/OCRBenchmark/results/photo-partial-translation-fixed.json`.
- Three real-engine UI tests passed: opening/closing from Notes; partial failure → edit original to Welcome → retry just that block → Tervetuloa; ordinary photo translation/correction/rotation/cancellation.
- Localization generation validated 515 keys in six languages; `git diff --check` passed.

The new regression test uses `PHOTO_PROBE_FIXTURE=partial-failure` and `Documents/photo-failure-probe.jpg` in the main app's explicit Debug probe. No inference is mocked. The physical phone and normal OCR dilation setting remain unchanged. Partial translation is now usable even when one paragraph fails; this does not resolve the low OCR recovery measured above or qualify all languages.
