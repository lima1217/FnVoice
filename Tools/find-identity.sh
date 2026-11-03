#!/bin/sh
# Prints the best available code-signing identity, or nothing.
# A stable identity matters: TCC ties Accessibility/Input Monitoring grants to the signature,
# so with ad-hoc signing every rebuild looks like a new app and permissions must be re-granted.
ids=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' 'NF>1 {print $2}')
[ -z "$ids" ] && exit 0
for pattern in "FnVoice" "Developer ID Application" "Apple Development"; do
  match=$(printf '%s\n' "$ids" | grep -m1 "$pattern")
  if [ -n "$match" ]; then printf '%s\n' "$match"; exit 0; fi
done
printf '%s\n' "$ids" | head -n1
