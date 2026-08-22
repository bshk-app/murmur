#!/usr/bin/env bash
# autoresearch verify+guard for Murmur pipeline performance.
#
# Metric: hybrid RTF on alex-mac, min of 3 passes, lower_is_better.
# Guard : transcript word-overlap vs baseline >= 0.90, and the unit tests pass.
#
# The guard on TEXT is the point. Every cheap way to improve RTF here — bigger
# chunks, shorter Voxtral delay, a coarser VAD — pays for it in transcription
# quality, and the metric alone cannot see that.
set -uo pipefail

REMOTE=alex-mac
CLIP='~/bench.wav'
BASE_TXT="$(dirname "$0")/baseline-text.txt"

rsync -az --exclude='.build' -e ssh /Volumes/DATA/Murmur/MurmurKit/Sources/ "$REMOTE:~/Murmur/MurmurKit/Sources/" || { echo "STATUS=crash REASON=rsync"; exit 1; }

OUT=$(ssh -o ServerAliveInterval=30 "$REMOTE" "cd ~/Murmur/MurmurKit && swift build -c release --product murmur-cli 2>&1 | grep -E '^.*error:' ; cd ~/Murmur && ./MurmurKit/.build/release/murmur-cli --wav $CLIP --mode hybrid --repeat 3 2>/dev/null") || { echo "STATUS=crash REASON=ssh"; exit 1; }

RTF=$(printf '%s' "$OUT" | awk '/RTF_MIN/ {print $2}')
TEXT=$(printf '%s' "$OUT" | sed -n 's/^text: //p')

[ -n "$RTF" ] || { echo "STATUS=metric-error REASON=no-rtf"; exit 1; }
[ -n "$TEXT" ] || { echo "STATUS=metric-error REASON=no-text"; exit 1; }

# First run establishes the reference transcript.
if [ ! -f "$BASE_TXT" ]; then printf '%s\n' "$TEXT" > "$BASE_TXT"; fi

OVERLAP=$(python3 - "$BASE_TXT" <<PY "$TEXT"
import sys
base = open(sys.argv[1]).read().lower().split()
new  = sys.argv[2].lower().split() if len(sys.argv) > 2 else []
if not base: print("0.0"); raise SystemExit
from collections import Counter
b, n = Counter(base), Counter(new)
kept = sum((b & n).values())
print(f"{kept/len(base):.3f}")
PY
)

# `grep -c` exits 1 on zero matches, so the fallback must not hang off its status
# — the `|| true` is inside the remote shell, and 99 only marks an ssh failure.
TESTS=$(ssh "$REMOTE" "cd ~/Murmur/MurmurKit && swift test 2>&1 | grep -cE 'error:' || true" 2>/dev/null)
[ -n "$TESTS" ] || TESTS=99

GUARD=pass
awk -v o="$OVERLAP" 'BEGIN{exit !(o+0 >= 0.90)}' || GUARD=fail-text
[ "$TESTS" = "0" ] || GUARD=fail-tests

echo "RTF=$RTF OVERLAP=$OVERLAP TESTS_ERRORS=$TESTS GUARD=$GUARD"
printf 'text: %s\n' "$TEXT"
