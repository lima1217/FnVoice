#!/bin/sh
# Static checks on the built bundle. Fails on anything that would break the app at runtime;
# Gatekeeper (spctl) is reported but not fatal, since local/self-signed builds are never notarized.
set -u
APP="${1:?usage: verify.sh path/to/FnVoice.app}"
PLIST="$APP/Contents/Info.plist"
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "  ok    $1"; else echo "  FAIL  $1"; fail=1; fi; }

echo "== codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /' || fail=1
codesign --verify --deep --strict "$APP" 2>/dev/null || fail=1

echo "== signature"
codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|Authority|Signature|CodeDirectory|Runtime)" | sed 's/^/  /'
check "hardened runtime enabled" "codesign -dv '$APP' 2>&1 | grep -q 'flags=.*runtime'"
if codesign -dv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
  echo "  WARN  ad-hoc signature: TCC permissions will reset on every rebuild"
fi

echo "== entitlements"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - 2>/dev/null | sed 's/^/  /'
check "audio-input entitlement" "codesign -d --entitlements - --xml '$APP' 2>/dev/null | grep -q com.apple.security.device.audio-input"

echo "== Info.plist"
check "plutil -lint" "plutil -lint '$PLIST'"
check "LSUIElement = true" "[ \"\$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' '$PLIST')\" = true ]"
check "NSMicrophoneUsageDescription" "/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' '$PLIST'"
check "NSSpeechRecognitionUsageDescription" "/usr/libexec/PlistBuddy -c 'Print :NSSpeechRecognitionUsageDescription' '$PLIST'"
check "LSMinimumSystemVersion = 14.0" "[ \"\$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' '$PLIST')\" = 14.0 ]"
check "executable present" "[ -x '$APP/Contents/MacOS/FnVoice' ]"
check "arm64 slice" "lipo -archs '$APP/Contents/MacOS/FnVoice' | grep -q arm64"

echo "== Gatekeeper (informational)"
spctl -a -vv "$APP" 2>&1 | sed 's/^/  /' || true

if [ $fail -eq 0 ]; then echo "verify: PASS"; else echo "verify: FAIL"; fi
exit $fail
