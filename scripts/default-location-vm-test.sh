#!/bin/zsh
# Flowriter: the default location for new notes (DefaultLocationSelfTest.swift). VM only:
#   $VM_RUN scripts/default-location-vm-test.sh
# One copy of Tests/fixtures/file-name/letter-to-a-friend.md per appearance (APPEARANCES, default
# "light dark"): `default-location` in the writing space's document window, then `default-location-full`
# in a workspace window. The default folder is a sibling of the post's folder. Screenshots
# default-location-*-<appearance>.png and logs go to ~/flo-out.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-$HOME/flo-out}
mkdir -p "$OUT"
swift build --product FloStateNative 2>&1 | grep -E "error|Build complete" | tail -3
BIN="$(swift build --product FloStateNative --show-bin-path)/FloStateNative"
WORK=$HOME/flo-default-location-work
post=letter-to-a-friend.md
code=0
for look in ${=APPEARANCES:-light dark}; do
  for scenario in default-location default-location-full; do
    rm -rf "$WORK"; mkdir -p "$WORK/posts"
    cp Tests/fixtures/file-name/$post "$WORK/posts/$post"
    echo "== $scenario ($look)"
    FLO_SELFTEST_VM=1 FLO_SELFTEST_TIMEOUT=120 FLO_TEST_APPEARANCE=$look "$BIN" --ui-selftest "$scenario" "$WORK/posts/$post" "$OUT" \
      2>"$OUT/$scenario-$look.err.log" | grep -v "^\s*$" > "$OUT/$scenario-$look.log"
    (( ${pipestatus[1]} == 0 )) || code=1
    grep -E "selftest: (FAIL|ALL PASS|FAILED)|Fatal|timeout" "$OUT/$scenario-$look.log"
    echo "   $(grep -c 'selftest: PASS' "$OUT/$scenario-$look.log") checks passed"
    chmod -R u+w "$WORK"
    cmp -s Tests/fixtures/file-name/$post "$WORK/posts/$post" && echo "   post unchanged on disk" || { echo "   post CHANGED on disk"; code=1; }
  done
done
exit $code
