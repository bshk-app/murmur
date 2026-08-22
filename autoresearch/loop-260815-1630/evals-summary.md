# Pipeline performance loop — 2026-08-15

**Goal** maximum performance · **Metric** hybrid RTF on alex-mac (Apple M1, 16 GB),
min of 3 warm passes, 9.7 s clip, lower is better · **Guard** transcript
word-overlap ≥ 0.90 and zero unit-test errors · **Scope** MurmurKit pipeline
parameters, models out of scope.

**Result: 2.417 → 2.29, about 5 %.** Guard held at overlap 1.000 in all nine
measurements — nothing was traded for speed. Stopped at 8 of 15 iterations: the
parametric search is exhausted, and the reason is structural.

## What happened

| # | change | RTF | verdict |
|---|---|---|---|
| 0 | baseline | 2.417 | — |
| 1 | MLX memory cap scaled to physical RAM | 2.406 | keep (noise; independently correct) |
| 2 | accurate-lane delay 960 → 1440 ms | 2.412 | discard |
| 3 | MLX relaxed buffer cache | 2.403 | discard — see below |
| 4 | Nemotron chunk 160 → 320 ms | **2.282** | **keep, −5.2 %** |
| 5 | Nemotron chunk 480 ms | 4.594 | discard, +101 % |
| 6 | re-confirm 320 ms | 2.314 | keep |
| 7 | Nemotron chunk 240 ms | 3.059 | discard, +32 % |
| 8 | Nemotron chunk 640 ms | 3.570 | discard, hypothesis refuted |

## The one real lever, and why it is small

Only the fast lane's chunk moved the metric. It could not have moved it much:
the fast lane is ~17 % of hybrid cost (0.139 of 0.829 on an M1 Max), so making
it ~30 % cheaper buys ~5 % overall. The other 78 % is Voxtral, and nothing in
scope touched it.

**Its curve is not tunable by reasoning.** Measured: 160 → 2.41, 240 → 3.06,
320 → 2.29, 480 → 4.59, 640 → 3.57. No arithmetic fits. A doubling hypothesis
(160 × 2^k) predicted 640 would be fast; it is 54 % slow. The likely cause is
Metal kernel specialisation — MLX compiles per tensor shape, and some shapes
land on better kernels. **Any future change here must be measured, not derived**,
and 320 is an empirical point, not a principled one.

## Why the other levers were flat

Issue #1 in the Gitea tracker already records it: the bottleneck is the **audio
encoder forward pass**, not token decode. Everything in scope — buffering
window, cache mode, call ordering, memory ceiling — controls *when and how often*
work is scheduled. Encoder cost scales with how much audio there is, and that is
fixed by how long someone spoke. Three iterations turned knobs not connected to
the load.

The same issue rules speculative decoding out of the live path for the same
reason: it accelerates decode, and decode is not the constraint here.

## Iteration 3: kept by the metric, reverted by hand

`relaxed: true` improved RTF and passed both guards. It was reverted anyway: the
hard memory cap exists so an unbounded MLX run cannot OOM-reboot the Mac, and
neither a transcript check nor a unit test can observe "made a rare crash more
likely". A loop following the protocol literally would have shipped it for
0.12 %. Formal guards cover what is measurable; the rest stays with whoever
reads the diff.

## What the guard could not see

The fast-lane chunk is paid for in **partial latency** — how long before words
appear. The transcript is identical either way, so the guard is blind to it, and
optimising on the metric alone would drift toward the largest chunk that still
passes. 320 ms was chosen with that ceiling in mind: partial latency must stay
well under the accurate lane's 960 ms head start, or the two-lane design stops
having a point.

## Open thread worth more than this loop

Issue #1 records the accurate lane at **RTF ~0.32** on 2026-06-23. Measured
**0.647** on an M1 Max on 2026-08-13 — twice as slow. Caveats apply (different
clip, possibly different warm-up method and machine), but if it is a regression
it is worth more than everything found here. Three pipeline commits landed
between those dates: the Silero speech gate, mode switching, and the 160 ms
chunk. The gate adds work on every chunk.

## Where the remaining performance is

Outside the scope set for this loop: model size, quantisation, or a different
architecture for the accurate lane. Within the current models on a base M1,
hybrid stays 2.3× slower than realtime, which is what the chip-tier default and
the overload valve exist to handle.
