# Flowriter: agent notes

Pointers only. The README explains the app, the layout and the tests.

- Work in a git worktree on `feat/<task>`, never in the main checkout. Each worktree has its own build folders (`.build-test`, `.build-release`). Commit only the files your task owns.
- Check before every push: `scripts/check.sh` (build + unit tests, last line `CHECK PASS` or `CHECK FAIL`). The pre-push hook runs it. Wire the hook once per clone: `git config core.hooksPath .githooks`. CI runs it too (`.github/workflows/ci.yml`).
- Never pipe test or check output before `&&` (`scripts/test.sh | tail -1 && git push` hid 2 failing tests on 2026-10-01). Run the script as it is and read its exit code.
- SwiftPM hangs on some Macs at "Downloading binary artifact ... Sparkle". `scripts/seed-sparkle.sh <build-dir>` fetches it with curl. `test.sh`, `check.sh` and `bundle.sh` call it when the artifact is missing.
- Never run `scripts/*-vm-test.sh` on a desktop. They open windows and send key and mouse events. Run them in the VM (README, Testing).
- Never edit a zsh script while it runs. zsh reads scripts as it goes, and a mid-run edit made `bundle.sh` fail with "unmatched".
- Releases: `scripts/release.sh X.Y.Z [--publish]`. The repo is public: ask Jonni before any push or release.
- The plain editor is `Sources/FlowriterKit` and `Sources/Flowriter` (README, Plain editor). It shares no code with `FloCore`, `FloKit` or `FloStateNative`. Its rule: the text storage is the only copy of the text, and Markdown styling sets colour and weight only, never a size or a spacing. `EditorViewTests.testTypingMarkersMovesNothingElse` holds that rule.
- Test the plain editor by sight with `scripts/drive.sh`: it runs the real app with its window off every screen, never activates it, feeds it the key and mouse steps of `Tests/FlowriterDrive/session.txt`, and saves a picture per `shot` step in `build/drive/`. It is safe on a desktop in use. Read the pictures after any change to layout, drawing or keys. The step language is in the header of `Sources/FlowriterDrive/main.swift`.
- Never pass a bare file path as an argument to a test tool that starts NSApplication: AppKit opens it as a document, and the document saves over it. Use `--name=value` arguments.
- One-off checks: `swift run Flowriter --snapshot file.md --out shot.png [--dark] [--notes notes.md] [--focus]` renders one picture, `--smoke file.md` launches and reports, `--perf file.md` times typing.
- The quit test is two runs: `scripts/drive.sh Tests/FlowriterDrive/quit-1.txt build/drive-quit`, then `scripts/drive.sh Tests/FlowriterDrive/quit-2.txt build/drive-quit --keep-state`. The first quits the app with an unsaved note; the second launches it again and expects the note back.
- AppKit calls `NSDocumentController.reviewUnsavedDocuments` at Quit before the app delegate's `applicationShouldTerminate`, and closes the documents in between. Anything that must see the open documents at quit belongs in `DocumentController.prepareToQuit`.
