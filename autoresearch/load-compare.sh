#!/usr/bin/env bash
# Load comparison for Murmur's accurate-lane candidates.
#
# The question is which engine costs the machine least while still keeping up
# with speech — not which is fastest. RTF < 1 is the admission test; what decides
# is how much of the machine is spent per second of speech transcribed.
#
# The metric is energy per audio-second:
#
#     joules per audio-second = power above idle (W) x RTF
#
# because a saturated run processes window/RTF seconds of audio in a window of
# wall time, so the window cancels. Half the power at twice the RTF is a wash;
# this number says which way the trade actually went.
#
# On this Mac mini M1 under macOS 26 the per-block "CPU Power / GPU Power /
# ANE Power" lines are all flat 0 mW, but "Combined Power (CPU + GPU + ANE)" is
# live and tracks load (idle ~20 mW, saturated ~5.5 W) — so power IS available,
# as one combined figure. Residency is sampled alongside it, since it answers a
# different question: which block is busy. Note that at saturation every engine
# pins the GPU near 100%, so residency ranks nothing on its own — it is a
# placement check, not a load metric.
#
# ANE caveat: "ANE Power" reads 0 mW while idle AND while the CoreML encoder
# runs, so it cannot distinguish a busy Neural Engine from an unreported one.
# The contention test in Part 2 is the evidence that matters instead.
#
#     sudo ./load-compare.sh [clip.wav]
set -uo pipefail

CLIP="${1:-$HOME/bench.wav}"
CLI="$HOME/Murmur/MurmurKit/.build/release/murmur-cli"
OUT="/tmp/murmur-load.$$"
SETTLE=6
WINDOW=20
LEAD_IN=8          # skip model load/compile before sampling
MARGIN=10          # keep the run alive past the end of the window

[ "$(id -u)" = "0" ] || { echo "run with sudo — powermetrics needs root"; exit 1; }
[ -x "$CLI" ] || { echo "murmur-cli not built at $CLI"; exit 1; }
[ -f "$CLIP" ] || { echo "clip not found: $CLIP"; exit 1; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }
mkdir -p "$OUT"

# Mean GPU/E/P residency and mean combined power over a window. Errors are NOT
# hidden — an earlier version sent powermetrics' stderr to /dev/null and a silent
# failure read as "0 mW", which looked like a measurement instead of a bug.
sample_load() {                         # $1 = seconds, $2 = label -> "gpu e p watts"
    powermetrics --samplers cpu_power,gpu_power -i 500 -n $(( $1 * 2 )) \
        > "$OUT/$2.txt" 2> "$OUT/$2.err"
    if [ ! -s "$OUT/$2.txt" ]; then
        echo "powermetrics produced nothing; stderr:" >&2
        head -3 "$OUT/$2.err" >&2
        echo "0 0 0 0"
        return
    fi
    awk '
        /GPU HW active residency/       { sub(/%.*/, "", $5); g += $5; ng++ }
        /E-Cluster HW active residency/ { sub(/%.*/, "", $5); e += $5; ne++ }
        /P-Cluster HW active residency/ { sub(/%.*/, "", $5); p += $5; np++ }
        /Combined Power/                { w += $(NF-1); nw++ }   # mW
        END { printf "%.1f %.1f %.1f %.3f\n",
                     (ng?g/ng:0), (ne?e/ne:0), (np?p/np:0), (nw?w/nw/1000:0) }
    ' "$OUT/$2.txt"
}

echo "idle baseline (${SETTLE}s settle, 8s sample)…"
sleep "$SETTLE"
read -r IDLE_G IDLE_E IDLE_P IDLE_W <<< "$(sample_load 8 idle)"
printf "idle:  gpu %s%%  E %s%%  P %s%%  power %s W\n\n" \
       "$IDLE_G" "$IDLE_E" "$IDLE_P" "$IDLE_W"

