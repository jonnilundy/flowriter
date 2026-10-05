#!/bin/zsh
# Headless Sparkle end-to-end test (no windows, no Dock icon), with a throwaway EdDSA key:
#   scripts/test-update.sh              the update signed with the app's key installs
#   scripts/test-update.sh --wrong-key  an update signed with another key is refused
# Copies the built app (build/Flowriter.app, from scripts/bundle.sh with INSTALL=0) to a temp
# dir with a throwaway SUPublicEDKey, makes a re-signed copy one build newer, zips and signs it,
# serves an appcast on localhost, and runs the old copy with --sparkle-probe pointed at it
# (FLOSTATE_FEED_URL). Installing replaces the temp copy, so the real key is never involved.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
MODE=install; [[ ${1:-} == --wrong-key ]] && MODE=refuse
SRC="${SRC:-$ROOT/build/Flowriter.app}"
SPARKLE_BIN="$ROOT/.build-release/artifacts/sparkle/Sparkle/bin"
[[ -d $SRC ]] || { echo "no $SRC: run INSTALL=0 scripts/bundle.sh first" >&2; exit 1; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/flowriter-update-test.XXXXXX")
trap '[[ -n "${SERVER:-}" ]] && kill $SERVER 2>/dev/null; [[ -n "${KEEP:-}" ]] && echo "kept $WORK" || rm -rf "$WORK"' EXIT

newkey() { openssl genpkey -algorithm ed25519 | openssl pkey -outform DER | tail -c 32 | base64; }
APP_SEED=$(newkey); SIGN_SEED=$APP_SEED
[[ $MODE == refuse ]] && SIGN_SEED=$(newkey)
APP_PUB=$(printf '%s' "$APP_SEED" | swift "$ROOT/scripts/ed-public-key.swift")

APP="$WORK/installed/Flowriter.app"
mkdir -p "$WORK/installed" "$WORK/serve" "$WORK/next"
ditto "$SRC" "$APP"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $APP_PUB" "$APP/Contents/Info.plist"
"$ROOT/scripts/sign.sh" "$APP" >/dev/null 2>&1
N=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
NEXT=$((N + 1))
ditto "$APP" "$WORK/next/Flowriter.app"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $NEXT" -c "Set CFBundleShortVersionString 99.0.0" "$WORK/next/Flowriter.app/Contents/Info.plist"
"$ROOT/scripts/sign.sh" "$WORK/next/Flowriter.app" >/dev/null 2>&1
ZIP="$WORK/serve/Flowriter-99.0.0.zip"
ditto -c -k --keepParent "$WORK/next/Flowriter.app" "$ZIP"

SIG=$(printf '%s' "$SIGN_SEED" | "$SPARKLE_BIN/sign_update" --ed-key-file - -p "$ZIP")
printf '%s' "$SIGN_SEED" | "$SPARKLE_BIN/sign_update" --verify --ed-key-file - "$ZIP" "$SIG" >/dev/null && echo "sign_update: signature verifies"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 "$ROOT/scripts/appcast.py" "$WORK/serve/appcast.xml" --version 99.0.0 --build $NEXT \
  --url "http://localhost:$PORT/${ZIP:t}" --ed-signature "$SIG" --length $(stat -f%z "$ZIP") >/dev/null
(cd "$WORK/serve" && exec python3 -m http.server $PORT --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER=$!
sleep 1

echo "installed: $N -> offering $NEXT ($MODE)"
FLOSTATE_FEED_URL="http://localhost:$PORT/appcast.xml" "$APP/Contents/MacOS/FloStateNative" --sparkle-probe || {
  [[ $MODE == refuse ]] || { echo "FAIL: probe exited with an error" >&2; exit 1; }; }
# the installer finishes after the app quits
for i in {1..60}; do
  V=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo "")
  [[ "$V" == "$NEXT" ]] && break
  sleep 0.5
done
if [[ $MODE == refuse ]]; then
  [[ "$V" == "$N" ]] && echo "PASS: an update signed with another key was refused (still at $V)" || { echo "FAIL: installed $V from a wrong-key feed" >&2; exit 1; }
elif [[ "$V" == "$NEXT" ]]; then
  codesign --verify --deep --strict "$APP" && echo "PASS: updated $N -> $NEXT, signature valid"
else
  echo "FAIL: still at $V" >&2; exit 1
fi
