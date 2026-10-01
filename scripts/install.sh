#!/bin/zsh
# Install build/Flowriter.app as /Applications/Flowriter.app.
# Fork: its own bundle id and path, so upstream Flo State is never touched or replaced.
# Never launches the app (set RELAUNCH=1 to reopen it when it was running before).
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${SRC:-build/Flowriter.app}"
DST="/Applications/Flowriter.app"
WAS_RUNNING=0; pgrep -f "Flowriter.app/Contents/MacOS/FloStateNative" >/dev/null && WAS_RUNNING=1
pkill -f "Flowriter.app/Contents/MacOS/FloStateNative" 2>/dev/null || true
rm -rf "$DST"
cp -R "$SRC" "$DST"
scripts/sign.sh "$DST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DST" 2>/dev/null || true
echo "installed: $DST"
if [[ $WAS_RUNNING == 1 && "${RELAUNCH:-0}" == 1 ]]; then open -g -a "$DST"; fi
