#!/bin/zsh
# Flowriter: fenced code blocks in the writing and reading views (CodeBlockSelfTest.swift). VM only:
#   $VM_RUN scripts/code-blocks-vm-test.sh
# One copy of Tests/fixtures/code-blocks/code.md per appearance (APPEARANCES, default "light dark")
# goes through `code-blocks` in the writing space's document window. The view state uses its own
# defaults suite (FLO_VIEW_DEFAULTS), cleared first. Screenshots code-blocks-*-<appearance>.png and
# logs go to ~/flo-out.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-$HOME/flo-out}
mkdir -p "$OUT"
swift build --product FloStateNative 2>&1 | grep -E "error|Build complete" | tail -3
BIN="$(swift build --product FloStateNative --show-bin-path)/FloStateNative"
WORK=$HOME/flo-code-blocks-work
post=code.md
suite=flowriter-code-blocks-test
code=0
for look in ${=APPEARANCES:-light dark}; do
  rm -rf "$WORK"; mkdir -p "$WORK/posts"
  cp Tests/fixtures/code-blocks/$post "$WORK/posts/$post"
  defaults delete $suite >/dev/null 2>&1
  echo "== code-blocks ($look)"
  FLO_VIEW_DEFAULTS=$suite FLO_SELFTEST_VM=1 FLO_SELFTEST_TIMEOUT=120 FLO_TEST_APPEARANCE=$look "$BIN" --ui-selftest code-blocks "$WORK/posts/$post" "$OUT" \
    2>"$OUT/code-blocks-$look.err.log" | grep -v "^\s*$" > "$OUT/code-blocks-$look.log"
  (( ${pipestatus[1]} == 0 )) || code=1
  grep -E "selftest: (FAIL|ALL PASS|FAILED)|Fatal" "$OUT/code-blocks-$look.log"
  echo "   $(grep -c 'selftest: PASS' "$OUT/code-blocks-$look.log") checks passed"
done
defaults delete $suite >/dev/null 2>&1
exit $code
