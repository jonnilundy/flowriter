#!/bin/zsh
# Flowriter: the side panels and the page column (PanelsSelfTest.swift). VM only:
#   $VM_RUN scripts/panels-vm-test.sh
# One copy of Tests/fixtures/combined/pencil-case.md per appearance (APPEARANCES, default
# "light dark"), in the writing space's document window: Alternatives, Overflow
# and both opened and closed in 1280, 1090 and 900 pt windows, typing with both open, the count's
# centre gap. Screenshots polish-<width>-<appearance>.png and logs go to ~/flo-out.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-$HOME/flo-out}
mkdir -p "$OUT"
swift build --product FloStateNative 2>&1 | grep -E "error|Build complete" | tail -3
BIN="$(swift build --product FloStateNative --show-bin-path)/FloStateNative"
WORK=$HOME/flo-panels-work
post=pencil-case.md
code=0
for look in ${=APPEARANCES:-light dark}; do
  rm -rf "$WORK"; mkdir -p "$WORK/posts"
  cp Tests/fixtures/combined/$post "$WORK/posts/$post"
  echo "== panels ($look)"
  FLO_SELFTEST_VM=1 FLO_SELFTEST_TIMEOUT=120 FLO_TEST_APPEARANCE=$look "$BIN" --ui-selftest panels "$WORK/posts/$post" "$OUT" \
    2>"$OUT/panels-$look.err.log" | grep -v "^\s*$" > "$OUT/panels-$look.log"
  (( ${pipestatus[1]} == 0 )) || code=1
  grep -E "selftest: (FAIL|ALL PASS|FAILED)|window [0-9]+:|column moved|Fatal" "$OUT/panels-$look.log"
  echo "   $(grep -c 'selftest: PASS' "$OUT/panels-$look.log") checks passed"
done
exit $code
