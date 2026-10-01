#!/bin/zsh
# Flowriter: File > Open Recent and the quick recent picker (RecentSelfTest.swift). VM only:
#   $VM_RUN scripts/recent-vm-test.sh
# Copies of Tests/fixtures/recent per appearance (APPEARANCES, default "light dark"): essays/garden.md,
# essays/orchard.md, essays/harvest.md and drafts/garden.md. `recent` runs in the writing space's
# document window on essays/garden.md, then `recent-restart` in a new process on essays/orchard.md
# (the list and the cleared state held). Screenshots recent-menu-<appearance>.png,
# recent-picker-<appearance>.png and recent-picker-filter-<appearance>.png and logs go to ~/flo-out.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-$HOME/flo-out}
mkdir -p "$OUT"
swift build --product FloStateNative 2>&1 | grep -E "error|Build complete" | tail -3
BIN="$(swift build --product FloStateNative --show-bin-path)/FloStateNative"
WORK=$HOME/flo-recent-work
code=0
for look in ${=APPEARANCES:-light dark}; do
  rm -rf "$WORK"; mkdir -p "$WORK/essays" "$WORK/drafts"
  cp Tests/fixtures/recent/garden.md Tests/fixtures/recent/orchard.md Tests/fixtures/recent/harvest.md "$WORK/essays/"
  cp Tests/fixtures/recent/garden-draft.md "$WORK/drafts/garden.md"
  for scenario in recent recent-restart; do
    post=essays/garden.md; [[ $scenario == recent-restart ]] && post=essays/orchard.md
    echo "== $scenario ($look)"
    FLO_SELFTEST_VM=1 FLO_SELFTEST_TIMEOUT=120 FLO_TEST_APPEARANCE=$look "$BIN" --ui-selftest "$scenario" "$WORK/$post" "$OUT" \
      2>"$OUT/$scenario-$look.err.log" | grep -v "^\s*$" > "$OUT/$scenario-$look.log"
    (( ${pipestatus[1]} == 0 )) || code=1
    grep -E "selftest: (FAIL|ALL PASS|FAILED)|Fatal|timeout" "$OUT/$scenario-$look.log"
    echo "   $(grep -c 'selftest: PASS' "$OUT/$scenario-$look.log") checks passed"
  done
  for f in garden orchard harvest; do
    cmp -s Tests/fixtures/recent/$f.md "$WORK/essays/$f.md" || { echo "   $f.md CHANGED on disk"; code=1; }
  done
  cmp -s Tests/fixtures/recent/garden-draft.md "$WORK/drafts/garden.md" || { echo "   drafts/garden.md CHANGED on disk"; code=1; }
  [[ -e "$WORK/essays/ephemeral.md" ]] && { echo "   ephemeral.md left behind"; code=1; }
done
exit $code
