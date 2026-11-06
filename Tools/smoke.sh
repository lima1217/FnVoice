#!/bin/sh
# Streams 3 corpus clips through the live SpeechAnalyzer path and fails on recognition errors or
# fallbacks, or a truncated final text. Launched via `open` so FnVoice.app holds the speech permission.
set -u
APP="${1:?usage: smoke.sh path/to/FnVoice.app}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$DIR/build/smoke"
mkdir -p "$OUT"
rm -f "$OUT/smoke.md" "$OUT/smoke.log"
open -n -W --stdout "$OUT/smoke.log" --stderr "$OUT/smoke.log" "$APP" --args \
  --latency-bench "$DIR/Eval/corpus.jsonl" --clips 3 --no-llm --prewarm --assert \
  --out "$OUT/smoke.md"
if grep -q "SMOKE: PASS" "$OUT/smoke.md" 2>/dev/null; then
  echo "smoke: PASS"
  exit 0
fi
echo "smoke: FAIL"
cat "$OUT/smoke.log" 2>/dev/null
exit 1
