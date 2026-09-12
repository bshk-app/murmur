# First20 OPUS qualification coverage

The initial8 non-English comparisons are only part of the20-direction study. The follow-on contains12 directions:11 distinct-model comparisons plus FR→FI baseline-only tuning. Across all20 directions,19 candidate selections require18 unique checkpoints because EN↔DE shares gmw-gmw weights. Every direction keeps its current baseline until independent quality, native/iPhone and human gates pass.

| Direction | Current baseline | First distinct candidate | Queue |
|---|---|---|---|
| de-en | opus-mt-de-en | opus-mt-tc-big-gmw-gmw | follow-on |
| de-fi | opus-mt-de-en → opus-mt-tc-big-en-fi | opus-mt-de-fi | initial-eight |
| de-fr | opus-mt-de-en → opus-mt-tc-big-en-fr | opus-mt-de-fr | initial-eight |
| de-ru | opus-mt-de-en → opus-mt-tc-big-en-zle | opus-mt-tc-big-de-zle | initial-eight |
| en-de | opus-mt-en-de | opus-mt-tc-big-gmw-gmw | follow-on |
| en-fi | opus-mt-tc-big-en-fi | opus-mt-en-fi | follow-on |
| en-fr | opus-mt-tc-big-en-fr | opus-mt-en-fr | follow-on |
| en-ru | opus-mt-tc-big-en-zle | opus-mt-en-ru | follow-on |
| fi-de | opus-mt-tc-big-fi-en → opus-mt-en-de | opus-mt-fi-de | initial-eight |
| fi-en | opus-mt-tc-big-fi-en | opus-mt-fi-en | follow-on |
| fi-fr | opus-mt-tc-big-fi-en → opus-mt-tc-big-en-fr | opus-mt-fi-fr | follow-on |
| fi-ru | opus-mt-tc-big-fi-zle | opus-mt-fi-ru | follow-on |
| fr-de | opus-mt-tc-big-fr-en → opus-mt-en-de | opus-mt-fr-de | initial-eight |
| fr-en | opus-mt-tc-big-fr-en | opus-mt-fr-en | follow-on |
| fr-fi | opus-mt-tc-big-fr-en → opus-mt-tc-big-en-fi | No non-Bible direct; baseline tuning only | follow-on |
| fr-ru | opus-mt-tc-big-fr-en → opus-mt-tc-big-en-zle | opus-mt-tc-big-fr-zle | initial-eight |
| ru-de | opus-mt-tc-big-zle-en → opus-mt-en-de | opus-mt-tc-big-zle-de | initial-eight |
| ru-en | opus-mt-tc-big-zle-en | opus-mt-ru-en | follow-on |
| ru-fi | opus-mt-tc-big-zle-fi | opus-mt-ru-fi | follow-on |
| ru-fr | opus-mt-tc-big-zle-en → opus-mt-tc-big-en-fr | opus-mt-tc-big-zle-fr | initial-eight |

The full JSON records all audited non-Bible standard/group/tc-big alternatives and explicit deferrals. Existing tc-big baselines use an ordinary bilingual control where no distinct stronger targeted tc-big exists; this is a comparison, not an assertion that smaller is better. EN↔DE uses the verified2022 gmw-gmw checkpoint and exact >>deu<</>>eng<< labels, not a nonexistent tc-big-en-de model.

Run first20-coverage.mjs to refresh actual coverage in the study data directory. Separate dev tuning, full heldout, float controls, human review and native cap-guard requalification remain visible; full baseline coverage alone does not complete this study. Python legacy capped-output behavior differs from the current native error guard, so no Python-only result authorizes promotion.
