# OPUS and ASR quality integration

Development checkout: `/Volumes/DATA/Murmur-opus-quality`, branch
`feat/opus-quality`. Commit `042346c8` records the inherited application/engine
source state, so changes after it isolate this integration from the pre-existing
engine extraction. Historical measurements referring to `c99ed6b` retain that
original snapshot under a backup ref; the integration snapshot excludes the
worktree-only `.claude` symlink.

## Implemented behavior

- One deterministic translation profile supplies preparation, execution and
  offline availability. Existing 52 direction bindings identify 44 distinct
  weight/tokenizer assets. Installed unqualified directories cannot silently
  change a selected route.
- Model identity covers weights, configuration, tokenizers and vocabularies.
  The engine verifies it before loading, retains verification metadata while
  files are unchanged, and shares a loaded group model across target tags.
- Configurable native decoding preserves the old ABI/defaults and supports
  beam 1/4/6/8, length penalty, source/output limits and INT8/FLOAT32 execution.
  FLOAT32 execution of INT8 weights is not an unquantized quality control.
- Shared model files can use verified hard links. Package replacement keeps
  the previous installation until atomic publication succeeds.
- A separate asset registry supplies downloads for newly qualified checkpoints:
  immutable HTTPS revisions, pinned file hashes and content-derived directories.
  Direction bindings retain separate language tags while shared weights download
  once. The additional-asset rollout table is intentionally empty pending evidence.
- Text/page framing, line endings and list markers survive translation.
  Confirmed dictation revisions invalidate stale translations. Strict quality
  calls report missing, corrupt, empty or decoder-capped model results without
  a preview fallback. Historic Python study results retain the old cap behavior
  and require native requalification before a changed profile is enabled.
- ASR profiles separate automatic recommendations from explicit selections.
  Qualified overrides are disabled. Canary is available separately in Settings
  → Tools → Test speech translation, with recording and file import through bounded,
  nonoverlapping windows. No production Canary default is claimed. See
  [CANARY-BATCHING.md](CANARY-BATCHING.md) for behavior and execution checks.
  The shipped user-facing setting uses neutral route names, is disabled by
  default, and applies direct translation only to the verified English↔X matrix.
- A debug device runner records real model outputs, source/profile provenance,
  process footprint, queue depths, input scheduling lag and finalization time.
  Fixed-rate replay has an independent producer, so slow inference cannot hide
  input backlog by slowing playback.

## Qualification, not automatic promotion

The inventory covers 1,550 upstream OPUS repositories and all 650 requested
directions. Only 498 directions have non-Bible direct candidates. In the first
twenty directions, FR→FI has only Bible-domain direct candidates in this audit.
That is availability evidence, not evidence that those models improve dictation.

Actual scoring uses the stock Omni Bench preparation/producer/scorer path.
Settings are selected on FLORES dev; full 1,012-row devtest runs are separate.
The source state, artifacts, native controls, normalization and original/HF
licenses are retained. CPU runs share the Mac: their timing is exploratory;
the iPhone budgets require device observations.

The first complete DE→FI comparison illustrates the selection rule:

| Pipeline | Full devtest chrF++ | BLEU |
| --- | ---: | ---: |
| Existing pivot, beam 1 | 50.872 | 20.153 |
| Same pivot, beam 6 | 51.674 | 21.073 |
| Direct OPUS, normalized input, beam 6 | 48.651 | 17.757 |

Each row has 1,012 successful samples. The direct candidate does not justify a
quality replacement. Beam 6 is a candidate improvement, not a qualified default.

The completed FI→DE and DE→FR direct comparisons also score below their
existing routes: chrF++ 47.434 versus 50.371 and 57.932 versus 59.262,
respectively, each on all 1,012 devtest rows. This does not rule out other
checkpoints. The broader candidate queue needs recovery: source conversion hit
the 3 GiB free-space guard, and the detached supervisor later exited on an
unhandled process-group permission error. Its old status file is not live proof.

