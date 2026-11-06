#!/bin/sh
# First Fn press after a cold start: quits FnVoice, leaves the mic untouched for GAP seconds
# (CoreAudio's input path goes cold again after ~1 minute), then launches the app with a
# synthetic press AFTER seconds later and checks press-to-ready stayed within budget.
# Launched via `open` so FnVoice.app, not the terminal, holds the mic permission.
set -u
APP="${1:?usage: coldstart.sh path/to/FnVoice.app}"
GAP="${GAP:-120}"; AFTER="${AFTER:-5}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$DIR/build/coldstart.log"
pkill -x FnVoice 2>/dev/null
echo "coldstart: idling ${GAP}s with the mic untouched"
sleep "$GAP"
rm -f "$LOG"
open -W --stdout "$LOG" --stderr "$LOG" "$APP" --args --first-press --after "$AFTER"
cat "$LOG"
grep -q "FIRSTPRESS: PASS" "$LOG" 2>/dev/null
