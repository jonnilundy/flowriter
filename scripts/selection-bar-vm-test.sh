#!/bin/zsh
# Flowriter: the selection bar (SelectionBarSelfTest.swift). VM only:
#   $VM_RUN scripts/selection-bar-vm-test.sh
# One copy of Tests/fixtures/selection-bar/notebook.md per appearance (APPEARANCES, default
# "light dark") goes through the `selection-bar` scenario in the writing space's document window.
# Screenshots selection-bar-*-<appearance>.png and logs go to ~/flo-out.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-$HOME/flo-out}
mkdir -p "$OUT"
swift build --product FloStateNative 2>&1 | grep -E "error|Build complete" | tail -3
BIN="$(swift build --product FloStateNative --show-bin-path)/FloStateNative"
WORK=$HOME/flo-selection-bar-work
post=notebook.md
code=0
for look in ${=APPEARANCES:-light dark}; do
  rm -rf "$WORK"; mkdir -p "$WORK/posts"
  cp Tests/fixtures/selection-bar/$post "$WORK/posts/$post"
  echo "== selection-bar ($look)"
  FLO_SELFTEST_VM=1 FLO_SELFTEST_TIMEOUT=120 FLO_TEST_APPEARANCE=$look "$BIN" --ui-selftest selection-bar "$WORK/posts/$post" "$OUT" \
    2>"$OUT/selection-bar-$look.err.log" | grep -v "^\s*$" > "$OUT/selection-bar-$look.log"
  (( ${pipestatus[1]} == 0 )) || code=1
  grep -E "selftest: (FAIL|ALL PASS|FAILED)|Fatal" "$OUT/selection-bar-$look.log"
  echo "   $(grep -c 'selftest: PASS' "$OUT/selection-bar-$look.log") checks passed"
done
exit $code
