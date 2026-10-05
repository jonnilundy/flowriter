# Flowriter: agent notes

Pointers only. The README explains the app, the layout and the tests.

- Work in a worktree, `~/Workbench/code/flowriter-wt/<task>` on `feat/<task>`, never in the main checkout. Each worktree has its own build folders (`.build-test`, `.build-release`). Commit only the files your task owns.
- Check before every push: `scripts/check.sh` (build + unit tests, last line `CHECK PASS` or `CHECK FAIL`). The pre-push hook runs it. Wire the hook once per clone: `git config core.hooksPath .githooks`. CI runs it too (`.github/workflows/ci.yml`).
- Never pipe test or check output before `&&` (`scripts/test.sh | tail -1 && git push` hid 2 failing tests on 2026-10-01). Run the script as it is and read its exit code.
- SwiftPM hangs on some Macs at "Downloading binary artifact ... Sparkle". `scripts/seed-sparkle.sh <build-dir>` fetches it with curl. `test.sh`, `check.sh` and `bundle.sh` call it when the artifact is missing.
- Never run `scripts/*-vm-test.sh` on a desktop. They open windows and send key and mouse events. Run them in the VM (README, Testing).
- Never edit a zsh script while it runs. zsh reads scripts as it goes, and a mid-run edit made `bundle.sh` fail with "unmatched".
- Releases: `scripts/release.sh X.Y.Z [--publish]`. The repo is public: ask Jonni before any push or release.
