#!/bin/zsh
# Flowriter: the writing space works offline. VM only:
#   $VM_RUN scripts/quiet-vm-test.sh
# Runs --ui-selftest quiet (types into a post; no AI items in the menus) and samples the process's
# sockets from outside every 0.2 s (lsof): any socket fails the run. Also fails when the app binary
# imports a Security framework item or key function (SecItem*, SecKey*): the app stores no secrets.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-$HOME/flo-out}
mkdir -p "$OUT"
swift build --product FloStateNative 2>&1 | grep -E "error|Build complete" | tail -3
BIN="$(swift build --product FloStateNative --show-bin-path)/FloStateNative"
WORK=$HOME/flo-quiet-work
rm -rf "$WORK"; mkdir -p "$WORK/posts"
cp Tests/fixtures/integrity/workshop.md "$WORK/posts/"
code=0
secrets=$(nm -u "$BIN" 2>/dev/null | grep -E '^_Sec(Item|Key)' | sort -u)
if [[ -n $secrets ]]; then echo "secret storage calls in the binary:"; print -r -- "$secrets"; code=1
else echo "secret storage calls in the binary: none"; fi
FLO_SELFTEST_DATA_SUFFIX=-quiet FLO_SELFTEST_VM=1 "$BIN" --ui-selftest quiet "$WORK/posts/workshop.md" "$OUT" > "$OUT/quiet.log" 2>"$OUT/quiet.err.log" &
pid=$!
: > "$OUT/quiet.sockets"
samples=0
while kill -0 $pid 2>/dev/null; do
  lsof -nP -a -i -p $pid 2>/dev/null | tail -n +2 >> "$OUT/quiet.sockets"
  samples=$((samples + 1))
  sleep 0.2
done
wait $pid || code=1
grep -E "selftest:" "$OUT/quiet.log" | sed 's/selftest: //'
n=$(wc -l < "$OUT/quiet.sockets" | tr -d ' ')
echo "sockets seen in $samples lsof samples: $n"
[[ $n == 0 ]] || { cat "$OUT/quiet.sockets" | sort -u; code=1; }
exit $code
