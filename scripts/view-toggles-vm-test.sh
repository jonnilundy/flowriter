#!/bin/zsh
# Flowriter: the view toggles (ViewTogglesSelfTest.swift). VM only:
#   $VM_RUN scripts/view-toggles-vm-test.sh
# One copy of Tests/fixtures/view-toggles/marks.md per appearance (APPEARANCES, default "light dark")
# goes through `view-toggles` then `restart-view-toggles` (a new process: the states persist), in the
# writing space's document window. The view states use their own defaults suite
# (FLO_VIEW_DEFAULTS), cleared first. Screenshots view-toggles-*-<appearance>.png and logs go to ~/flo-out.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-$HOME/flo-out}
mkdir -p "$OUT"
swift build --product FloStateNative 2>&1 | grep -E "error|Build complete" | tail -3
BIN="$(swift build --product FloStateNative --show-bin-path)/FloStateNative"
WORK=$HOME/flo-view-toggles-work
post=marks.md
suite=flowriter-view-toggles-test
code=0
for look in ${=APPEARANCES:-light dark}; do
  rm -rf "$WORK"; mkdir -p "$WORK/posts"
  cp Tests/fixtures/view-toggles/$post "$WORK/posts/$post"
  defaults delete $suite >/dev/null 2>&1
  for scenario in view-toggles restart-view-toggles; do
    echo "== $scenario ($look)"
    FLO_VIEW_DEFAULTS=$suite FLO_SELFTEST_VM=1 FLO_SELFTEST_TIMEOUT=120 FLO_TEST_APPEARANCE=$look "$BIN" --ui-selftest "$scenario" "$WORK/posts/$post" "$OUT" \
      2>"$OUT/$scenario-$look.err.log" | grep -v "^\s*$" > "$OUT/$scenario-$look.log"
    (( ${pipestatus[1]} == 0 )) || code=1
    grep -E "selftest: (FAIL|ALL PASS|FAILED)|toggles:|Fatal" "$OUT/$scenario-$look.log"
    echo "   $(grep -c 'selftest: PASS' "$OUT/$scenario-$look.log") checks passed"
  done
  cmp -s Tests/fixtures/view-toggles/$post "$WORK/posts/$post" && echo "   post unchanged on disk" || { echo "   post CHANGED on disk"; code=1; }
done
defaults delete $suite >/dev/null 2>&1
exit $code
