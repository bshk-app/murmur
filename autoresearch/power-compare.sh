#!/usr/bin/env bash
# Power comparison for Murmur's accurate-lane candidates.
#
# The question is not "which is fastest". It is "which costs least while still
# keeping up with speech". For an app that runs in the background all day on
# battery, a model at RTF 0.025 that pegs the GPU is worse than one at RTF 0.3
# that sips the ANE — what drains the battery during continuous dictation is
# power x duty cycle, not peak speed.
#
# So: RTF < 1 is the admission test, and the number that decides is
#
#     W_per_audio_second = (power above idle) x RTF
#
# which is exactly the sustained draw while someone dictates without pause.
#
# Idle is measured first and subtracted, so what is reported is the cost of
# transcribing, not the cost of owning the machine.
#
# Needs sudo for powermetrics — run it yourself:
#     sudo ./power-compare.sh [clip.wav]
set -uo pipefail

CLIP="${1:-$HOME/meeting.wav}"
CLI="$HOME/Murmur/MurmurKit/.build/release/murmur-cli"
OUT="${TMPDIR:-/tmp}/murmur-power.$$"
SETTLE=8          # seconds of idle before each sample window
WINDOW=25         # seconds each engine should stay busy

[ -x "$CLI" ] || { echo "murmur-cli not built at $CLI"; exit 1; }
[ -f "$CLIP" ]  || { echo "clip not found: $CLIP"; exit 1; }
[ "$(id -u)" = "0" ] || { echo "run with sudo — powermetrics needs root"; exit 1; }
mkdir -p "$OUT"

# Average mW over a sampling window. powermetrics prints one block per interval;
# we take the mean of every block so a single spike cannot decide the result.
sample_power() {                       # $1 = seconds, $2 = label
    powermetrics --samplers cpu_power,gpu_power,ane_power -i 500 -n $(( $1 * 2 )) \
        > "$OUT/$2.txt" 2>/dev/null
    awk '
        /CPU Power:/ { c += $3; nc++ }
        /GPU Power:/ { g += $3; ng++ }
        /ANE Power:/ { a += $3; na++ }
        END { printf "%.0f %.0f %.0f\n", (nc?c/nc:0), (ng?g/ng:0), (na?a/na:0) }
    ' "$OUT/$2.txt"
}

echo "settling ${SETTLE}s, then measuring idle…"
sleep "$SETTLE"
read -r IDLE_C IDLE_G IDLE_A <<< "$(sample_power 10 idle)"
printf "idle:  cpu %s mW  gpu %s mW  ane %s mW\n\n" "$IDLE_C" "$IDLE_G" "$IDLE_A"

run_engine() {                          # $1 = label, $2.. = cli args
    local label="$1"; shift
    echo "=== $label ==="
    sleep "$SETTLE"

    # Busy the process for the whole window, sampling power alongside it.
    "$CLI" "$@" > "$OUT/$label.out" 2>/dev/null &
    local pid=$!
    read -r C G A <<< "$(sample_power "$WINDOW" "$label")"
    wait "$pid" 2>/dev/null

    local rtf audio
    rtf=$(awk '/RTF_MIN/ {print $2}'         "$OUT/$label.out")
    audio=$(awk '/audio_processed/ {print $2}' "$OUT/$label.out")
    [ -n "$audio" ] || audio=$(awk '/^audio / {print $2}' "$OUT/$label.out")

    awk -v c="$C" -v g="$G" -v a="$A" -v ic="$IDLE_C" -v ig="$IDLE_G" -v ia="$IDLE_A" \
        -v rtf="$rtf" -v label="$label" 'BEGIN {
        dc = c - ic; dg = g - ig; da = a - ia
        if (dc < 0) dc = 0; if (dg < 0) dg = 0; if (da < 0) da = 0
        tot = dc + dg + da
        printf "  RTF          %s\n", rtf
        printf "  above idle   cpu %.0f mW   gpu %.0f mW   ane %.0f mW   total %.0f mW\n", dc, dg, da, tot
        printf "  W per second of audio  %.3f   <-- the number that decides\n\n", tot * rtf / 1000
    }'
}

# Parakeet needs enough passes to stay busy for the window; Voxtral fills it on
# its own. Pass counts are rough — the metric normalises by audio processed.
run_engine parakeet-mlx --parakeet "$CLIP" --repeat 40
run_engine parakeet-ane --parakeet "$CLIP" --ane --repeat 40
run_engine voxtral      --wav "$CLIP" --mode accurate --repeat 2

echo "raw powermetrics output kept in $OUT"
