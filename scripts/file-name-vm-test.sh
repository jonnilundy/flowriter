#!/bin/zsh
# Flowriter: the file name at the top left and its save dot (FileNameSelfTest.swift). VM only:
#   $VM_RUN scripts/file-name-vm-test.sh
# One copy of Tests/fixtures/file-name/letter-to-a-friend.md per appearance (APPEARANCES, default
# "light dark"): `file-name` in the writing space's document window, then `file-name-full`
# in a workspace window with tabs. Screenshots file-name-*-<appearance>.png and logs go to ~/flo-out.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-$HOME/flo-out}
mkdir -p "$OUT"
swift build --product FloStateNative 2>&1 | grep -E "error|Build complete" | tail -3
BIN="$(swift build --product FloStateNative --show-bin-path)/FloStateNative"
WORK=$HOME/flo-file-name-work
post=letter-to-a-friend.md
code=0
for look in ${=APPEARANCES:-light dark}; do
  rm -rf "$WORK"; mkdir -p "$WORK/posts"
  cp Tests/fixtures/file-name/$post "$WORK/posts/$post"
  for scenario in file-name file-name-full; do
    echo "== $scenario ($look)"
    FLO_SELFTEST_VM=1 FLO_SELFTEST_TIMEOUT=120 FLO_TEST_APPEARANCE=$look "$BIN" --ui-selftest "$scenario" "$WORK/posts/$post" "$OUT" \
      2>"$OUT/$scenario-$look.err.log" | grep -v "^\s*$" > "$OUT/$scenario-$look.log"
    (( ${pipestatus[1]} == 0 )) || code=1
    grep -E "selftest: (FAIL|ALL PASS|FAILED)|save delay|name: |Fatal|timeout" "$OUT/$scenario-$look.log"
    echo "   $(grep -c 'selftest: PASS' "$OUT/$scenario-$look.log") checks passed"
  done
  chmod -R u+w "$WORK"
  cmp -s Tests/fixtures/file-name/$post "$WORK/posts/$post" && echo "   post unchanged on disk" || { echo "   post CHANGED on disk"; code=1; }
done
exit $code
