#!/bin/zsh
# Flowriter: the word count is the writing tools switch (ToolsSwitchSelfTest.swift). VM only:
#   $VM_RUN scripts/tools-vm-test.sh
# One copy of Tests/fixtures/combined/pencil-case.md goes through `tools` (first launch: the stored
# switch is removed), `restart-tools` and `restart-tools-off` (each a new process on what the one
# before saved), once per appearance (APPEARANCES, default "light dark"), in the writing space's
# document window. Then `tools-shots` on a fresh copy (the merged look: off, on,
# reading view, both panels). The view toggles use their own defaults suite (FLO_VIEW_DEFAULTS).
# Screenshots tools-switch-<state>-<appearance>.png, tools-shots-<state>-<appearance>.png and logs go to ~/flo-out.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-$HOME/flo-out}
mkdir -p "$OUT"
swift build --product FloStateNative 2>&1 | grep -E "error|Build complete" | tail -3
BIN="$(swift build --product FloStateNative --show-bin-path)/FloStateNative"
WORK=$HOME/flo-tools-work
post=pencil-case.md
suite=flowriter-tools-test
code=0
for look in ${=APPEARANCES:-light dark}; do
  rm -rf "$WORK"; mkdir -p "$WORK/posts"
  cp Tests/fixtures/combined/$post "$WORK/posts/$post"
  defaults delete $suite >/dev/null 2>&1
  for scenario in tools restart-tools restart-tools-off tools-shots; do
    if [[ $scenario == tools-shots ]]; then rm -rf "$WORK"; mkdir -p "$WORK/posts"; cp Tests/fixtures/combined/$post "$WORK/posts/$post"; fi
    echo "== $scenario ($look)"
    FLO_VIEW_DEFAULTS=$suite FLO_SELFTEST_VM=1 FLO_TEST_APPEARANCE=$look "$BIN" --ui-selftest "$scenario" "$WORK/posts/$post" "$OUT" \
      2>"$OUT/$scenario-$look.err.log" | grep -v "^\s*$" > "$OUT/$scenario-$look.log"
    (( ${pipestatus[1]} == 0 )) || code=1
    grep -E "selftest: (FAIL|ALL PASS|FAILED)|Fatal" "$OUT/$scenario-$look.log"
    echo "   $(grep -c 'selftest: PASS' "$OUT/$scenario-$look.log") checks passed"
  done
done
defaults delete $suite >/dev/null 2>&1
exit $code
