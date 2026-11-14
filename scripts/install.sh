#!/bin/zsh
# Install build/Flowriter.app as /Applications/Flowriter.app.
#
#   scripts/install.sh               SRC=<app> to install another build, DST=<app> for another place
#
# A running copy at DST is asked to quit the normal way (SIGTERM, which the app turns into Quit),
# so unsaved notes are kept as drafts and come back. It is reopened in the background afterwards.
# RELAUNCH=0: do not reopen it. When it does not quit within 20 s the install stops and changes
# nothing; FORCE=1 kills it instead (unsaved typing since the last autosave is lost).
# Nothing is launched when no copy was running.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${SRC:-build/Flowriter.app}"
DST="${DST:-/Applications/Flowriter.app}"
[[ -d "$SRC" ]] || { echo "no app at $SRC (scripts/bundle.sh builds one)" >&2; exit 66; }

# the copy that runs from DST, matched by its full executable path
running() { ps -axo pid=,command= | awk -v exe="$DST/Contents/MacOS/" '{ pid = $1; sub(/^ *[0-9]+ /, ""); if (index($0, exe) == 1) print pid }'; }
PIDS=(${(f)"$(running)"})
if (( ${#PIDS} )); then
  kill -TERM $PIDS
  for _ in {1..80}; do
    alive=0; for p in $PIDS; do kill -0 $p 2>/dev/null && alive=1; done
    (( alive )) || break
    sleep 0.25
  done
  if (( alive )); then
    if [[ "${FORCE:-0}" == 1 ]]; then
      kill -KILL $PIDS 2>/dev/null || true; sleep 0.5
    else
      echo "Flowriter at $DST did not quit within 20 s; nothing installed (FORCE=1 kills it)" >&2
      exit 75
    fi
  fi
fi

# copy next to the old app first, so a failed copy leaves the old one in place
NEW="$DST.installing"
rm -rf "$NEW"
ditto "$SRC" "$NEW"
scripts/sign.sh "$NEW" >/dev/null
rm -rf "$DST"
mv "$NEW" "$DST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DST" 2>/dev/null || true
echo "installed: $DST ($(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DST/Contents/Info.plist"))"
if (( ${#PIDS} )) && [[ "${RELAUNCH:-1}" == 1 ]]; then open -g "$DST" && echo "reopened"; fi
