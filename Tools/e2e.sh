#!/bin/sh
# Injects into InjectProbe under ABC and under the first enabled CJK input method, asserting the
# text arrives intact, the clipboard is restored, and the input source is restored.
# The ABC run then swaps a "refined" text in place and fixes a word over Accessibility, checking
# the swap landed and FnVoice learned the fix; the CJK run types on first and checks the swap is skipped.
set -u
APP="${1:?app}"; PROBE="${2:?probe}"
OUT="${TMPDIR:-/tmp}/fnvoice-probe.txt"
LOG="${TMPDIR:-/tmp}/fnvoice-e2e.log"
TEXT='我在用 piston 写一个 JSON 解析器, it works.'
REFINED='我在用 Python 写一个 JSON 解析器, it works.'
EDIT='我在用 Python 写一个 JSON 编译器, it works.'
status=0
for source in com.apple.keylayout.ABC cjk; do
  rm -f "$LOG"
  if [ "$source" = com.apple.keylayout.ABC ]; then
    set -- --replace-with "$REFINED" --edit-to "$EDIT"
  else
    set -- --replace-with "$REFINED" --after-move
  fi
  open -n -W --stdout "$LOG" --stderr "$LOG" "$APP" --args --selftest-inject \
    --probe "$PROBE" --out "$OUT" --text "$TEXT" --input-source "$source" "$@"
  result=$(tail -n1 "$LOG" 2>/dev/null)
  sleep 1
  echo "[$source] $result"
  case "$result" in
    *'"result":"pass"'*) ;;
    *'"result":"skipped"'*) [ $status -eq 0 ] && status=2 ;;
    *) status=1 ;;
  esac
done
case $status in
  0) echo "e2e: PASS" ;;
  2) echo "e2e: SKIPPED (see reasons above)" ;;
  *) echo "e2e: FAIL" ;;
esac
exit $status
