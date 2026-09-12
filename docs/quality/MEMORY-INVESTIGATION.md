# Memory investigation — 2026-09-12

## Finding and fix

The SHA-256 model verifier read 1 MiB chunks through Foundation `FileHandle`,
but temporary read buffers survived across iterations. Checking the existing
RU→EN OPUS asset in a fresh process reached **262.4 MB** of process footprint,
without loading speech or translation engines. An autorelease pool around the
whole hash operation did not reduce its peak.

Bounding the buffer lifetime with an autorelease pool **inside each read
iteration** reduced that check to **10.5 MB**. The complete model identity stayed
`opus-d7c2126955c676c4537ea6678d2daad52d48cc896817ac62637ff6bbea0f92ef`.
The same correction is applied to the matching-file scan used for shared assets.
Hash verification, cancellation and corrupt-package checks remain enabled.

## Controlled Mac measurements

Host: Apple M1 Max, 32 GiB RAM. Debug CLI using the production phone speech and
translation classes. Each full case is a fresh process with three real-time
replays of the same 11.52-second Russian recording. Model preparation is separate
from replay compute time. The initial pilot, which included warm-up/setup, is
excluded from the before/after comparison.

| Case | Peak process footprint |
| --- | ---: |
| Before, process 1 | 1,698 MB |
| Before, process 2 | 1,710 MB |
| MLX cache capped at 64 MiB | 1,711 MB |
| Bounded hash buffers, process 1 | 1,473 MB |
| Bounded hash buffers, process 2 | 1,483 MB |
| Final source, including shared-file verifier fix | 1,472 MB |

The full-process peak reduction is about **230 MB / 14% on this Mac**. All 18
full-pipeline replay outputs across these cases have identical transcripts and
translations, with no translation errors. Warm replay compute medians were
approximately 5.4–5.6 seconds for 11.52 seconds of audio; this small diagnostic
does not establish an iPhone latency budget.

The gain concerns preparation/high-water memory. After several replays, both
versions settle near 1.3 GB on this Mac. It does not eliminate the ongoing
resident cost of simultaneous models.

## What accounts for memory

- Nemotron plus Silero holds about **799 MB of active MLX tensors after load**.
  The cached Nemotron checkpoint contains 755,471,936 bytes of tensors: about
  555 MB in packed U32 storage and 200 MB in BF16 storage. Its 8-bit setting does
  not make every tensor 8-bit; large pointwise convolution weights remain BF16.
- Replay MLX cache peaks were around **20 MB**, generally returning near zero
  because the stream already clears it every step. The 64 MiB cache control did
  not improve the full-process peak. Production cache policy was not changed.
- After the hash fix, observed preparation deltas were roughly **180–220 MB**
  for the preview translator/preparation and another **380–390 MB** for OPUS
  warm-up. These are phase deltas, not an allocator-level breakdown of each
  engine's weights versus workspaces.
- Removing Nemotron lowered the old-process peak to about **890 MB**; removing
  GigaAM left it near **1,704 MB** on this Mac. The latter must not be interpreted
  as GigaAM having no memory cost on iPhone: Core ML preparation and memory
  accounting did not reproduce the handset footprint here.
- The configured GigaAM encoder uses INT8 weights reconstructed to FP16 and a
  fixed `[1,64,3000]` input (30 seconds). The generic `quantization: "int4"`
  argument selects Parakeet's variant; it does not quantize this GigaAM export or
  change the fixed 8-bit Nemotron checkpoint.

## Validation and limits

Core: 132 tests passed. Translation: 92 tests, four fixture skips, no failures.
The new identity regression covers complete read chunks plus a final partial
chunk with a fixed independently calculated digest. The iOS Debug build passed
with source fingerprint
`718e2f35a5050ffebecc2ee9b262dbce44d15f5e7bd02231cf3488f4468b8ae4`.
It was **not installed or tested on the iPhone**; device testing remains stopped.

The handset's prior 2.77–2.83 GB footprint cannot be precisely decomposed by
subtracting these Mac numbers. A future brief handset check should capture
process memory and MLX active/cache counters at each load boundary. Then evaluate
smaller GigaAM input shapes and alternative Nemotron quantization with transcript,
preview and final-translation parity checks. Neither model change is made here.

Raw cases, output-parity checks, SHA-256 records and the patch are in
`/Volumes/DATA/Murmur-models/opus-quality/memory-investigation/`.

## Reproduce

Build `murmur-cli` from this checkout with its resolved dependencies. Provide a
model root containing the pinned `ct2-ruen` asset; the normal downloader prepares
the preview package when absent. Run each case in a fresh process:

```sh
murmur-cli --memory-probe --wav /path/to/ru_ru_01.wav \
  --models-root /path/to/models --json-out /path/to/result.json
```

Controls: `--cache-mb 64`, `--probe-mode accurate` (without Nemotron),
`--probe-mode fast` (without GigaAM), and `--hash-only` (identity check only).
`--pool-hash` records the whole-operation pool control. The saved patch describes
the pre-fix implementation; pre-fix JSON results must not be relabeled as runs
of the corrected binary.
