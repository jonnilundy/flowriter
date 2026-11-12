# README media

The two pictures in the main README are rendered by the app itself from the sample note in
this folder. No window opens.

| File | What |
|---|---|
| `flowriter-light.png`, `flowriter-dark.png` | The window (1320 x 860 pt at 2x) with the sample note and its notes drawer. |
| `first-draft.md`, `first-draft.notes.md` | The sample note and the text of its drawer. |

## Regenerate

```sh
swift run Flowriter --snapshot docs/media/first-draft.md --notes docs/media/first-draft.notes.md \
  --width 1320 --height 860 --out docs/media/flowriter-light.png
swift run Flowriter --snapshot docs/media/first-draft.md --notes docs/media/first-draft.notes.md \
  --width 1320 --height 860 --dark --out docs/media/flowriter-dark.png
```

Read both pictures before you commit.
