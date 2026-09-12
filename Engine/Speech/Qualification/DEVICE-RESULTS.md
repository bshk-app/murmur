# Device timing sidecars

```sh
uv run --no-project python Engine/Speech/Qualification/device_results.py /path/to/run \
  --output /path/to/device-summary.json
uv run --no-project python Engine/Speech/Qualification/device_results.py /path/to/baseline \
  --compare /path/to/candidate --output /path/to/comparison.json
uv run --no-project python -m unittest discover -s Engine/Speech/Qualification \
  -p 'test_device_results.py' -v
```

This standard-library utility reads raw attempt JSON and its corresponding
`attempt-XXXXXX-telemetry.jsonl`. It produces a SHA256-linked sidecar, **not an
Omni Bench Result**, a quality score, or a release gate decision. Input manifests,
build-source manifests and raw attempt/telemetry files are linked by digest.
Malformed files are reported rather than treated as successful measurements.

Results group by complete translation/speech profile, source/target direction,
scenario, speech pipeline, timing contract and device. Failed or unfinished
attempts remain counted, but never enter successful latency percentiles. p50/p95
use nearest rank: sort N finite nonnegative measurements and select
`ceil(p*N)-1`, without interpolation. For three measurements, p95 is their maximum.
Model-load time is not subtracted: the probe instantiates a service per attempt
and final latency includes cold work. Per-leg MT loading is shown separately from
whole-pipeline cold loading; missing whole-pipeline cold/preview values remain
null. Preparation that could include downloading is not relabeled as cold load.

Footprint is the observed maximum of raw process samples, not an absolute peak.
Warning/failure counts remain unavailable where raw observations are missing.
The original 15-attempt smoke run predates source fingerprints and pure cold-load
observations: its five groups can be summarized, but cannot qualify a replacement.

Comparison pairs groups only when device, direction, scenario, pipeline and
**timing-contract strings match exactly**. It requires identical sample IDs,
sample SHA256s, repeat IDs and stress-cycle identities, no duplicates, at least
three distinct repeat IDs per sample, complete measurements and build provenance.
Sequential Canary and concurrent ASR/MT cannot be ranked as equivalent latency
measurements. Incomplete or unmatched comparisons return reasons and null ratios.
All outputs remain `not_qualified` / `release_gate_eligible:false`; full stock
Omni Bench quality scoring, bilingual review and device release checks still apply.
