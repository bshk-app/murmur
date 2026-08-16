#!/usr/bin/env bash
# Run one or more Murmur engines against a FLEURS Russian Task and score each.
#
#     ./run-fleurs-ru.sh <omni-bench-checkout> <work-dir> [task-id] [engine …]
#
# Defaults to the quick Task and every engine. Engine names are the adapter's
# factory names, so what appears here is exactly what lands in --adapter.
#
# Why `hybrid` is not in the default list: TwoTierSession.finish() returns the
# accurate lane's text verbatim unless the overload valve shed mid-utterance, so
# on offline files hybrid and accurate produce the same transcript and the same
# WER. Running it costs ~30 minutes to re-measure `accurate`. Ask for it by name
# when the valve behaviour is what is being tested.
set -uo pipefail

OB="${1:?path to an omni-bench checkout}"
WORK="${2:?work directory for data/ and runs/}"
TASK="${3:-asr.fleurs.ru.quick.v1}"
shift 3 2>/dev/null || shift $#
ENGINES=("$@")
[ ${#ENGINES[@]} -eq 0 ] && ENGINES=(parakeet_mlx parakeet_ane fast accurate)

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$BENCH_DIR/../MurmurKit/.build/release/murmur-cli"
OMNI="$OB/python/.venv/bin/omni-bench"
BUNDLE="$OB/fixtures/consumer-bundle"
PROFILE='{"delivery":"batch","chunk_ms":null,"warmup_samples":0,"concurrency":1,"family_parameters":{}}'

[ -x "$OMNI" ]  || { echo "omni-bench not installed at $OMNI"; exit 1; }
[ -x "$CLI" ]   || { echo "murmur-cli not built: swift build -c release --product murmur-cli"; exit 1; }
mkdir -p "$WORK/runs"

MANIFEST="$WORK/data/$TASK/manifest.json"
if [ ! -f "$MANIFEST" ]; then
    echo "=== preparing $TASK ==="
    "$OMNI" prepare "$TASK" --out "$WORK/data" --registry-bundle "$BUNDLE" || exit 1
fi

export PYTHONPATH="$BENCH_DIR"
for engine in "${ENGINES[@]}"; do
    label="${engine//_/-}"
    echo "=== $label ==="
    # Batch profile: the producer hands over a whole prepared file. The chunking
    # the --mode lanes do internally is the engine's business; declaring it as
    # streaming would claim producer-paced delivery this path does not implement.
    if ! "$OMNI" run \
            --adapter "murmur_bench.adapter:$engine" \
            --manifest "$MANIFEST" \
            --measurement-profile audio_transcription.batch_single.v1 \
            --run-profile "$PROFILE" \
            --implementation swift \
            --registry-bundle "$BUNDLE" \
            --out "$WORK/runs/$label.jsonl" 2>&1 | grep -v "^Using cached" ; then
        echo "  RUN FAILED — continuing with the next engine"
        continue
    fi
    "$OMNI" score \
        --manifest "$MANIFEST" \
        --artifact "$WORK/runs/$label.jsonl" \
        --registry-bundle "$BUNDLE" \
        --out "$WORK/runs/$label.result.json" || echo "  SCORE FAILED"
done

echo
echo "=== $TASK ==="
for f in "$WORK"/runs/*.result.json; do
    [ -f "$f" ] || continue
    jq -r --arg n "$(basename "$f" .result.json)" '
        (.observations[]? | select(.metric_ref.id=="quality.wer_norm.v1") | .value.value) as $wer
        | (.observations[]? | select(.metric_ref.id=="quality.cer.v1")      | .value.value) as $cer
        | "\($n)\t\($wer * 100 | .*100 | round / 100)%\t\($cer * 100 | .*100 | round / 100)%\t\(.counts.n_ok)/\(.counts.n_total)\t\(.status)"
    ' "$f"
done | sort -t$'\t' -k2 -n | awk 'BEGIN { printf "%-16s %8s %8s %8s  %s\n", "engine", "WER", "CER", "ok", "status" }
     { printf "%-16s %8s %8s %8s  %s\n", $1, $2, $3, $4, $5 }'
