#!/usr/bin/env bash
# Load comparison for Murmur's accurate-lane candidates.
#
# The question is which engine costs the machine least while still keeping up
# with speech — not which is fastest. RTF < 1 is the admission test; what decides
# is how much of the machine is occupied while someone dictates without pause.
#
# Power would be the ideal metric. It is not available here: on this Mac mini M1
# under macOS 26, powermetrics reports CPU/GPU/ANE Power as a flat 0 mW, and
# there is no ANE utilisation section at all. What it does report is RESIDENCY —
# the share of wall time each block was actually working — which answers the
# question directly enough:
#
#     occupancy = residency x RTF
#
# "the share of the GPU held continuously while dictating". And it doubles as an
# ANE check: if Parakeet-on-ANE transcribes with the GPU near idle, the work
# really went to the Neural Engine; if the GPU lights up, CoreML fell back.
#
# Part 2 answers "do the two models fight": the same pair run back to back and
# then together. Wall time near the sum means they serialise; near the longer of
# the two means they genuinely overlap.
#
#     sudo ./load-compare.sh [clip.wav]
set -uo pipefail

CLIP="${1:-$HOME/bench.wav}"
CLI="$HOME/Murmur/MurmurKit/.build/release/murmur-cli"
OUT="/tmp/murmur-load.$$"
SETTLE=6
WINDOW=20
LEAD_IN=6          # skip model load/compile before sampling

[ "$(id -u)" = "0" ] || { echo "run with sudo — powermetrics needs root"; exit 1; }
[ -x "$CLI" ] || { echo "murmur-cli not built at $CLI"; exit 1; }
[ -f "$CLIP" ] || { echo "clip not found: $CLIP"; exit 1; }
mkdir -p "$OUT"

# Mean active residency over a window. Errors are NOT hidden — the previous
# version sent powermetrics' stderr to /dev/null and a silent failure read as
# "0 mW", which looked like a measurement instead of a bug.
sample_residency() {                    # $1 = seconds, $2 = label
    powermetrics --samplers cpu_power,gpu_power -i 500 -n $(( $1 * 2 )) \
        > "$OUT/$2.txt" 2> "$OUT/$2.err"
    if [ ! -s "$OUT/$2.txt" ]; then
        echo "powermetrics produced nothing; stderr:" >&2
        head -3 "$OUT/$2.err" >&2
        echo "0 0"
        return
    fi
    awk '
        /GPU HW active residency/ { sub(/%.*/, "", $5); g += $5; ng++ }
        /E-Cluster HW active residency/ { sub(/%.*/, "", $5); e += $5; ne++ }
        /P-Cluster HW active residency/ { sub(/%.*/, "", $5); p += $5; np++ }
        END { printf "%.1f %.1f\n", (ng?g/ng:0), ((ne?e/ne:0) + (np?p/np:0)) }
    ' "$OUT/$2.txt"
}

echo "idle baseline (${SETTLE}s settle, 8s sample)…"
sleep "$SETTLE"
read -r IDLE_G IDLE_C <<< "$(sample_residency 8 idle)"
printf "idle:  gpu %s%%  cpu %s%%\n\n" "$IDLE_G" "$IDLE_C"

run_engine() {                          # $1 = label, $2 = passes, $3.. = cli args
    local label="$1"; local passes="$2"; shift 2
    printf "=== %s ===\n" "$label"

    # Throwaway run first: the ANE path compiles the CoreML model on first use
    # (~33 s cold, ~2.3 s once cached). Charging that to the utterance would be
    # measuring the installer, not the model.
    echo "  warming…"
    "$CLI" "$@" --repeat 1 > /dev/null 2>&1

    sleep "$SETTLE"
    echo "  running + sampling ${WINDOW}s…"
    "$CLI" "$@" --repeat "$passes" > "$OUT/$label.out" 2>/dev/null &
    local pid=$!
    sleep "$LEAD_IN"
    read -r G C <<< "$(sample_residency "$WINDOW" "$label")"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

    local rtf; rtf=$(awk '/RTF_MIN/ {print $2}' "$OUT/$label.out")
    [ -n "$rtf" ] || rtf="n/a"

    awk -v g="$G" -v c="$C" -v ig="$IDLE_G" -v ic="$IDLE_C" -v rtf="$rtf" 'BEGIN {
        dg = g - ig; dc = c - ic
        if (dg < 0) dg = 0; if (dc < 0) dc = 0
        printf "  RTF                %s\n", rtf
        printf "  above idle         gpu %.1f%%   cpu %.1f%%\n", dg, dc
        if (rtf != "n/a")
            printf "  GPU held while dictating  %.2f%%   <-- the number that decides\n\n", dg * rtf
        else print ""
    }'
}

# Pass counts only need to outlast the sampling window; the run is killed after.
run_engine parakeet-mlx 200 --parakeet "$CLIP"
run_engine parakeet-ane 200 --parakeet "$CLIP" --ane
run_engine voxtral        8 --wav "$CLIP" --mode accurate

# ---- Part 2: do they fight? -------------------------------------------------
echo "=== contention: Nemotron(GPU) + Parakeet(ANE) ==="
echo "  sequential…"
t0=$(date +%s)
"$CLI" --wav "$CLIP" --mode fast --repeat 20 > /dev/null 2>&1
"$CLI" --parakeet "$CLIP" --ane --repeat 20 > /dev/null 2>&1
seq=$(( $(date +%s) - t0 ))

echo "  concurrent…"
t0=$(date +%s)
"$CLI" --wav "$CLIP" --mode fast --repeat 20 > /dev/null 2>&1 &
a=$!
"$CLI" --parakeet "$CLIP" --ane --repeat 20 > /dev/null 2>&1 &
b=$!
wait $a $b
con=$(( $(date +%s) - t0 ))

printf "  sequential %ss   concurrent %ss\n" "$seq" "$con"
echo "  near the sum -> they serialise; near the longer one -> they overlap"
echo
echo "raw output in $OUT"
