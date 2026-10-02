# README media

The hero images and the demo video in the main README come from a scripted run of the
real app in a macOS virtual machine. Nothing is drawn by hand, and nothing runs on a
real desktop.

| File | What |
|---|---|
| `flowriter-dark.png`, `flowriter-light.png` | The window (1320 x 860 pt at 2x) with a ghosted line and the Alternatives panel open on a word. |
| `demo.mp4` | The demo flow, 1280 px wide, H.264, no audio. |
| `demo.gif` | The same flow as a GIF, only when it stays under 6 MB. |

## Regenerate

1. Run the scenario in the VM. `VM_RUN` is any command that runs a shell command inside
   the VM, in a copy of this repo (see Testing in the main README):

   ```sh
   $VM_RUN scripts/readme-media-vm.sh
   ```

   It plays the flow twice, dark (with video) and light, and writes to
   `~/flo-out/readme-media` in the VM. Copy that folder back to
   `build/vm-out/readme-media` on the Mac (the usual VM runner does this).

2. Build the files on the Mac (ffmpeg and sips only, no app, no windows):

   ```sh
   scripts/readme-media-build.sh                  # reads build/vm-out/readme-media
   HERO=all scripts/readme-media-build.sh         # hero with the Overflow panel open too
   ```

3. Read every file before you commit: the two PNGs and the eight stills in
   `build/readme-media-review/`. Look for anything that is not the sample text, a wrong
   theme, cut off panels, and blank areas.

## What the scenario does

`readme-shots` (`Sources/FloStateNative/App/ReadmeMediaSelfTest.swift`) opens a copy of
`Tests/fixtures/readme-media/first-draft.md` in the writing space and drives it with
real key events through the self test path: the window's key monitor, then the window.

1. Types a new line at the end of the document.
2. Selects it (⇧⌘←) and ghosts it (⌥G).
3. Selects a word, opens Alternatives (⌥A), adds two versions and steps through them.
4. Clicks back into the page. Still: `readme-hero-<appearance>.png`.
5. Opens Overflow (⌥O) and stashes a sentence into it (⌘K, then `s`).
   Still: `readme-hero-all-<appearance>.png`.

Stills are `screencapture -o -l <window number>`: the window only, without its shadow.
With `FLO_README_VIDEO=1` the window is recorded the whole time with a ScreenCaptureKit
stream of that one window (a desktop independent filter, so no wallpaper, menu bar,
cursor or other windows). When the system refuses the stream, the app renders its own
frames instead (`cacheDisplay` of the window frame view, 15 fps, real times in
`readme-frames/times.txt`), and the build script assembles them at those times.

## Isolation

- `scripts/readme-media-vm.sh` refuses to run outside a virtual machine
  (`sysctl kern.hv_vmm_present`).
- The self test refuses to start without `FLO_SELFTEST_VM=1`. It keeps its app data in a
  temporary folder (`NSTemporaryDirectory()/flo-selftest-data`), and its unbundled binary
  uses its own defaults domain, never `app.flowriter.Flowriter`.
- `readme-shots` also refuses to run as the installed app (bundle id
  `app.flowriter.Flowriter`) or against the real data folder
  (`~/Library/Application Support/Flowriter`).
- The document is a fresh copy in a throwaway folder for each appearance. Its sidecar
  file (`.first-draft.md.flowriter.json`) is created there and removed with the folder.
- The self test window never joins the single instance channel. It builds its own window
  and does not run the app delegate that posts or observes `app.flowriter.Flowriter.open`.