Release evidence schema 2 verifies the linked Omni Results and run artifacts,
their counts and identities, measured observations, device budgets, and completed
blinded review rows. Artifact hashes and declarations alone are insufficient.
Unchanged profiles may retain baseline with identical verified profile artifacts.
No real passing release bundle or qualified default has been manufactured.

## Verification and remaining evidence

Core and translation package regressions pass, including real native group-tag
alternation using one loaded model. All 46 existing European conversions passed
native loading, translation and a Maltese→Irish session check. Both Debug and
Release iOS builds pass for source fingerprint
`e5911a1be4e04c1cde611793bc43016885fbb975479e90ddcee914d16bee26d5`.
An earlier debug build installed on iPhone 15 Pro and ran the smoke below;
the latest build still needs device execution.

The latest Core regression contains 132 passing tests; Translation reports 91
tests with four fixture skips and no failures. The qualification tool suite has
26 passing tests. Corruption/repair, shared ownership across scenarios and
identity-cache invalidation are covered. Commits use the configured Git signer.

The first device smoke completed 15 text/page attempts with preserved structure
and zero observed memory warnings. It is a small execution check, not a quality,
p95 or endurance qualification. Fresh ASR/device runs require the phone unlocked.

On September 12, iPhone 15 Pro completed three short baseline ASR→OPUS repeats
for each of RU/EN/FI/DE/FR and three Canary→OPUS repeats per language. Baseline
startup runs produced memory warnings; Canary's sampled peak was about 2.41 GB
with no warnings in those short runs. Results differ in quality and do not
justify automatic replacement. French initially lacked its preview package;
explicit setup repaired preparation before a fresh three-repeat run passed.

The combined endurance replay was stopped at the user's request after about
16 minutes, with a sampled peak about 2.83 GB, three memory warnings and serious
thermal state. It did not complete 30 minutes. The app was terminated and device
testing is stopped. [Raw device results and limitations](/Volumes/DATA/Murmur-models/opus-quality/device/iphone15pro-20260912/RESULTS.md)
record the incomplete run separately from successful short attempts.

The Debug diagnostic screen now stays awake between runs and has an explicit
preview-package setup command; measured runs still refuse missing packages.
Latest installed Debug source fingerprint:
`ba63380cc4a13466d4429a022c4266f635eb2ddb24abeb19344241b992b0d5f0`.

The baseline covers all twenty directions × 1,012 rows (20,240 heldout samples).
The legacy producer reports completion, but nine outputs reached its decoder
limit (seven FR→DE and two RU→DE) and require the new native guard to be
requalified. Candidate comparisons remain incomplete. Human review,
matched speech strata, device comparisons and continuous endurance evidence are
required before enabling changed profiles. Sentence assembly ablations are
source-preserving experimental inputs, not a changed live segmentation default.

## Reproduce and inspect

```sh
swift test --package-path Engine/Core
swift test --package-path Engine/Translation
node Engine/Translation/Scripts/generate-quality-baseline.mjs --check
node Engine/Translation/Qualification/validate-audit.mjs
python3 -m unittest discover -s Engine/Speech/Qualification -p 'test_*.py'
```

For a device evidence build, run
`node Engine/Speech/Qualification/capture-build-source.mjs` before generating the
Xcode project. Preserve `Applications/iOS/Package.resolved` in the generated
workspace and use `-onlyUsePackageVersionsFromResolvedFile`.

- [Live text-study progress](/Volumes/DATA/Murmur-models/opus-quality/runs/first20-v2/PROGRESS.md)
- [Native European regression](/Volumes/DATA/Murmur-models/opus-quality/native-eu-regression.json)
- [First device smoke](/Volumes/DATA/Murmur-models/opus-quality/device/profile-smoke-20260911-1/manifest.json)
- [Blinded DE→FI review packet](/Volumes/DATA/Murmur-models/opus-quality/review/first20-v2/de-fi-tuned-baseline-beam6/packet.csv)
- [Qualification protocol](OPUS-ASR-QUALIFICATION.md)

Large artifacts stay on DATA. Nothing has been uploaded or published.
