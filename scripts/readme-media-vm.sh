#!/bin/zsh
# Flowriter: the README hero shots and demo video (scenario readme-shots, ReadmeMediaSelfTest.swift).
# Runs in the test VM only, like the window tests:
#   $VM_RUN scripts/readme-media-vm.sh
# (VM_RUN: your command that runs a shell command inside a macOS test VM, in a copy of this repo.)
# Plays the demo once in dark (with video) and once in light, on a copy of
# Tests/fixtures/readme-media/first-draft.md in a throwaway folder. Output: ~/flo-out/readme-media.
# Then, on the Mac: scripts/readme-media-build.sh <that folder> turns it into docs/media/.
set -uo pipefail
cd "$(dirname "$0")/.."
# Never on a real desktop: the scenario drives a window with synthetic keys.
if [[ "$(sysctl -n kern.hv_vmm_present 2>/dev/null)" != 1 ]]; then
  echo "readme-media-vm: not in a virtual machine, refusing (run it through \$VM_RUN)"; exit 64
fi
OUT=${OUT:-$HOME/flo-out}/readme-media
rm -rf "$OUT"; mkdir -p "$OUT"
swift build --product FloStateNative 2>&1 | grep -E "error|Build complete" | tail -3
BIN="$(swift build --product FloStateNative --show-bin-path)/FloStateNative"
WORK=$(mktemp -d /tmp/flo-readme.XXXXXX)
code=0
for appearance in dark light; do
  rm -rf "$WORK/Drafts"; mkdir -p "$WORK/Drafts"
  cp Tests/fixtures/readme-media/first-draft.md "$WORK/Drafts/first-draft.md"
  video=0; [[ $appearance == dark ]] && video=1
  echo "== readme-shots $appearance (video $video)"
  FLO_SELFTEST_VM=1 FLO_SELFTEST_TIMEOUT=120 FLO_TEST_APPEARANCE=$appearance FLO_README_VIDEO=$video \
    "$BIN" --ui-selftest readme-shots "$WORK/Drafts/first-draft.md" "$OUT" 2>"$OUT/$appearance.err.log" | grep -v "^\s*$" > "$OUT/$appearance.log"
  (( ${pipestatus[1]} == 0 )) || code=1
  grep -E "selftest:|Fatal" "$OUT/$appearance.log"
  cp "$WORK/Drafts/first-draft.md" "$OUT/first-draft-after-$appearance.md"
done
rm -rf "$WORK"
ls -la "$OUT" | head -20
exit $code
