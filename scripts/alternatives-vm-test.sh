#!/bin/zsh
# Flowriter: Alternatives window tests. Runs in the test VM only:
#   $VM_RUN 'scripts/alternatives-vm-test.sh'
# One copy of Tests/fixtures/alternatives/pencil-case.md goes through alt-word, alt-sentence,
# alt-paragraph and alt-reopen (each a new app process on the files the previous one saved),
# once per appearance (APPEARANCES, default "light dark").
# Screenshots alternatives-<name>-<appearance>.png and logs go to ~/flo-out.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-$HOME/flo-out}
mkdir -p "$OUT"
swift build --product FloStateNative 2>&1 | grep -E "error|Build complete" | tail -3
BIN="$(swift build --product FloStateNative --show-bin-path)/FloStateNative"
WORK=$HOME/flo-alt-work
post=pencil-case.md
code=0
for look in ${=APPEARANCES:-light dark}; do
  rm -rf "$WORK"; mkdir -p "$WORK/posts"
  cp Tests/fixtures/alternatives/$post "$WORK/posts/$post"
  for scenario in ${=SCENARIOS:-alt-word alt-sentence alt-paragraph alt-reopen}; do
    echo "== $scenario ($look)"
    FLO_SELFTEST_VM=1 FLO_TEST_APPEARANCE=$look "$BIN" --ui-selftest "$scenario" "$WORK/posts/$post" "$OUT" \
      2>"$OUT/$scenario-$look.err.log" | grep -v "^\s*$" > "$OUT/$scenario-$look.log"
    (( ${pipestatus[1]} == 0 )) || code=1
    grep -E "selftest:|Fatal" "$OUT/$scenario-$look.log"
  done
  cp "$WORK/posts/$post" "$OUT/final-$look.md"
  cp "$WORK/posts/.$post.flowriter.json" "$OUT/final-$look.flowriter.json" 2>/dev/null
done
exit $code
