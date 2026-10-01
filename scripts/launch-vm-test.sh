#!/bin/zsh
# Flowriter: the app reopens the last document on launch (one document window, no sidebar).
# VM only: $VM_RUN scripts/launch-vm-test.sh
# Starts the real app on a fresh data dir whose recent files list one post, waits, takes a
# screenshot (~/flo-out/space-launch.png), reads the window title list, and quits the app.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-$HOME/flo-out}; mkdir -p "$OUT"
swift build --product FloStateNative 2>&1 | grep -E "error|Build complete" | tail -1
BIN="$(swift build --product FloStateNative --show-bin-path)/FloStateNative"
D=$HOME/flo-launch-data; W=$HOME/flo-launch-work
rm -rf "$D" "$W"; mkdir -p "$D" "$W"
cp Tests/fixtures/integrity/night-trains.md "$W/"
printf '[{"path": "%s", "opened_at": 1790801250}]\n' "$W/night-trains.md" > "$D/recent_files.json"
printf '["%s"]\n' "$W" > "$D/recent_workspaces.json"
FLO_DATA_DIR=$D "$BIN" > "$OUT/launch.log" 2>&1 &
pid=$!
sleep 4
osascript -e 'tell application "System Events" to get name of every window of (first process whose unix id is '$pid')' 2>&1 | sed 's/^/windows: /'
screencapture -x -t png "$OUT/space-launch.png"
lsof -nP -a -i -p $pid 2>/dev/null | tail -n +2 | sed 's/^/socket: /'
kill $pid; wait $pid 2>/dev/null
cmp -s Tests/fixtures/integrity/night-trains.md "$W/night-trains.md" && echo "post unchanged on disk" || echo "post CHANGED on disk"
