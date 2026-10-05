#!/bin/zsh
# Put the Sparkle binary artifact into a SwiftPM build folder by hand.
#
#   scripts/seed-sparkle.sh <build-dir>      e.g. .build-test, .build-release, /tmp/fw-build
#
# Why: on some Macs (iris-agi) SwiftPM hangs forever at "Downloading binary artifact
# .../Sparkle-for-Swift-Package-Manager.zip", while curl gets the same zip in a second.
# This script downloads the zip with curl, checks its sha256, unzips it where SwiftPM
# expects it, and records it in <build-dir>/workspace-state.json. SwiftPM then skips
# the download. It does nothing when the artifact is already there.
# test.sh and bundle.sh call it when the artifact is missing.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

(( $# == 1 )) || { echo "usage: scripts/seed-sparkle.sh <build-dir>" >&2; exit 2; }
BUILD=$1
[[ $BUILD == /* ]] || BUILD=$ROOT/$BUILD

# The version comes from Package.resolved. The checksum is the one Sparkle's own
# Package.swift declares for that version. Bump both when Sparkle is bumped.
VERSION=$(/usr/bin/python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(next(p["state"]["version"] for p in d["pins"] if p["identity"]=="sparkle"))' "$ROOT/Package.resolved")
case $VERSION in
  2.10.0) SHA=17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959 ;;
  *) echo "seed-sparkle: no checksum known for Sparkle $VERSION. Add it to this script." >&2; exit 1 ;;
esac
URL="https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-for-Swift-Package-Manager.zip"
DEST="$BUILD/artifacts/sparkle/Sparkle"
XCF="$DEST/Sparkle.xcframework"
STATE="$BUILD/workspace-state.json"

recorded() {
  [[ -f $STATE ]] && /usr/bin/python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if any(a.get("path")==sys.argv[2] for a in d["object"].get("artifacts",[])) else 1)' "$STATE" "$XCF"
}

if [[ -d $XCF ]] && recorded; then
  echo "seed-sparkle: Sparkle $VERSION already in $BUILD"
  exit 0
fi

# 1. download once per version into a cache, check the checksum
CACHE=${XDG_CACHE_HOME:-$HOME/Library/Caches}/flowriter
ZIP=$CACHE/Sparkle-$VERSION-spm.zip
mkdir -p "$CACHE"
if [[ ! -f $ZIP ]] || [[ $(shasum -a 256 "$ZIP" | cut -d' ' -f1) != "$SHA" ]]; then
  curl -fsSL --retry 3 --max-time 120 -o "$ZIP.part" "$URL"
  mv "$ZIP.part" "$ZIP"
fi
GOT=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
if [[ $GOT != "$SHA" ]]; then
  rm -f "$ZIP"
  echo "seed-sparkle: checksum mismatch for $URL (got $GOT, want $SHA)" >&2
  exit 1
fi

# 2. unzip where SwiftPM looks for it
rm -rf "$DEST"
mkdir -p "$DEST"
ditto -x -k "$ZIP" "$DEST"
[[ -d $XCF ]] || { echo "seed-sparkle: $XCF missing after unzip" >&2; exit 1; }

# 3. record it in workspace-state.json (a new state file when the folder is new)
/usr/bin/python3 - "$STATE" "$XCF" "$URL" "$SHA" <<'PY'
import json, os, sys
state, path, url, sha = sys.argv[1:]
if os.path.exists(state):
    d = json.load(open(state))
else:
    d = {"object": {"artifacts": [], "dependencies": [], "prebuilts": []}, "version": 7}
obj = d.setdefault("object", {})
arts = [a for a in obj.get("artifacts", []) if a.get("targetName") != "Sparkle"]
arts.append({
    "kind": {"xcframework": {}},
    "packageRef": {
        "identity": "sparkle",
        "kind": "remoteSourceControl",
        "location": "https://github.com/sparkle-project/Sparkle",
        "name": "Sparkle",
    },
    "path": path,
    "source": {"checksum": sha, "type": "remote", "url": url},
    "targetName": "Sparkle",
})
obj["artifacts"] = arts
os.makedirs(os.path.dirname(state), exist_ok=True)
json.dump(d, open(state, "w"), indent=2)
PY
echo "seed-sparkle: seeded Sparkle $VERSION into $BUILD"
