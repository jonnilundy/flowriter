#!/bin/zsh
# Flowriter: build and run scripted window tests on one post. Runs in the test VM only:
#   $VM_RUN 'scripts/ui-vm-test.sh roundtrip ghost restart-ghost'
# (VM_RUN: your command that runs a shell command inside a macOS test VM, in a copy of this repo.
# The window tests open real windows and drive them; never run them on your own desktop.)
# Scenarios (--ui-selftest, SelfTestRunner.swift and the *SelfTest.swift files): roundtrip, ghost,
# restart-ghost (right after ghost), overflow, restart-overflow, overflow-typing,
# restart-overflow-typing, overflow-shots. A restart-* scenario reuses the files the one before it saved.
# The post is a copy of Tests/fixtures/integrity/workshop.md. Screenshots and logs go to ~/flo-out.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-$HOME/flo-out}
mkdir -p "$OUT"
swift build --product FloStateNative 2>&1 | grep -E "error|Build complete" | tail -3
BIN="$(swift build --product FloStateNative --show-bin-path)/FloStateNative"
WORK=$HOME/flo-ui-work
post=workshop.md
code=0
for scenario in "${@:-roundtrip}"; do
  if [[ $scenario != restart* ]]; then
    rm -rf "$WORK"; mkdir -p "$WORK/posts"
    cp Tests/fixtures/integrity/$post "$WORK/posts/$post"
  fi
  echo "== $scenario"
  FLO_SELFTEST_VM=1 "$BIN" --ui-selftest "$scenario" "$WORK/posts/$post" "$OUT" 2>"$OUT/$scenario.err.log" | grep -v "^\s*$" > "$OUT/$scenario.log"
  (( ${pipestatus[1]} == 0 )) || code=1
  grep -E "selftest:|Fatal" "$OUT/$scenario.log"
  if [[ $scenario == roundtrip ]]; then
    cmp Tests/fixtures/integrity/$post "$WORK/posts/$post" && echo "cmp: identical ($(wc -c < "$WORK/posts/$post" | tr -d ' ') bytes)" || { echo "cmp: DIFFERENT"; code=1; }
  fi
done
exit $code
