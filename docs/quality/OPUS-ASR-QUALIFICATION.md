# OPUS and ASR release qualification

This repository contains a qualification **gate**, not completed evidence. No ASR
candidate is promoted by the files in `Engine/Speech/Qualification`. The source
snapshot records code hashes and declared pins, deliberately with null quality
and performance fields. Recapture it before each study:

```sh
uv run --no-project python Engine/Speech/Qualification/capture_baseline.py > baseline-source.json
uv run --no-project python -m unittest discover -s Engine/Speech/Qualification -p 'test_*.py' -v
uv run --no-project python Engine/Speech/Qualification/gate.py /path/to/evidence.json
```

The gate prints JSON and exits 1 when evidence is incomplete or budgets fail.
It is an offline audit prerequisite; it does not change app defaults. Host,
reviewer, dataset completeness, and metric declarations remain trusted inputs,
as they are in Omni Bench. SHA256 verification detects changed/missing artifacts,
not dishonest measurements. Only audited real run bundles may be submitted;
unit-test fixtures are never qualifying evidence.

## Reproducible experiment

Use Omni Bench as the canonical dataset/producer/scorer framework. Pin its actual
checkout, Registry, schemas and scoring implementations in every study. The
external CanaryProbe study currently uses schema 0.6.0; do not assume the older
0.2.0 version in the generic skill applies. Do not modify canonical schemas or
copy metric implementations into the app.

Each host owns inference, tokenizer, decoder settings, device timing and process
memory. Capture exact model files, conversion toolchain, backend, quantization,
source revision, source diff, model revision, tokenizer and target tags in the
baseline and candidate manifests. Runtime options must match the app profile.
No package name or upstream model card substitutes for a converted artifact hash.

Prepare separate tuning and held-out datasets before model selection. Use the
full available FLORES devtest for the 20 directions between RU/EN/FI/DE/FR;
record the immutable dataset revision, complete manifest, sample IDs and content
hashes. Tune on a disjoint split. Compare ordinary OPUS, tc-big and applicable
group checkpoints using direct and current pivot routes, INT8/control precision,
beam 1/4/8 and checkpoint defaults. Reject unusable conversion/language/tag/license
combinations before inference. Select separately by direction; retain baseline
when quality evidence is ambiguous.

For speech, run the same recording bytes and references through baseline and
each applicable ASR candidate in `asr-candidates.json`, then the same chosen OPUS
profile. Keep oracle source-text MT as a separate diagnostic arm. Include
reading, spontaneous speech, noise and long recordings; an absent stratum blocks
qualification. Record source WER/CER and target chrF++/BLEU using Omni Bench's
scorers. Record transcript and translation hypotheses for omissions, repetitions,
wrong language, numbers, names, links and negation review. Canary direct AST is a
control only. Its short-window success does not qualify long transcript merging.

Lock selection before blind bilingual review of at least 100 held-out samples
per direction plus disputed examples. Preserve blinded assignments, reviewer ID,
ratings, stratum decisions and unblinding record. A reviewer must explicitly
accept improvement without meaningful stratum regressions; metric presence alone
cannot promote a candidate.

## Device protocol

Use a physical iPhone 15 Pro (`iPhone16,1`), current release configuration and
identical baseline/candidate input bytes. A paired available device was observed
on 2026-09-11; availability is not a measurement. Three distinct repeats are
required for every direction and each scenario: dictation, text and pages.

Measure final latency from end of speech or explicit text/page request; retain
raw per-sample observations, median, p95 and cold load separately. Dictation also
records first draft, every draft update, confirmed-fragment stability and
correction-to-translation completion under simultaneous ASR and OPUS load.
Budget p95 final ≤2×, draft p95 ≤1.1× and total process peak footprint ≤1.2× the
matched baseline. Never report an MLX allocation limit as process footprint.

