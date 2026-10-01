#!/bin/zsh
# Flowriter: every window suite in one go, in the test VM only:
#   $VM_RUN scripts/all-vm-suites.sh
# (VM_RUN: your command that runs a shell command inside a macOS test VM, in a copy of this repo.
# The suites open real windows and drive them; never run them on your own desktop.)
#   ... 'scripts/all-vm-suites.sh --all'                 run every suite even after a FAIL
#   ... 'scripts/all-vm-suites.sh quiet launch'          only these suites (names below, perf too)
#   ... 'SUITE_TIMEOUT=120 scripts/all-vm-suites.sh'     per-suite time limit in seconds (default 600)
# integrity (light + dark), quiet, launch, ghost + restart-ghost (light, dark), alternatives
# (light, dark), overflow + restart-overflow + overflow-typing
# + restart-overflow-typing + overflow-shots (light, dark), combined + restart-combined
# (light, dark), panels (light, dark), writing-ui (light, dark),
# integrity-reading (the integrity suite in the reading view), view-toggles + restart-view-toggles
# (light, dark), tools (light, dark), selection-bar (light, dark), file-name (light, dark), default-location (light, dark), recent (light, dark), then --perf with and without the writing
# features. Each suite's summary lines stream live (indented; LIVE=all for every line) and its whole
# output goes to ~/flo-out/suite-<name>.txt.
# The run stops at the first failed suite (the rest are listed as SKIP) unless --all is given.
# A suite that runs past SUITE_TIMEOUT is killed with its whole process tree (the apps included) and
# counts as FAIL (timeout). After each suite a "#### <name>: ..." line is printed: vm-run-flo.sh copies
# ~/flo-out back to the Mac on that line. The summary at the end lists PASS, FAIL or SKIP per suite.
# Exit 1 on any FAIL.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-$HOME/flo-out}; mkdir -p "$OUT"
ALL=${ALL:-0}
[[ ${1:-} == --all ]] && { ALL=1; shift }
only=("$@")
SUITE_TIMEOUT=${SUITE_TIMEOUT:-600}
# the lines streamed live (LIVE=all streams every line; the suite file always has all of them)
SHOW='FAIL|secret storage|save delay|jumps|ALL PASS|FAILED|sockets seen|post (un)?changed|windows:|socket:|== |TIMEOUT|Fatal|error|timeout|checks passed'
swift build --product FloStateNative 2>&1 | grep -E "error|Build complete" | tail -3
BIN="$(swift build --product FloStateNative --show-bin-path)/FloStateNative"
summary=()
code=0
stopped=0

# every pid in the tree under $1 (collected before any kill, so nothing is reparented in between)
tree() {
  ps -ax -o pid=,ppid= | awk -v root=$1 '{ kids[$2] = kids[$2] " " $1 }
    END { out = root; q = root; while (q != "") { n = split(q, a, " "); q = ""
      for (i = 1; i <= n; i++) { m = split(kids[a[i]], k, " "); for (j = 1; j <= m; j++) { out = out " " k[j]; q = q " " k[j] } } }
      print out }'
}
kill_tree() {
  local pids=($(tree $1))
  kill -STOP $pids 2>/dev/null; kill -TERM $pids 2>/dev/null; kill -CONT $pids 2>/dev/null
  sleep 2; kill -KILL $pids 2>/dev/null
  return 0
}

