#!/bin/sh
# Synthesizes audio for every `mixed` corpus case that lacks a recording, using a Mandarin voice.
# Replace files in Eval/audio/ with real recordings for a harsher, more realistic test.
set -eu
CORPUS="${1:?corpus.jsonl}"
DIR=$(dirname "$CORPUS")
VOICE="${EVAL_VOICE:-Tingting}"
python3 - "$CORPUS" <<'PY' | while IFS="$(printf '\t')" read -r audio text; do
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("//"):
        continue
    c = json.loads(line)
    if c.get("kind") == "mixed" and c.get("audio"):
        print(c["audio"] + "\t" + c["reference"])
PY
  path="$DIR/$audio"
  if [ ! -f "$path" ]; then
    mkdir -p "$(dirname "$path")"
    say -v "$VOICE" -o "$path" "$text"
    echo "generated $path"
  fi
done
