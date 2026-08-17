#!/usr/bin/env bash
# Energy of a streaming lane, in joules per second of speech.
#
# The batch comparison in load-compare.sh saturates the machine and divides by
# RTF. A streaming lane cannot be measured that way: it is idle between chunks by
# design, and running it flat out would measure something nobody experiences.
#
# Paced at 1x real time, wall time equals audio time — so the RTF term cancels
# and the answer is simply:
#
#     joules per second of audio = mean power above idle, in watts
#
# The feeder reports realtime_ratio; anything above ~1.05 means the lane fell
# behind and the identity above no longer holds, so the number is discarded
# rather than quietly reported.
#
#     sudo ./stream-load.sh [clip.wav] [engine …]
#
# Engines are murmur-cli argument sets: "parakeet", "parakeet-int8",
# "parakeet-ane", "fast", "hybrid".
set -uo pipefail

CLIP="${1:-$HOME/bench.wav}"; shift 2>/dev/null || true
ENGINES=("$@")
[ ${#ENGINES[@]} -eq 0 ] && ENGINES=(parakeet-int8 parakeet-ane fast)

CLI="$HOME/Murmur/MurmurKit/.build/release/murmur-cli"
FEED="$HOME/Murmur/bench/stream-feed.py"
OUT="/tmp/murmur-stream-load.$$"
SETTLE=6
FEED_SECONDS=120     # long enough for a stable average over many utterances
LEAD_IN=15           # skip the first utterance: caches and kernels are cold
WINDOW=60

INT8_REPO="beshkenadze/parakeet-tdt-0.6b-v3-mlx-encoder-int8"

[ "$(id -u)" = "0" ] || { echo "run with sudo — powermetrics needs root"; exit 1; }
[ -x "$CLI" ] || { echo "murmur-cli not built at $CLI"; exit 1; }
[ -f "$FEED" ] || { echo "feeder missing at $FEED"; exit 1; }
[ -f "$CLIP" ] || { echo "clip not found: $CLIP"; exit 1; }
mkdir -p "$OUT"

engine_args() {
    case "$1" in
        parakeet)      echo "--parakeet" ;;
        parakeet-int8) echo "--parakeet --repo $INT8_REPO" ;;
        parakeet-ane)  echo "--parakeet --ane" ;;
        fast|hybrid|accurate) echo "--mode $1" ;;
        *) echo "unknown engine: $1" >&2; return 1 ;;
    esac
}

# Mean combined power and GPU/CPU residency over a window. stderr is kept: an
# earlier version discarded it and a powermetrics failure read as "0 mW".
sample_load() {                          # $1 = seconds, $2 = label -> "gpu e p watts"
    powermetrics --samplers cpu_power,gpu_power -i 500 -n $(( $1 * 2 )) \
        > "$OUT/$2.txt" 2> "$OUT/$2.err"
    if [ ! -s "$OUT/$2.txt" ]; then
        echo "powermetrics produced nothing; stderr:" >&2
        head -3 "$OUT/$2.err" >&2
        echo "0 0 0 0"; return
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
printf "idle:  gpu %s%%  E %s%%  P %s%%  power %s W\n\n" "$IDLE_G" "$IDLE_E" "$IDLE_P" "$IDLE_W"

for engine in "${ENGINES[@]}"; do
    args=$(engine_args "$engine") || continue
    printf "=== %s ===\n" "$engine"
    echo "  loading + feeding ${FEED_SECONDS}s of speech at 1x…"

    # shellcheck disable=SC2086
    python3 "$FEED" "$CLI" "$CLIP" "$FEED_SECONDS" $args > "$OUT/$engine.out" 2> "$OUT/$engine.err" &
    feeder=$!

    # Sample only once audio is actually flowing: the feeder prints READY after
    # the model is loaded, and loading is not what we are measuring.
    for _ in $(seq 1 1800); do
        grep -q "^READY" "$OUT/$engine.out" 2>/dev/null && break
        kill -0 "$feeder" 2>/dev/null || break
        sleep 1
    done
    if ! kill -0 "$feeder" 2>/dev/null; then
        echo "  worker died before feeding; stderr:"; tail -3 "$OUT/$engine.err"; echo; continue
    fi

    sleep "$LEAD_IN"
    read -r G E P W <<< "$(sample_load "$WINDOW" "$engine")"
    still_running=1; kill -0 "$feeder" 2>/dev/null || still_running=0
    wait "$feeder" 2>/dev/null

    ratio=$(awk '/realtime_ratio/ {print $2}' "$OUT/$engine.out")
    [ -n "$ratio" ] || ratio="n/a"
    [ "$still_running" = 0 ] && echo "  WARNING: feeding ended before the window closed — sample includes idle"
    grep -q WARNING "$OUT/$engine.err" && echo "  WARNING: the lane fell behind real time (see $OUT/$engine.err)"

    awk -v g="$G" -v e="$E" -v p="$P" -v w="$W" \
        -v ig="$IDLE_G" -v ie="$IDLE_E" -v ip="$IDLE_P" -v iw="$IDLE_W" -v r="$ratio" 'BEGIN {
        dg = g - ig; de = e - ie; dp = p - ip; dw = w - iw
        if (dg < 0) dg = 0; if (de < 0) de = 0; if (dp < 0) dp = 0; if (dw < 0) dw = 0
        printf "  realtime ratio     %s     (>1.05 = fell behind, number below is void)\n", r
        printf "  above idle         gpu %.1f%%   E %.1f%%   P %.1f%%\n", dg, de, dp
        printf "  ENERGY PER AUDIO-SECOND  %.2f J/s   <-- the number that decides\n\n", dw
    }'
done

echo "raw output in $OUT"