# timed <seconds> <log> <cmd...>: run cmd, stream its output indented and into <log>; past the
# time limit kill its process tree. Returns cmd's exit code, 124 on timeout.
timed() {
  local limit=$1 log=$2; shift 2
  local fifo=$OUT/.suite-fifo flag=$OUT/.suite-timeout
  rm -f $fifo $flag; mkfifo $fifo
  { tee "$log" < $fifo | while IFS= read -r l || [[ -n $l ]]; do
      [[ ${LIVE:-short} == all || ( $l =~ $SHOW && ! $l =~ "selftest: PASS" ) ]] && print -r -- "   $l"
    done } &
  local streamer=$!
  "$@" > $fifo 2>&1 &
  local pid=$!
  {
    local t=0
    while kill -0 $pid 2>/dev/null; do
      if (( t >= limit * 2 )); then
        print "   TIMEOUT: still running after ${limit} s, killing it"
        touch $flag; kill_tree $pid; pkill -KILL -x FloStateNative 2>/dev/null
        break
      fi
      sleep 0.5; (( t++ ))
    done
  } &
  local watch=$!
  wait $pid; local rc=$?
  wait $watch 2>/dev/null
  # a process that escaped the tree could keep the fifo open: give the stream 5 s, then cut it
  local i=0
  while kill -0 $streamer 2>/dev/null && (( i++ < 50 )); do sleep 0.1; done
  kill $streamer 2>/dev/null; wait $streamer 2>/dev/null
  rm -f $fifo
  [[ -e $flag ]] && { rm -f $flag; return 124 }
  return $rc
}

suite() {
  local name=$1; shift
  if (( ${#only} )) && (( ! ${only[(Ie)$name]} )); then return; fi
  if (( stopped )); then summary+=("SKIP $name"); return; fi
  echo "== suite $name"
  local t0=$(date +%s)
  timed $SUITE_TIMEOUT "$OUT/suite-$name.txt" "$@"
  local rc=$? t=$(( $(date +%s) - t0 ))
  if (( rc == 0 )); then summary+=("PASS $name (${t}s)")
  elif (( rc == 124 )); then summary+=("FAIL $name (${t}s, timeout after ${SUITE_TIMEOUT}s)"); code=1
  else summary+=("FAIL $name (${t}s, exit $rc)"); code=1; fi
  (( rc != 0 && ! ALL )) && stopped=1
  echo "#### $name: exit $rc, ${t}s"
}
suite integrity scripts/integrity-vm-test.sh
suite integrity-reading env SCENARIO=integrity-reading scripts/integrity-vm-test.sh
suite quiet scripts/quiet-vm-test.sh
suite launch zsh -c 'scripts/launch-vm-test.sh | tee /dev/stderr | grep -q "post unchanged on disk"'
suite ghost-light env FLO_TEST_APPEARANCE=light scripts/ui-vm-test.sh ghost restart-ghost
suite ghost-dark env FLO_TEST_APPEARANCE=dark scripts/ui-vm-test.sh ghost restart-ghost
suite alternatives scripts/alternatives-vm-test.sh
suite overflow scripts/ui-vm-test.sh overflow restart-overflow overflow-typing restart-overflow-typing
suite overflow-shots-light env FLO_TEST_APPEARANCE=light scripts/ui-vm-test.sh overflow-shots
suite overflow-shots-dark env FLO_TEST_APPEARANCE=dark scripts/ui-vm-test.sh overflow-shots
suite combined scripts/combined-vm-test.sh
suite panels scripts/panels-vm-test.sh
suite writing-ui scripts/writing-ui-vm-test.sh
suite view-toggles scripts/view-toggles-vm-test.sh
suite tools scripts/tools-vm-test.sh
suite selection-bar scripts/selection-bar-vm-test.sh
suite file-name scripts/file-name-vm-test.sh
suite default-location scripts/default-location-vm-test.sh
suite recent scripts/recent-vm-test.sh
if (( ! stopped )) && { (( ! ${#only} )) || (( ${only[(Ie)perf]} )) }; then
  echo "== perf"
  LIVE=all timed $SUITE_TIMEOUT "$OUT/perf-plain.txt" "$BIN" --perf Tests/fixtures/integrity/workshop.md
  LIVE=all timed $SUITE_TIMEOUT "$OUT/perf-writing.txt" "$BIN" --perf Tests/fixtures/integrity/workshop.md --writing
  echo "#### perf"
fi
echo "#### summary"
printf '%s\n' "${summary[@]}"
exit $code
