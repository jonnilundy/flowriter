#!/bin/zsh
# Drive the app through a scripted session without showing a window or taking focus,
# and save a picture of the window after the steps that ask for one.
#
#   scripts/drive.sh [script] [out-dir] [--keep-state]
#       default: Tests/FlowriterDrive/session.txt -> build/drive
#       --keep-state: start from what the last run left (its preferences and unsaved notes)
#
# The app's window is parked off every screen and the process may not become active, so this is
# safe to run on a desktop in use. The last line is "DRIVE PASS ..." or "DRIVE FAIL ...".
set -uo pipefail
cd "$(dirname "$0")/.."
SCRIPT=${1:-Tests/FlowriterDrive/session.txt}
OUT=${2:-build/drive}
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
swift build --disable-keychain --build-path .build-test -j ${JOBS:-8} --product FlowriterDrive > build/drive-build.log 2>&1 \
  || { echo "DRIVE FAIL (build): $(grep -m1 'error' build/drive-build.log | cut -c1-200)"; exit 1; }
BIN=$(swift build --disable-keychain --build-path .build-test --product FlowriterDrive --show-bin-path)/FlowriterDrive
[[ "${3:-}" == --keep-state ]] || rm -rf "$OUT"; mkdir -p "$OUT"
"$BIN" --script="$SCRIPT" --out="$OUT" ${3:-} 2>/dev/null | grep '^DRIVE'
exit ${pipestatus[1]}
