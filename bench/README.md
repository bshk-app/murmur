# Benchmarking Murmur with omni-bench

The adapter lives here rather than in omni-bench: the benchmark must not know
about the app. It wraps `murmur-cli`, so what gets scored is the code the
menu-bar app runs, not a reimplementation.

## What it measures, and what it does not

Quality only. `run-fleurs-ru.sh` uses `audio_transcription.batch_single.v1` with
`delivery: batch`, which hands the host a whole prepared file — the chunking the
`--mode` lanes do internally is the engine's business, not producer-paced
delivery. Declaring it as streaming would claim streaming-integrity evidence
this path cannot produce.

For load and speed use `autoresearch/load-compare.sh` instead. It reports
joules per second of audio, which is the figure that ranks engines when the
question is "fast enough for speech, at what cost".

## Setup

omni-bench and the adapter must be importable from the *same* interpreter:

```bash
git -C <omni-bench> worktree add --detach /tmp/ob v0.6.4
cd /tmp/ob/python && uv venv && uv pip install -e .

cd <murmur>/MurmurKit && swift build -c release --product murmur-cli
```

## Running

```bash
bench/run-fleurs-ru.sh /tmp/ob ~/murmur-bench            # quick Task, 64 samples
bench/run-fleurs-ru.sh /tmp/ob ~/murmur-bench asr.fleurs.ru.v1
bench/run-fleurs-ru.sh /tmp/ob ~/murmur-bench asr.fleurs.ru.quick.v1 accurate
```

It prepares the Task if needed, runs each engine, scores it, and prints WER and
CER per engine. A failing engine is reported and the rest continue.

## Engines

| factory | lanes | placement |
|---|---|---|
| `fast` | Nemotron 0.6B 8bit | MLX |
| `accurate` | Voxtral 4B 4bit | MLX |
| `hybrid` | both | MLX |
| `parakeet_mlx` | Parakeet TDT 0.6B v3 | MLX |
| `parakeet_ane` | Parakeet TDT 0.6B v3 | Conformer on ANE, decode in MLX |

`hybrid` is not in the default set. `TwoTierSession.finish()` returns the
accurate lane's text verbatim unless the overload valve shed mid-utterance, so
on offline files it produces the same transcript — and the same WER — as
`accurate`. Ask for it by name when valve behaviour is the thing under test.

## Result: asr.fleurs.ru.quick.v1

64 samples, 12.4 min of audio, 1204 reference words. M1 Max, macOS 26.2,
mlx-audio-swift `6768a6d`. 64/64 scored for every engine, no sample errors.

| engine | WER_norm | CER | word errors |
|---|---|---|---|
| `parakeet_mlx` | 10.88 % | 5.60 % | ~131 |
| `accurate` (Voxtral 4B) | 11.05 % | 5.73 % | ~133 |
| `parakeet_ane` | 11.46 % | 6.30 % | ~138 |
| `fast` (Nemotron 0.6B) | 18.27 % | 9.07 % | ~220 |

**The top three tie.** They sit within 7 word errors of each other out of 1204,
under one standard deviation even before accounting for the fact that ASR errors
cluster per utterance rather than falling independently. Read this as "Parakeet
0.6B matches Voxtral 4B on this task", not as a ranking among them.

That is the decision: `autoresearch/load-compare.sh` measures Voxtral at RTF 2.09
and 7.28 J per second of audio against Parakeet-ANE's 0.0153 and 0.07 — roughly
137x the time and 104x the energy for quality this run cannot distinguish.

`fast` is the one real gap: 220 errors against 131. The two-tier design assumed
exactly that, so it holds — but it is an argument for replacing the accurate
lane, not for keeping two.

## Identity

`model` and `backend` are closed objects in the 0.6 schema
(`additionalProperties: false`), so everything that shaped a run has to fit the
fields that exist: model repos in `base_model_id`, compute placement in
`backend.id`, and the pinned mlx-audio-swift revision plus the fast-lane chunk
size in `backend.version`. Without that last part two runs with different chunk
sizes would pool as one configuration.

`language` is accepted and not forwarded — none of these engines takes a
language on the offline path. That is a no-op for the monolingual FLEURS Russian
Tasks and would matter for a mixed-language one.
