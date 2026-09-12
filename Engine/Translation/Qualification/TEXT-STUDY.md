# OPUS text qualification

The study uses the existing `/Volumes/DATA/omni-bench/python/.venv/bin/python` environment and the stock Omni Bench preparation runtime, producer and translation scorer. All large inputs, weights and results are stored in `/Volumes/DATA/Murmur-models/opus-quality`. No model is promoted or published by these tools.

- `run-first20.py --phase baseline-dev`: serial100-sentence FLORES **dev** baseline for20 directions. `tuning` runs baseline beams4/8; `baseline-heldout` runs full1012-sentence **devtest** baseline.
- `run-candidates.py`: sequential preparation and baseline/candidate beams1/4/6/8 on dev100; freeze provisional maximum-chrF beam choices before full devtest runs. Full heldout includes current baseline beam1, tuned baseline and tuned candidate. Device budgets and human review still gate any release. Source/card/config revisions and converted file hashes are recorded.
- `prepare-candidate.py --checkpoint Helsinki-NLP/opus-mt-de-fi --quantization int8`: original OPUS conversion. `float32` produces a genuine control from original weights; float execution of an INT8 pack is rejected as a control. Original `decoder.yml` and HF wrapper generation settings are recorded separately. Exact HF/Marian/CT2 default-decoding parity is **not established** by matching beam width.
- `make-review-packet.py --baseline RUN_DIR --candidate RUN_DIR --output REVIEW_DIR`: requires two complete full-heldout runs on identical pinned content; creates100 deterministic sampled items with source/reference and blinded A/B translations. Assignment key is separate. All human fields are blank and status remains awaiting-human-review.
- `summarize-text-study.py`: copies already-scored Omni observations into a progress report; implements no scoring formulas.

Use `--study-id` to isolate experiments. `first20-v2` is the corrected runner contract: maximum512 output tokens **per segment**, with a16384-token whole-request envelope. The initial `first20-v1` exploratory batch exposed one FR→DE generated-token-envelope error because a multi-sentence result totaled538 tokens. Its incomplete result is retained and is not eligible for selection. Changing the envelope does not truncate or otherwise alter translations.

The runner snapshots its source with each new run and hashes decoding controls with model provenance. Candidate conversion retains INT8 packs for device tests. Only after complete current/tuned/candidate heldout and float controls does `cleanup-study-intermediates.py` use the safe-rm skill's dry-run followed by scoped removal of study-created extracted sources, source archive and float pack; checksums, conversion controls, provenance and results remain. Re-downloads must match the recorded original-archive hash.

Still required for release: full first20 comparisons, sample-stratum checks, bilingual human review, speech-chain qualification, actual iPhone15Pro latency/memory/endurance measurements and explicit approved-profile selection. A high dev100 score is not a release decision.

`setup-normalization-env.sh` uses uv to create a dedicated normalization environment; it reads existing Omni dependencies through a local `.pth` and never installs into the shared Omni environment. The explicit `--normalization sacremoses` candidate runs Unicode punctuation replacement, control-character removal, language-specific punctuation normalization (`perl_parity=True`), and ASCII-space collapse/trim before sentence splitting on each line/leg. Sacremoses0.1.1 source and dependency versions are pinned. This tests the documented OPUS preprocessing stages, but the archive does not pin its historical Moses installation, so exact2020 pipeline parity is not claimed. Raw SentencePiece remains the baseline. The normalization choice is made on dev at the selected raw beam before candidate heldout evaluation.

After the app build, two existing-pack baseline workers (`run-baseline-full.py`) were added alongside the single candidate queue, for at most three inference processes with one CT2 thread each. CPU timings are exploratory under contention; use actual iPhone measurements for resource gates. The runner archives the actual Omni source/schema/registry state, including pre-existing local edits, instead of relying solely on its Git commit.

### Decoding-limit reliability check

The native application shim now rejects a returned hypothesis that reaches its
configured `max_decoding_length` without EOS. CTranslate2 stops either at EOS or
the final allowed decoding step. This shim supplies no target prefix and leaves
`return_end_token=false`; an EOS-completed output therefore has at most cap−1
pieces. A cap-sized output is an unfinished generation, not a successful final
translation. The native call fails explicitly before returning any partial text;
there is no automatic truncation, fallback or second decoding attempt.

Existing Python study results retain their original decoding behavior: capped
outputs were scored and diagnostics flag them where recorded. Those historical
results, counts and metric values are not rewritten by this native reliability
fix. They cannot establish successful final-output behavior for a candidate with
cap failures; requalification must exercise the new native error contract. This
change promotes no model or decoding default.

`first20-coverage.mjs` publishes the complete20-direction plan, standard/group/tc-big shortlists, explicit candidate deferrals and actual stage coverage. The initial8 comparisons do not complete first20. `run-follow-on.py --baseline-only --workers2 --wait-pid BASELINE_POOL_PID` can use the two released baseline slots for full20 baseline beam/normalization tuning; `run-follow-on.py --wait-pid INITIAL_CANDIDATE_PID` performs the remaining12 directions serially (11 distinct candidates, FR→FI baseline tuning only). Both respect per-run locks and preserve complete outputs. All conversions also share a file lock and disk guards. A float32 dev improvement in the follow-on triggers full float heldout before any comparison claim.

The Python study intentionally retains legacy capped hypotheses with diagnostics. The new native shim instead rejects a selected hypothesis at its configured decoding cap. Existing research artifacts are not rewritten; all prospective profiles require native requalification under that guard. Matching Python corpus scores alone cannot authorize an app default.

The one-off `supervise-study.py` process can be detached from the assistant/tool session. It adopts existing process groups, waits for surviving children before resuming, manages the serial candidate lane and two baseline-tuning slots, and refreshes progress plus missing cap-review packets every 30 seconds. Inspect the timestamp and process liveness as well as `/Volumes/DATA/Murmur-models/opus-quality/supervisor-status.json`; a stale file does not prove that work is running. If an adopted group cannot be inspected, the supervisor records `attention-required` instead of launching a possible duplicate. It performs no app default changes or publication; human and native qualification remain separate.