Run a 30-minute combined speech/translation session per qualifying direction;
retain sampled process footprint, memory-warning and crash events, monotonic
queue depth, input/output progress and thermal state. No warnings, crashes or
growing backlog are allowed. Verify offline launch, cancellation, language
changes, reload, corrupt packages, unload and rollback with retained logs.

### Hardware admission

Keep app installation, backend capability and measured profile qualification
separate. The XS smoke can run OPUS but crashes in the current MLX Silero
warm-up; its Canary process was terminated with `per-process-limit`. Those
failures do not imply that every ASR backend is impossible on that device.

The current MLX matrix kernel requires at least Metal Apple7 features. A runtime
`MTLDevice.supportsFamily(.apple7)` check before MLX initialization is a necessary
admission check, not proof that the whole model fits or performs well. A future
hardware guard must run before `GPU.set(memoryLimit:)` and report unsupported
hardware without triggering the fatal MLX error handler. Do not treat changing
the default MLX device to CPU as a verified fallback.

Enable a heavy speech profile only for a tested device/OS/backend/model
combination. Physical RAM alone is insufficient: measure the whole process,
startup transients, warnings and sustained thermal/backlog behavior. User reports
of working iPhone 13 Pro and iPad Pro devices are useful selection evidence,
not release qualification. Do not infer ordinary iPhone 13 support from 13 Pro.

