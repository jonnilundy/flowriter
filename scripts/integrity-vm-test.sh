#!/bin/zsh
# Flowriter: UI integrity suite (IntegritySelfTest.swift). Runs in the test VM only:
#   $VM_RUN scripts/integrity-vm-test.sh
#   ... 'scripts/integrity-vm-test.sh workshop'             one post (fixture name without .md)
#   ... 'APPEARANCES=dark scripts/integrity-vm-test.sh'      one appearance
# Every fixture post in Tests/fixtures/integrity, in light and dark: the real window is driven in
# process (typing, Return, arrows, clicks, formatting, block prefixes, paste, undo/redo, scroll) and
# every layout change the edit did not cause is printed as a jump. Exit 1 on any jump.
# SCENARIO=space takes the writing-space screenshots (space-<post>-<appearance>.png) instead.
# SCENARIO=integrity-reading runs the same script in the reading view (ViewTogglesSelfTest.swift);
# its logs and screenshots are named integrity-reading-<post>-<appearance>.
# FLO_INTEGRITY_REPORT_ONLY=1 prints the jumps but exits 0 (baseline runs).
# Logs and screenshots go to ~/flo-out (copied back to the Mac by vm-run-flo.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-$HOME/flo-out}
mkdir -p "$OUT"
start=$(date +%s)
swift build --product FloStateNative 2>&1 | grep -E "error|Build complete" | tail -3
built=$(date +%s)
BIN="$(swift build --product FloStateNative --show-bin-path)/FloStateNative"
WORK=$HOME/flo-integrity-work
posts=("$@")
(( ${#posts} )) || posts=(Tests/fixtures/integrity/*.md(:t:r))
# every post in every appearance runs side by side (separate processes with their own work and data
# folders, events go straight to each window, so they do not share focus); the pasted text is the
# same in every run. SERIAL=1 runs one appearance at a time (the old way, half as many windows).
run_one() {
  local post=$1 appearance=$2 work="$WORK-$1-$2"
  # each run keeps the view toggles in its own defaults suite (writing view unless the scenario switches)
  defaults delete flowriter-integrity-$post-$appearance >/dev/null 2>&1
  rm -rf "$work"; mkdir -p "$work/posts"
  cp "Tests/fixtures/integrity/$post.md" "$work/posts/$post.md"
  FLO_VIEW_DEFAULTS=flowriter-integrity-$post-$appearance FLO_SELFTEST_DATA_SUFFIX=-$post-$appearance FLO_SELFTEST_VM=1 FLO_SELFTEST_TIMEOUT=150 FLO_TEST_APPEARANCE=$appearance "$BIN" --ui-selftest ${SCENARIO:-integrity} "$work/posts/$post.md" "$OUT" \
    2>"$OUT/$TAG-$post-$appearance.err.log" | grep -v "^\s*$" > "$OUT/$TAG-$post-$appearance.log"
  return ${pipestatus[1]}
}
TAG=integrity
[[ ${SCENARIO:-integrity} == integrity-reading ]] && TAG=integrity-reading
code=0
looks=(${=APPEARANCES:-light dark})
if [[ ${SERIAL:-0} == 1 ]]; then groups=($looks); else groups=("$looks"); fi
for group in $groups; do
  pids=()
  for appearance in ${=group}; do
    for post in $posts; do run_one $post $appearance & pids+=($!); done
  done
  for pid in $pids; do wait $pid || code=1; done
  for appearance in ${=group}; do for post in $posts; do
    log="$OUT/$TAG-$post-$appearance.log"
    echo "== $post ($appearance): $(grep -E 'integrity: [0-9]+ jumps|ALL PASS|FAILED' "$log" | sed 's/selftest: integrity: //; s/selftest: //' | head -1)"
    grep -E "selftest: (FAIL|integrity: action)|Fatal|timeout" "$log" | sed 's/selftest: //'
    [[ ${SCENARIO:-integrity} == space ]] && grep -E "selftest: (PASS|column|colours)" "$log" | sed 's/selftest: //'
  done; done
done
echo "integrity suite: build $((built - start)) s, runs $(( $(date +%s) - built )) s"
exit $code
