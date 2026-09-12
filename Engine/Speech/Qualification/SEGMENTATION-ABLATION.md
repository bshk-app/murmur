# Source segmentation ablation

The diagnostic probe now exports `source_utterances` for speech attempts. IDs are
strings, preserving UInt64 values in JavaScript. Each entry contains the actual
final text and `startSample` / `endSample` at 16 kHz. Streaming arms construct these
from all ordered caption snapshots through production `RecordingTranscript`;
Canary short clips export one whole-clip utterance. This adds diagnostics only:
production segmentation, UI grouping and default model selection are unchanged.

Create source-only comparison inputs from real attempt files:

```sh
uv run --no-project python Engine/Speech/Qualification/segmentation_ablation.py \
  /path/to/attempt-000000.json /path/to/attempt-000001.json > segmentation-inputs.jsonl
uv run --no-project python -m unittest discover -s Engine/Speech/Qualification \
  -p 'test_segmentation_ablation.py' -v
```

Each output contains two arms: `utterance` retains every source fragment as its
own segment; `sentence` merges adjacent fragments until terminal punctuation or
the end of input. The punctuation heuristic supports Unicode terminal marks and
closing quotation marks/brackets; it is not a language-aware sentence parser and
can treat abbreviations ending in a period as boundaries. It never splits a
fragment, rewrites text, or drops trailing incomplete/empty fragments.

`coveredIDs` lists every original ID in order, exactly once across an arm.
`fragments` retains the exact original objects/text. Merging inserts one space
only where neither neighboring fragment already supplies whitespace. This makes
joining explicit and reviewable while preserving every source word and character.
Duplicate/numeric IDs and malformed sample ranges are rejected. Old probe rows
without actual source utterances must be rerun, not reconstructed from guesses.

Run both arms with the same pinned OPUS model and decode settings, using actual
aligned target references and stock Omni Bench producers/scorers. Compare final
reassembled target output on the same sample population, latency, and diagnostic
preservation of numbers, names and negation. The utility does not manufacture
references or scores: it emits `quality_status:not_evaluated` and null references.
No result from this source assembly step qualifies a model or changes defaults.
