# OPUS candidate metadata audit

Inspected 1550 repositories across 16 HF API pages, following every next link. 409 checkpoints have source and target membership evidence for the application's 26 languages. The matrix has 650 directions; 498 have a non-Bible candidate. Bible-domain candidates are recorded for completeness, not recommended for general dictation.

## First 20 directions

| Direction | Baseline | Non-Bible direct candidates | Bible candidates |
|---|---|---|---|
| de → en | de-en | 10 | 13 |
| de → fi | de-en → tc-big-en-fi | 1 | 4 |
| de → fr | de-en → tc-big-en-fr | 2 | 11 |
| de → ru | de-en → tc-big-en-zle | 2 | 4 |
| en → de | en-de | 10 | 12 |
| en → fi | tc-big-en-fi | 6 | 4 |
| en → fr | tc-big-en-fr | 8 | 11 |
| en → ru | tc-big-en-zle | 7 | 4 |
| fi → de | tc-big-fi-en → en-de | 1 | 6 |
| fi → en | tc-big-fi-en | 6 | 7 |
| fi → fr | tc-big-fi-en → tc-big-en-fr | 1 | 6 |
| fi → ru | tc-big-fi-zle | 2 | 1 |
| fr → de | tc-big-fr-en → en-de | 2 | 12 |
| fr → en | tc-big-fr-en | 8 | 13 |
| fr → fi | tc-big-fr-en → tc-big-en-fi | 0 | 4 |
| fr → ru | tc-big-fr-en → tc-big-en-zle | 3 | 4 |
| ru → de | tc-big-zle-en → en-de | 2 | 6 |
| ru → en | tc-big-zle-en | 7 | 7 |
| ru → fi | tc-big-zle-fi | 2 | 1 |
| ru → fr | tc-big-zle-en → tc-big-en-fr | 4 | 3 |

## Interpretation and reproducibility

Run `node Engine/Translation/Qualification/discover-opus.mjs` for a fresh paginated inventory; use `--cached` to regenerate against the saved inventory and revision-keyed cards. Set OPUS_AUDIT_CACHE to relocate metadata storage. No weights are downloaded. The JSON includes exact source/target card lines, license, revision, archive location, file availability, and target tag evidence. Generic documented `>>id<<` is accepted only with exact target-language membership; language groups are never expanded from checkpoint names.

Baseline routes come from the existing EU catalog and six RU/EN/FI tc-big conversions. HF revisions in this audit pin inspected metadata, not the previously converted application weights; those remain identified by the shipped SHA-256 digests. Conversion availability is a file/card preflight, and conversion status remains not-tested. Quality, latency, INT8 parity, device resource use and human review are not measured by discovery. No candidates are selected or promoted. FR→FI has only Bible-domain direct candidates in this inventory; pivot must remain until comparative qualification.

## Benchmark integration references

Omni Bench skill: /Volumes/DATA/omni-bench/.claude/skills/omni-bench/SKILL.md (also .agents/skills/omni-bench/SKILL.md). Hosts own inference; Omni Bench owns scoring and artifacts. Use its prepare → run → score → diff pipeline and record model revision, backend, hardware and decode parameters. Never reimplement BLEU/chrF or WER/CER inside this discovery script.

## Actual text runs

`run-text-study.py` uses the installed Omni Bench 0.6.0 preparation runtime, producer and translation scorer. FLORES+ is pinned to `b3a5298db5721c8a682e7ef00a37fcc9ab522757`; `dev` is exclusively for tuning and `devtest` always loads the complete heldout split with stock file verification. The local registry/content descriptor pins all selected prompts and references. The inference host receives only prompts. Existing package bytes and decoding choices are hashed in provenance.

`run-first20.py --phase baseline-dev` executes 20 directions serially on 100 dev sentences each. `--phase tuning` executes baseline INT8 beams 4/8; `--phase baseline-heldout` runs baseline beam1 on full devtest. None of these commands selects or promotes a profile. Use a distinct study ID for altered code/settings. Candidate packages can be passed to `run-text-study.py --model-dir …`; float32 requires an independently converted original-weight package, rather than float execution of quantized weights. Results stay under `/Volumes/DATA/Murmur-models/opus-quality/runs`.

`prepare-candidate.py` records revision-pinned checkpoint controls and converts original archives (or an explicit existing source directory) to INT8/float32. Original archive bytes get a separate SHA-256 because an HF revision does not pin an external archive. Preparation requires 4 GiB free at entry and guards a 2 GiB reserve. Model conversion, beam sweeps, complete heldout comparisons, checkpoint-default decoding parity and iPhone qualification remain separate requirements; runner availability is not evidence that those experiments passed.
