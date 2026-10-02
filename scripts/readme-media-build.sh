#!/bin/zsh
# Flowriter: turn the readme-shots output (scripts/readme-media-vm.sh, copied back from the VM)
# into docs/media/. Runs on the Mac, needs only ffmpeg and sips. No windows, no app.
#   scripts/readme-media-build.sh [vm-out/readme-media folder]   (default build/vm-out/readme-media)
# Writes docs/media/flowriter-dark.png, flowriter-light.png, demo.mp4 and, when it stays under
# GIF_MAX bytes (default 6 MB), demo.gif. Review frames go to build/readme-media-review/.
# HERO=all picks the shot with Overflow open too (readme-hero-all-*.png) instead of ghost + Alternatives.
set -euo pipefail
cd "$(dirname "$0")/.."
IN=${1:-build/vm-out/readme-media}
DEST=docs/media
REVIEW=build/readme-media-review
GIF_MAX=${GIF_MAX:-6000000}
HERO=${HERO:-}
mkdir -p "$DEST" "$REVIEW"
find build/readme-media-review -maxdepth 1 -name '*.png' -delete

# 1. hero stills: 8-bit palette PNG (no dither, transparent corners kept), only when smaller
for mode in dark light; do
  src="$IN/readme-hero-${HERO:+$HERO-}$mode.png"
  [[ -f $src ]] || { echo "missing $src"; exit 1; }
  ffmpeg -loglevel error -y -i "$src" -vf "split[a][b];[a]palettegen=max_colors=256:reserve_transparent=1:stats_mode=full[p];[b][p]paletteuse=dither=none:alpha_threshold=128" "$REVIEW/hero-$mode-pal.png"
  if (( $(stat -f %z "$REVIEW/hero-$mode-pal.png") < $(stat -f %z "$src") )); then cp "$REVIEW/hero-$mode-pal.png" "$DEST/flowriter-$mode.png"
  else cp "$src" "$DEST/flowriter-$mode.png"; fi
  echo "flowriter-$mode.png: $(sips -g pixelWidth -g pixelHeight "$DEST/flowriter-$mode.png" | awk '/pixel/{printf "%s ", $2}')px, $(stat -f %z "$DEST/flowriter-$mode.png") bytes (source $(stat -f %z "$src"))"
done

# 2. video: the ScreenCaptureKit .mov, or the app-rendered frames with their real times
if [[ -f $IN/readme-demo.mov ]]; then
  SRC=(-i "$IN/readme-demo.mov")
else
  [[ -f $IN/readme-frames/times.txt ]] || { echo "no readme-demo.mov and no readme-frames/times.txt in $IN"; exit 1; }
  awk 'BEGIN{print "ffconcat version 1.0"} {if (NR>1) printf "duration %.4f\n", $2-t; if ($1!="end") printf "file %s\n", $1; t=$2}' \
    "$IN/readme-frames/times.txt" > "$IN/readme-frames/list.ffconcat"
  SRC=(-f concat -i "$IN/readme-frames/list.ffconcat")
fi
ffmpeg -loglevel error -y "${SRC[@]}" -an -vf "fps=30,scale=1280:-2:flags=lanczos,format=yuv420p" \
  -c:v libx264 -preset slow -crf 24 -tune stillimage -movflags +faststart "$DEST/demo.mp4"
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$DEST/demo.mp4")
echo "demo.mp4: ${dur}s, $(ffprobe -v error -select_streams v -show_entries stream=codec_name,width,height,pix_fmt -of csv=p=0 "$DEST/demo.mp4"), $(stat -f %z "$DEST/demo.mp4") bytes"

# 3. gif: 12 fps, 960 px, one palette for the clip, no dither; kept only under GIF_MAX
ffmpeg -loglevel error -y -i "$DEST/demo.mp4" -vf "fps=12,scale=960:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" "$REVIEW/demo.gif"
gsize=$(stat -f %z "$REVIEW/demo.gif")
if (( gsize <= GIF_MAX )); then cp "$REVIEW/demo.gif" "$DEST/demo.gif"; echo "demo.gif: $gsize bytes (kept)"
else rm -f "$DEST/demo.gif"; echo "demo.gif: $gsize bytes, over $GIF_MAX, not kept (link the mp4)"; fi

# 4. review frames: 8 evenly spaced stills from the mp4, to read before committing
for i in 1 2 3 4 5 6 7 8; do
  t=$(awk -v d="$dur" -v i="$i" 'BEGIN{printf "%.2f", d*(i-0.5)/8}')
  ffmpeg -loglevel error -y -ss "$t" -i "$DEST/demo.mp4" -frames:v 1 "$REVIEW/frame-$i-${t}s.png"
done
ls "$REVIEW"
du -sh "$DEST"
