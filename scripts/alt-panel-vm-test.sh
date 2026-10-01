#!/bin/zsh
# Flowriter: the Alternatives panel's close paths, its top edge and a click in its empty space
# (AltPanelSelfTest.swift). VM only:
#   $VM_RUN scripts/alt-panel-vm-test.sh
# alt-close and alt-empty-click, each on a fresh copy of Tests/fixtures/combined/pencil-case.md in
# the writing space's document window, once per appearance (APPEARANCES, default "light dark").
# Screenshots alt-panel-<state>-<appearance>.png and logs go to ~/flo-out.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-$HOME/flo-out}
mkdir -p "$OUT"
swift build --product FloStateNative 2>&1 | grep -E "error|Build complete" | tail -3
BIN="$(swift build --product FloStateNative --show-bin-path)/FloStateNative"
WORK=$HOME/flo-alt-panel-work
post=pencil-case.md
code=0
for look in ${=APPEARANCES:-light dark}; do
  for scenario in ${=SCENARIOS:-alt-close alt-empty-click}; do
    rm -rf "$WORK"; mkdir -p "$WORK/posts"
    cp Tests/fixtures/combined/$post "$WORK/posts/$post"
    echo "== $scenario ($look)"
    FLO_SELFTEST_VM=1 FLO_TEST_APPEARANCE=$look "$BIN" --ui-selftest "$scenario" "$WORK/posts/$post" "$OUT" \
      2>"$OUT/$scenario-$look.err.log" | grep -v "^\s*$" > "$OUT/$scenario-$look.log"
    (( ${pipestatus[1]} == 0 )) || code=1
    grep -E "selftest: (FAIL|ALL PASS|FAILED)|Fatal" "$OUT/$scenario-$look.log"
    echo "   $(grep -c 'selftest: PASS' "$OUT/$scenario-$look.log") checks passed"
  done
done
exit $code
