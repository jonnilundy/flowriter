#!/bin/zsh
# Flowriter: ghost, alternatives and overflow together on one post (CombinedSelfTest.swift). VM only:
#   $VM_RUN scripts/combined-vm-test.sh
# One copy of Tests/fixtures/combined/pencil-case.md goes through `combined` then `restart-combined`
# (a new process on the files the first one saved), once per appearance (APPEARANCES, default
# "light dark"), in the writing space's document window. Screenshots
# merged-<appearance>.png and merged-restarted-<appearance>.png, logs and the final files go to ~/flo-out.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-$HOME/flo-out}
mkdir -p "$OUT"
swift build --product FloStateNative 2>&1 | grep -E "error|Build complete" | tail -3
BIN="$(swift build --product FloStateNative --show-bin-path)/FloStateNative"
WORK=$HOME/flo-combined-work
post=pencil-case.md
code=0
for look in ${=APPEARANCES:-light dark}; do
  rm -rf "$WORK"; mkdir -p "$WORK/posts"
  cp Tests/fixtures/combined/$post "$WORK/posts/$post"
  for scenario in combined restart-combined; do
    echo "== $scenario ($look)"
    FLO_SELFTEST_VM=1 FLO_TEST_APPEARANCE=$look "$BIN" --ui-selftest "$scenario" "$WORK/posts/$post" "$OUT" \
      2>"$OUT/$scenario-$look.err.log" | grep -v "^\s*$" > "$OUT/$scenario-$look.log"
    (( ${pipestatus[1]} == 0 )) || code=1
    grep -E "selftest: (FAIL|ALL PASS|FAILED)|Fatal" "$OUT/$scenario-$look.log"
    echo "   $(grep -c 'selftest: PASS' "$OUT/$scenario-$look.log") checks passed"
  done
  cp "$WORK/posts/$post" "$OUT/combined-final-$look.md"
  cp "$WORK/posts/.$post.flowriter.json" "$OUT/combined-final-$look.flowriter.json" 2>/dev/null
done
exit $code