run_engine() {                          # $1 = label, $2.. = cli args
    local label="$1"; shift
    printf "=== %s ===\n" "$label"

    # Calibration pass, also the warm-up: the ANE path compiles the CoreML model
    # on first use (~33 s cold, ~2.3 s once cached), and charging that to the
    # utterance would be measuring the installer. Its per-pass compute time then
    # sets how many passes the timed run needs to outlast the sampling window —
    # the previous version guessed (--repeat 200), killed the process mid-run,
    # and so never got an RTF at all.
    echo "  calibrating (also the warm-up)…"
    "$CLI" "$@" --repeat 1 --json-out "$OUT/$label.warm.json" >/dev/null 2>&1
    local per_pass
    per_pass=$(jq -r '.compute_seconds // empty' "$OUT/$label.warm.json" 2>/dev/null)
    if [ -z "$per_pass" ]; then
        echo "  calibration produced no JSON — cannot size the run; skipping"
        echo; return
    fi
    local passes
    passes=$(awk -v t=$(( LEAD_IN + WINDOW + MARGIN )) -v p="$per_pass" \
                 'BEGIN { n = int(t / p) + 1; print (n < 2 ? 2 : n) }')
    printf "  %.2fs per pass -> %s passes\n" "$per_pass" "$passes"

    sleep "$SETTLE"
    echo "  running + sampling ${WINDOW}s…"
    "$CLI" "$@" --repeat "$passes" --json-out "$OUT/$label.json" >/dev/null 2>&1 &
    local pid=$!
    sleep "$LEAD_IN"
    read -r G E P W <<< "$(sample_load "$WINDOW" "$label")"

    # A run that ended inside the window pollutes the sample with idle tail.
    # Say so rather than print an average of two different things.
    local finished_early=0
    kill -0 "$pid" 2>/dev/null || finished_early=1
    wait "$pid" 2>/dev/null

    local rtf; rtf=$(jq -r '.rtf // empty' "$OUT/$label.json" 2>/dev/null)
    [ -n "$rtf" ] || rtf="n/a"
    [ "$finished_early" = 1 ] && echo "  WARNING: run ended before the window closed — sample includes idle"

    awk -v g="$G" -v e="$E" -v p="$P" -v w="$W" \
        -v ig="$IDLE_G" -v ie="$IDLE_E" -v ip="$IDLE_P" -v iw="$IDLE_W" \
        -v rtf="$rtf" 'BEGIN {
        dg = g - ig; de = e - ie; dp = p - ip; dw = w - iw
        if (dg < 0) dg = 0; if (de < 0) de = 0; if (dp < 0) dp = 0; if (dw < 0) dw = 0
        printf "  RTF                %s     (<1 = faster than realtime)\n", rtf
        printf "  above idle         gpu %.1f%%   E %.1f%%   P %.1f%%   power %.2f W\n", dg, de, dp, dw
        if (rtf != "n/a")
            printf "  ENERGY PER AUDIO-SECOND  %.2f J/s   <-- the number that decides\n\n", dw * rtf
        else print ""
    }'
}

run_engine parakeet-mlx --parakeet "$CLIP"
run_engine parakeet-ane --parakeet "$CLIP" --ane
run_engine voxtral      --wav "$CLIP" --mode accurate

# ---- Part 2: do they fight? -------------------------------------------------
# Nemotron is pure MLX/GPU; Parakeet --ane puts its Conformer encoder on the
# Neural Engine and leaves the prompt MLP and TDT decode in MLX. If the split
# buys real parallelism, running them together costs the LONGER of the two. If
# MLX's serial queue dominates, it costs their SUM. Each leg is timed separately
# so the comparison is against real numbers, not a guess at the split.
echo "=== contention: Nemotron(GPU) + Parakeet(ANE) ==="
echo "  sequential…"
t0=$(date +%s); "$CLI" --wav "$CLIP" --mode fast --repeat 20 >/dev/null 2>&1
nemo=$(( $(date +%s) - t0 ))
t0=$(date +%s); "$CLI" --parakeet "$CLIP" --ane --repeat 20 >/dev/null 2>&1
para=$(( $(date +%s) - t0 ))
seq=$(( nemo + para ))

echo "  concurrent…"
t0=$(date +%s)
"$CLI" --wav "$CLIP" --mode fast --repeat 20 >/dev/null 2>&1 & a=$!
"$CLI" --parakeet "$CLIP" --ane --repeat 20 >/dev/null 2>&1 & b=$!
wait $a $b
con=$(( $(date +%s) - t0 ))

awk -v n="$nemo" -v p="$para" -v s="$seq" -v c="$con" 'BEGIN {
    longer = (n > p ? n : p)
    printf "  nemotron %ss   parakeet-ane %ss\n", n, p
    printf "  sequential %ss   concurrent %ss\n", s, c
    printf "  serialise -> %ss, fully overlap -> %ss\n", s, longer
    if (s > longer)
        printf "  OVERLAP %.0f%% of the theoretical maximum\n", 100 * (s - c) / (s - longer)
}'
echo
echo "raw output in $OUT"
