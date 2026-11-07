#!/bin/sh
# Would the in-place swap work in a given text field? Runs FnVoice.app --ax-probe through `open`,
# so the app's Accessibility grant is used, not the terminal's.
#   make ax-probe                 isolated Chrome (temp profile): textarea + contenteditable
#   make ax-probe TARGET=Planet   the focused field of a running app (env APP here)
#   make ax-probe DELAY=5         whatever is frontmost after 5 s (click into it meanwhile)
# The Chrome case never touches the user's own Chrome: it starts a separate instance and kills
# only that instance, found by its profile path.
set -u
app=$1
work=$(mktemp -d /tmp/fnvoice-axprobe.XXXXXX)
log="$work/probe.log"
status=0

probe() {
  rm -f "$log"
  open -n -W --stdout "$log" --stderr "$log" "$app" --args --ax-probe "$@"
  cat "$log"
  grep -q '^PASS\|^SKIP' "$log" || status=1
}

if [ -n "${APP:-}" ]; then
  probe --app "$APP"
elif [ -n "${DELAY:-}" ]; then
  echo "click into the field to test; probing the frontmost app in ${DELAY}s"
  probe --delay "$DELAY"
else
  chrome="/Applications/Google Chrome.app"
  [ -d "$chrome" ] || { echo "Google Chrome not installed"; exit 1; }
  cat > "$work/textarea.html" <<'EOF'
<textarea id=f autofocus style="width:600px;height:100px">值得分享出来给有需要的人。</textarea>
<script>const f=document.getElementById('f');f.focus();f.setSelectionRange(f.value.length,f.value.length)</script>
EOF
  cat > "$work/contenteditable.html" <<'EOF'
<div id=f contenteditable style="width:600px;height:100px;border:1px solid">值得分享出来给有需要的人。</div>
<script>const f=document.getElementById('f');f.focus();const r=document.createRange();r.selectNodeContents(f);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r)</script>
EOF
  for page in textarea contenteditable; do
    echo "== Chrome $page"
    open -na "$chrome" --args --user-data-dir="$work/profile" --no-first-run --no-default-browser-check \
      --new-window "file://$work/$page.html"
    pid=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      sleep 0.5
      # The browser process is the one without --type= (renderers and helpers carry one).
      pid=$(pgrep -f -- "--user-data-dir=$work/profile" | while read -r p; do
              ps -o args= -p "$p" | grep -q -- '--type=' || echo "$p"; done | head -1)
      [ -n "$pid" ] && break
    done
    if [ -z "$pid" ]; then echo "FAIL Chrome did not start"; status=1; continue; fi
    sleep 2  # page load + autofocus
    probe --pid "$pid"
    pkill -f -- "--user-data-dir=$work/profile"
    sleep 1
  done
fi

rm -rf "$work"
exit $status
