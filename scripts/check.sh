#!/bin/zsh
# The one check before a push: build the app, then run the unit tests.
#
#   scripts/check.sh                 build + whole test suite
#   scripts/check.sh --filter X      build + only matching tests (passed on to test.sh)
#
# The exit code is the failing step's exit code (0 when all pass).
# The last line is always one of:
#   CHECK PASS: TESTS PASS: 405 tests in 70s
#   CHECK FAIL (build): <first error> (log: build/check-build.log)
#   CHECK FAIL (tests): <test.sh summary line>
# Run it as it is. Never pipe it into tail or grep before && (the pipe hides the exit code).
# The pre-push hook (.githooks/pre-push) and CI (.github/workflows/ci.yml) run this script.
setopt no_nomatch
cd "$(dirname "$0")/.."
BP=.build-test
# test.sh stops a test that prints nothing for $STALL s (default 15). Some tests run 13 s quietly on a
# busy Mac, so the check allows 45 s: a slow machine must not block a push. A real hang still stops.
export STALL=${STALL:-45}
LOG=build/check-build.log
mkdir -p build
: > "$LOG"

# 1. build the app (same build folder as test.sh, so the test build is incremental)
[[ -d $BP/artifacts/sparkle/Sparkle/Sparkle.xcframework ]] || scripts/seed-sparkle.sh $BP >> "$LOG" 2>&1
THROTTLE=${THROTTLE-$( (( $+commands[slowbuild] )) && print slowbuild )}
${=THROTTLE} swift build --build-path $BP -j ${JOBS:-8} --product FloStateNative >> "$LOG" 2>&1
code=$?
if (( code )); then
  echo "CHECK FAIL (build): $( { grep -m1 -E ':[0-9]+:[0-9]+: .*error' "$LOG" || grep -m1 -E 'error:' "$LOG"; } | perl -pe 's/\e\[[0-9;]*m//g' | cut -c1-200) (log: $LOG)"
  exit $code
fi

# 2. unit tests (test.sh prints one summary line and exits non-zero on any failure)
summary=$(scripts/test.sh "$@")
code=$?
[[ -n $summary ]] && print -r -- "$summary" | sed '$d'
last=$(print -r -- "$summary" | tail -1)
if (( code )); then
  echo "CHECK FAIL (tests): ${last:-scripts/test.sh exited $code}"
  exit $code
fi
echo "CHECK PASS: $last"
