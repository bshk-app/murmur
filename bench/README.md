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

| engine | seam | WER_norm | CER |
|---|---|---|---|
| `parakeet_int8` | batch | **10.88 %** | 5.51 % |
| `parakeet_mlx` | batch | 10.88 % | 5.60 % |
| `accurate` (Voxtral 4B) | batch | 11.05 % | 5.73 % |
| `parakeet_ane` | batch | 11.46 % | 6.30 % |
| `parakeet_int8_stream` | streaming | 14.29 % | 8.42 % |
| `parakeet_mlx_stream` | streaming | 14.70 % | 8.62 % |
| `fast` (Nemotron 0.6B) | batch | 18.27 % | 9.07 % |
| `fast_stream` | streaming | 18.27 % | 9.07 % |

Streaming runs are paced at 480 ms; all three held real time (`audio_rtfx_wall`
0.986–0.994) and drained every chunk (`chunk_completion_rate` 1.0).

**int8 quantization is free.** Same WER as the full-precision MLX encoder and a
slightly better CER, on a smaller model. It is the Parakeet build to use.

**The rolling window costs 3.4 points.** 10.88 % batch against 14.29 % streaming
is the price of re-decoding a 9.5 s window every second instead of carrying
state. Nemotron pays nothing — `fast` and `fast_stream` are identical to the
digit, because it is natively cache-aware, which also serves as a check that the
two seams feed the engine the same audio.

**Latency does not separate them.** First partial p50 is ~2.0 s for every engine.
The distributions differ, though: Parakeet answers only on even chunks (53 of 64
on chunk 4, then 6, then 8) because its window updates once a second, while
Nemotron is spread from chunk 3 to chunk 9. Parakeet is the more predictable of
the two, and no slower to first text.

**The top three tie.** They sit within 7 word errors of each other out of 1204,
under one standard deviation even before accounting for the fact that ASR errors
cluster per utterance rather than falling independently. Read this as "Parakeet
0.6B matches Voxtral 4B on this task", not as a ranking among them.

That is the decision: `autoresearch/load-compare.sh` measures Voxtral at RTF 2.09
and 7.28 J per second of audio against Parakeet-ANE's 0.0153 and 0.07 — roughly
137x the time and 104x the energy for quality this run cannot distinguish.

`fast` is the one real gap: 18.27 % against 10.88 %. The two-tier design assumed
exactly that, so it holds — but it is an argument for replacing the accurate
lane, not for keeping two.

### What this suggests: one model, two passes

Two lanes exist because the accurate lane could not keep up, so a weaker model
had to cover the wait. Nothing has to cover a wait that is gone.

| | live text | final text |
|---|---|---|
| today | Nemotron, 18.27 % | Voxtral, 11.05 % |
| one model | Parakeet int8 streaming, 14.29 % | Parakeet int8 batch, **10.88 %** |

The second pass is affordable precisely because the model is fast: re-decoding a
whole 10 s utterance at RTF 0.015 costs ~0.15 s, and measured finalization is
already 0.12 s. So the same model gives better partials *and* a better final,
from one set of weights, at a fraction of the energy — and the streaming
penalty stops mattering, because the rolling window never has to produce the
final text.

This is a conclusion from measurements, not a change that has been made. What is
still unmeasured: Parakeet streaming under the ANE encoder (its `fixedFrames`
limit constrains the window), and behaviour on long dictation rather than
FLEURS' ~12 s clips.

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
