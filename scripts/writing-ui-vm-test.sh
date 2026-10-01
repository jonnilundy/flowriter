#!/bin/zsh
# Flowriter: the right-click menu, Revive and the shortcut line (WritingMenuSelfTest.swift, ReviveClickSelfTest.swift,
# HintsSelfTest.swift). VM only:
#   $VM_RUN scripts/writing-ui-vm-test.sh
# One copy of Tests/fixtures/combined/pencil-case.md per appearance (APPEARANCES, default
# "light dark"), in the writing space's document window: `writing-menu`, `revive-click`, then
# `hints` (ends with the line turned off) and `hints-restart` (a new process: the stored setting
# holds, then it is turned back on). Screenshots hints-menu-<appearance>.png and
# hints-strip-<appearance>.png and logs go to ~/flo-out.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-$HOME/flo-out}
mkdir -p "$OUT"
swift build --product FloStateNative 2>&1 | grep -E "error|Build complete" | tail -3
BIN="$(swift build --product FloStateNative --show-bin-path)/FloStateNative"
WORK=$HOME/flo-writing-ui-work
post=pencil-case.md
code=0
for look in ${=APPEARANCES:-light dark}; do
  for scenario in writing-menu revive-click hints hints-restart; do
    [[ $scenario == hints-restart ]] || { rm -rf "$WORK"; mkdir -p "$WORK/posts"; cp Tests/fixtures/combined/$post "$WORK/posts/$post"; }
    echo "== $scenario ($look)"
    FLO_SELFTEST_VM=1 FLO_SELFTEST_TIMEOUT=120 FLO_TEST_APPEARANCE=$look "$BIN" --ui-selftest "$scenario" "$WORK/posts/$post" "$OUT" \
      2>"$OUT/$scenario-$look.err.log" | grep -v "^\s*$" > "$OUT/$scenario-$look.log"
    (( ${pipestatus[1]} == 0 )) || code=1
    grep -E "selftest: (FAIL|ALL PASS|FAILED)|Fatal|timeout" "$OUT/$scenario-$look.log"
    echo "   $(grep -c 'selftest: PASS' "$OUT/$scenario-$look.log") checks passed"
  done
done
# whatever happened above, leave the line on for the other suites
defaults write FloStateNative FlowriterShortcutHints -bool true 2>/dev/null
exit $code
