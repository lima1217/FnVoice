#!/bin/sh
# Assembles and signs one .app bundle, skipping both when nothing that goes into it changed.
#   bundle.sh <app> <binary> <Info.plist> <identity> [entitlements] [icon]
# Every codesign call reads the signing key from the keychain, which can prompt for a password;
# `make check`, `make e2e` and `make install` each rebuild, so re-signing an unchanged binary
# meant one prompt per bundle per target. The stamp sits beside the bundle, not inside it, so it
# never touches the signature.
set -eu
app=$1 bin=$2 plist=$3 identity=$4 entitlements=${5:-} icon=${6:-}
stamp="$(dirname "$app")/.$(basename "$app").stamp"
name=$(basename "$bin")

sum=$( { cat "$bin" "$plist"; [ -z "$entitlements" ] || cat "$entitlements"; [ -z "$icon" ] || cat "$icon"; \
         printf '%s' "$identity"; } | shasum -a 256 | cut -d' ' -f1)

if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$sum" ] && codesign -v "$app" 2>/dev/null; then
  echo "unchanged $app"
  exit 0
fi

rm -rf "$app" "$stamp"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/$name"
cp "$plist" "$app/Contents/Info.plist"
if [ -n "$icon" ]; then
  mkdir -p "$app/Contents/Resources"
  cp "$icon" "$app/Contents/Resources/$(basename "$icon")"
fi
if [ -n "$entitlements" ]; then
  codesign --force --options runtime --timestamp=none --entitlements "$entitlements" --sign "$identity" "$app"
else
  codesign --force --timestamp=none --sign "$identity" "$app"
fi
echo "$sum" > "$stamp"
echo "signed $app"
