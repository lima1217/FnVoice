#!/bin/sh
# Streams 3 corpus clips through the live SpeechAnalyzer path, with live text on and off, and
# fails on recognition errors or fallbacks, an empty capsule (no partials while speaking), or a
# truncated final text. Launched via `open` so FnVoice.app holds the speech permission.
set -u
APP="${1:?usage: smoke.sh path/to/FnVoice.app}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$DIR/build/smoke"
mkdir -p "$OUT"
status=0
for mode in on off; do
  rm -f "$OUT/live-$mode.md" "$OUT/live-$mode.log"
  open -n -W --stdout "$OUT/live-$mode.log" --stderr "$OUT/live-$mode.log" "$APP" --args \
    --latency-bench "$DIR/Eval/corpus.jsonl" --clips 3 --no-llm --prewarm --live-text "$mode" --assert \
    --out "$OUT/live-$mode.md"
  if grep -q "SMOKE: PASS" "$OUT/live-$mode.md" 2>/dev/null; then
    echo "smoke (live text $mode): PASS"
  else
    echo "smoke (live text $mode): FAIL"
    cat "$OUT/live-$mode.log" 2>/dev/null
    status=1
  fi
done
exit $status