The existing implementation does not yet enforce this proposed hardware policy.
Do not silently turn it into a blanket App Store restriction: older devices may
retain working text/page translation. See Apple's
[GPU capability checks](https://developer.apple.com/documentation/metal/mtldevice/supportsfamily(_:))
and [installation capability filters](https://developer.apple.com/support/required-device-capabilities/).

Diagnostic file replays built with Debug are execution evidence only. A clip's
file end can follow the actual end of speech; its tiny post-file finalization
time is not proof of the requested end-of-speech latency budget. The repeated
30-minute read-speech fixture is an endurance workload, not spontaneous/noisy
speech coverage.

## Evidence envelope and integration

`gate.py` is the version-2 envelope contract. Every artifact reference is
`{"path":"relative/path", "sha256":"hex digest"}` under the envelope directory.
Top-level fields: schema_version=2, evidence_kind=measured, device=iPhone16,1,
simulator=false; source, omni_registry, omni_schemas, baseline_manifest and
candidate_manifest artifact references; disjoint nonempty selection_sample_ids
and heldout_sample_ids; directions containing all 20 unique direction entries.

Each changed direction carries quality_results, human_review, review_assignment_key, diagnostic_review and
lifecycle_artifact references; blind_bilingual, blind_sample_count, reviewer_id,
quality_decision=`improved_without_stratum_regression`; flores_split=devtest,
flores_full_available_split=true; metrics containing baseline/candidate numeric
values for chrf++, bleu, wer, cer; all four speech_strata; passed_lifecycle_checks;
device_runs and stress. Metrics must come from the pinned Omni Bench results;
the envelope is a normalized audit summary, not a second scorer.

Each device run includes scenario, distinct repeat_id, artifact reference,
evidence_kind=measured, device=iPhone16,1 and matching baseline_sample_sha256 /
candidate_sample_sha256 (64 lowercase hex digits), plus baseline_manifest_sha256
and candidate_manifest_sha256 matching the top-level artifact hashes. Baseline and candidate objects contain final_p95_s,
final_median_s, cold_load_s, peak_process_bytes and (dictation) preview_p95_s.
Stress contains artifact, duration_s≥1800 and measured zero memory_warnings,
crashes and queue_growth. Missing data fails closed, including null/nonfinite
numbers. The gate checks each repeat rather than hiding failures in pooled data.

The application profile catalog should reference immutable evidence IDs after
review. Gate success is necessary but does not automatically edit that catalog.
Stage qualified replacements under the internal switch; retain existing defaults
and installed packages until replacement preparation and release review succeed.

## Current gaps

The existing external CanaryProbe study has 64 shared short read-speech samples,
RU/EN/FI, six directions, Mac timing, and no blind human review. It is useful for
candidate selection but does not pass this release protocol. DE/FR, full FLORES,
spontaneous/noisy/long speech coverage, all model/decode arms, paired phone runs,
30-minute stress and bilingual review remain required. Canary now has a separate,
explicitly experimental recording/import screen with serial nonoverlapping windows.
Each model call still has a 15-second limit; the caller handles longer audio.
[Execution checks](CANARY-BATCHING.md) supply no new scored model-quality results
and do not establish that any replacement is better.

## In-app ASR profile and telemetry hooks

`SpeechRecognitionProfile.resolve` retains explicit model choices; otherwise it
uses the existing source-language baseline. A qualified override needs the
internal enable flag, a single matching entry, a supported language in the
existing 26-language set, actual device match and an audited evidence SHA256
reference. The shipped override table is empty. A SHA reference alone is not
proof; only release code loading previously reviewed gate output may populate
that table. Historical persisted choices are treated as explicit. Source-language
recommendations use automatic routing; choosing a model explicitly retains that
choice across launches.

Use `SpeechRecognitionProfile.candidate(language:mode:runtimeID:)` to construct a
benchmark-only Parakeet, GigaAM or Whisper candidate. Unsupported language/model
combinations throw; `canary` remains unavailable through the normal profile
resolver. The diagnostic runner uses CanaryQualificationRuntime for explicit
sequential clips of at most 15 seconds. The separate experimental tool uses
CanaryTranscriber to feed long audio through the same runtime in bounded windows.
`SpeechSession(profile:,
memoryLimit:)` uses the profile's model and independent lane setting; its start,
warm-up and offline replay use the profile's language and mode. Existing callers
using the original initializer retain their existing behavior.

A host can serialize `SpeechSession.qualificationSnapshot()` or subscribe to
`onQualificationTelemetry`. Snapshots use monotonic time and include independent input scheduling lag, first draft,
draft update count/max gap, stop-to-final duration, audio/correction queue depth
and observed peaks, correction failures, and whole-process physical footprint.
The footprint peak is sampled only when snapshots are requested/emitted; it is
not the absolute peak and does not replace a sustained device sampler. Callback
consumers must retain raw observations and compute the required p95 metrics via
Omni Bench. Correction failures are distinct from a successful final result.
AppModel retains the latest telemetry only when its internal qualification flag
is enabled; full evidence export remains the benchmark host's responsibility.

## Explicit iPhone diagnostic runner

Launch the debug app with `--quality-qualification-probe` after copying
`quality-qualification-request.json` into its Documents directory. A text-only
smoke request needs no speech models or microphone permission:

```json
{
  "schemaVersion": 1,
  "runID": "baseline-text-smoke-1",
  "repetitions": 3,
  "samples": [
    {"id": "en-de-1", "source": "en", "target": "de", "scenario": "text",
     "text": "I will send the documents tomorrow.\n\nCan we meet at three?"}
  ]
}
```

Use a fresh runID: the runner refuses to overwrite existing studies. OPUS models
must already be installed; no translation download or fallback occurs. Requests
are limited to the existing 26-language catalog. A sample supplies exactly one
of `text` and `fixturePath`; fixture paths are relative to Documents, and escaping
paths or symlinks are rejected. `pages` fixtures decode a production
PageTranslationRequest; inline text creates one page group. `dictation` fixtures
must be mono 16 kHz audio. Set `allowASRPreparation:true` explicitly for speech:
ASR preparation can download missing assets through the normal app loader and is
reported as preparation time, not pure model loading. Optional `speechRuntimeID`
selects a candidate; optional `speechMode` defaults to hybrid. `speechPipeline`
defaults to `concurrent`: the production TranslationSession receives ordered
caption snapshots during replay and finalizes with finishUtterances. Required
Mozilla preview packs (when that route exists) and OPUS packs must already be
installed; preflight fails before translation preparation if any is absent.
Use `speechPipeline:"sequential"` for the separate ASR-then-OPUS control.
For Canary set speechRuntimeID="canary", speechPipeline="sequential", and
speechModelsDirectory to the staged Documents-relative model directory. Canary
rejects clips over 15 seconds and concurrent mode; it makes no streaming claim. No automatic app profile or user setting is changed.

Results appear under `Documents/quality-qualification/<runID>/`. The runner
persists the request hash, device/OS/app versions, full translation profile,
input hashes, actual per-leg model IDs/loading times and outputs. Each attempt
gets an atomic `started` record before work and a final success/error record.
An interrupted process leaves an identifiable incomplete attempt. A separate
JSONL stream records requested 100 ms footprint samples, thermal state, memory
warnings and speech telemetry; writes are synchronized approximately every second.
`quality-qualification-status.json` is the latest overall status.

`model_load_seconds` sums actual lookup/loading intervals per executed leg.
`final_seconds` includes loading and translation; dictation additionally includes
ASR finalization after paced file input ends and pending production translation
work. Concurrent-session load intervals are not exposed individually: its rows
omit model_load_seconds and retain separately labeled preparation and warmup
(load plus punctuation inference) timings. Speech is explicitly **fixed-rate file
replay, not a microphone latency measurement**. Fresh service ownership per
attempt makes model loading visible; OS filesystem caches may remain warm.

Optional `stressDurationSeconds` must be 1800–7200 and repeats whole workloads
until that duration is reached. Repeating short fixtures is not a continuous
stress test. Supply one ≥1800-second speech fixture with concurrent mode to
exercise sustained ASR/MT competition; retain actual audio duration and raw queue
observations. Even that remains file replay and cannot establish microphone
capture backlog behavior. These outputs are tagged `exploratory_device_observations` and
`not_qualified`. They must be matched, scored, reviewed and supplemented with the
full protocol before the external release gate can pass.


### Fixed-rate producer, imported candidates and retained baselines

The runner now uses `replayRealtimeForQualification`, not `transcribeOffline`.
A detached producer schedules each 1536-frame chunk against the original
monotonic 16 kHz timeline independently of inference. Slow consumers accumulate
observable pending audio chunks. Finalization starts at actual producer input
completion, before backlog drain. Maximum source-scheduler lag is retained; OS
scheduling lateness must not be mistaken for an inference speedup. Cancellation
stops the producer, finishes the stream and invalidates engine jobs. The original
throughput-paced replay API remains unchanged and is not fixed-rate evidence.

Optional per-sample `translationModelsRoot` (Documents-relative) and
`translationBindings` (an array of Codable TranslationModelBinding values) create
an explicit diagnostic-only `candidate-unqualified` catalog. Each declared modelID
must exactly equal TranslationModelIdentity.compute for its installed directory;
no qualified-profile flag or app default is changed. The declared bindings must
resolve the requested direction. Missing/mismatched packages fail rather than
download or fall back. Concurrent previews still use installed baseline Mozilla
packs when that route exists.

A staged Canary candidate uses FluidInference/canary-1b-v2-coreml revision
75c1b536fe7ca6b589d2395ed9a43169d71f543b, verified against the local CanaryProbe
snapshot metadata. The runner records it as an expected revision, not a computed
proof of arbitrary staged bytes. Source and model artifact manifests remain
required for release evidence.

When bundled, QualityQualificationBuild.json is copied into each run as
build-source.json and its source_sha256 is embedded in the run manifest. Missing
build provenance is explicitly unavailable; the run remains unqualified.

A direction may declare quality_decision=retained_baseline instead of claiming
improvement. Such entries require baseline_profile and selected_profile artifact
references with the **same SHA256** of the complete pipeline profile (model,
decoding, ASR, segmentation and device settings). Both files are verified. A
changed profile cannot use this exemption. Retaining identical baseline settings
does not require new improvement evidence; replacing them still requires every
quality, device, review and stress check above.

### Linked quality evidence (gate schema 2)

Hashes alone do not establish that a result completed. For each changed direction,
`quality_results` has `baseline` and `candidate`, each with `mt` and `asr` objects:

```json
{
  "quality_results": {
    "baseline": {
      "mt": {"result": {"path": "baseline-mt/result.json", "sha256": "..."},
             "run": {"path": "baseline-mt/run-artifact.jsonl", "sha256": "..."}},
      "asr": {"result": {"path": "baseline-asr/result.json", "sha256": "..."},
              "run": {"path": "baseline-asr/run-artifact.jsonl", "sha256": "..."}}
    },
    "candidate": {"mt": {"result": {}, "run": {}}, "asr": {"result": {}, "run": {}}}
  }
}
```

This is a structural illustration, not eligible evidence. Replace every reference
with an actual artifact and digest. The two pinned arm manifests must each include
`source_artifact_sha256` matching the envelope's `source` reference, and
`expectations[direction][mt|asr]`. Each expectation contains the complete stock
Omni `identity`, `identity_key`, `definition_ref`, `registry_ref`, and the complete
ordered `sample_ids` from the pinned heldout preparation manifest. Record these
before reviewing results; do not derive expectations from whichever result is
being submitted. Model identities contain the exact model/configuration provenance
hash, including decoding settings. An Omni model identity hash is not necessarily
the raw-byte digest of a pretty-printed provenance JSON file.

The verifier checks Result 0.6 completion, zero errors, full expected counts,
linked run digest, header identity, footer completion and unique successful sample
IDs. Both arms must use identical definition, dataset, protocol and sample IDs.
IDs must belong to the envelope's heldout IDs and never its selection IDs. The
pinned expected sample list must contain the full available FLORES devtest for MT.
Schema 2 enforces exactly 1,012 MT samples and a devtest definition token, even if
a smaller pinned manifest declares itself complete. There is no CLI or environment
override; a different corpus requires a reviewed gate/schema change. Unit tests
patch the count internally for small synthetic fixtures and separately verify
that the production count rejects a complete 100-row subset. For ASR, prepare an error-free Omni result covering the pinned
speech corpus, including the required strata; do not use a translation result as
ASR evidence.

MT observations must have measured scalar `quality.translation_chrf_pp.v1` and
`quality.translation_bleu.v1`; ASR uses `quality.wer_norm.v1` and `quality.cer.v1`.
Each quality observation must cover every expected sample. Envelope values must
exactly match these observations. Timing populations may exclude warmup, and
unavailable unrelated metrics (such as accelerator memory on CPU) are allowed.
Mac quality results are allowed; the separate physical-device budget requirements
remain unchanged. Metrics are read, never recalculated here.

`human_review` is a completed JSON packet using `make-review-packet.py` fields:
`direction`, `status: "completed"`, `completed_reviews`, and `rows`. Preserve all
original source/reference/A/B text. At least 100 unique heldout `sample_id` and
`review_id` rows must include `overall_preference` (`A`, `B`, `tie`, `uncertain`),
nonempty `reviewer_name` and `reviewed_at`, and yes/no/uncertain annotations for
both sides' negation, numbers, names, omission and meaning errors. Empty review
packets fail. `review_assignment_key` references the separately stored assignment
JSON; its direction and both identities must match the linked MT runs. Each A/B
text is checked against that run's output for the row's sample. Keep the assignment
key hidden from reviewers until completion. Human reviewer authenticity and the
acceptance decision still require trusted release review; the verifier does not
pretend to establish either automatically.

The retained-baseline branch still requires equal hashed complete pipeline profile
artifacts, and does not fabricate improvement evidence. Schema-1 envelopes are
rejected. Unit tests intentionally construct synthetic stock-shaped records; they
are not measured qualification evidence and must never be submitted for release.
