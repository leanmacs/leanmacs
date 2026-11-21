# The built-in theme's reference image

`default.png` is the picture of the fixture file `source.lean` in the
built-in theme, `default` (`Theme.builtin`, `lean/Editor/Face.lean`), as
the headless CPU renderer draws it. The gate draws the same picture again
and compares it with the file: `ffi-test theme-pictures` in `mise run
ffi-test` (`FfiTest.themePictures`, `lean/FfiTest.lean`), which runs the
core's theme picture check (`lean/Editor/Theme/Picture.lean`,
`themePicturesScenario`) on that theme. The scene is built in Lean and
published through the display's real binding, so what is compared is what
the editor sends, not a theme written again in Rust.

The check is a test double of the core, and a package that ships themes
runs it on its own: the shipped palettes' pictures and their README are in
`packages/shipped-themes/tests/render/`, with a copy of `source.lean` and
of the font, so that package reads nothing here.

| File | Size | Bytes | sha256 |
|---|---|---|---|
| `default.png` | 320 by 160 pixels, 8 bits a channel, no alpha | 15549 | `3344637de4787fddcf636603b3650b983ed153599ede4e2a985be06ce8b4d836` |

It is kept small on purpose: the scene's size, 320 by 160, and at most
20 KB, which the scenario checks.

## What it shows

The fixture file `source.lean`, four lines of ASCII, in one view 320 by
160 that covers the picture, taller than the text, so rows of bare paper
remain below it. The view is padded as the editor pads a window, 8 points
across and down (`Loop.padding`), which at scale 1 are 8 pixels: the text
starts 8 in from the left and 8 down, on paper, and the mode line's first
field starts 8 in from the left and its last ends 8 short of the right,
while its background runs to both edges:

- the text in the default face, the theme's ink on its paper;
- a selection from the `a` of `area` on the second line to its head on
  the `h` of `(w h`, in the theme's selection background;
- a block cursor on that `h`, in the face of the Vim scheme's visual state
  (`cursor.visual`): the paper on the cursor colour;
- the mode line across the bottom, the shipped one of a selected window
  in visual state (`Themes.Picture.themeStatus`, `lean/Editor/ModeLine.lean`):
  on the left the `VISUAL` badge in `mode-line.state.visual`, the paper on
  the theme's visual accent, with 8 points of it each side of the text,
  then `source.lean` in `mode-line.buffer`; on the right, ending at the
  row's end less the padding, the cursor's line:col `2:13` and its
  position `50%` in
  `mode-line.secondary`; over the row's face `mode-line.active`, the
  selected window's, which gives the row its background (the theme's
  selection colour), over `mode-line`, in a row made taller by
  `mode-line`'s and `echo-area`'s padding of 3 points above and below (the
  font's 22-pixel line and 6, 28 pixels, the view's bottom row).

It is laid out by the real shaper over one font file, the fixture
`tests/fonts/NotoSansMono-Regular.subset.ttf`, the default family of a
font set with no font of the machine; the theme's `monospace` family is
not in the set and falls through to it. It is drawn at 16 points, the
theme's default size, at scale 1, with grayscale antialiasing and hinting,
at the linear weight.

The file was made when the picture check became the core's (2026-11-19)
and looked at, enlarged four times, by the agent that made it, and not yet
by a person: the text in the placeholder palette's ink on its paper, the
selection from `area` to the `h`, the block cursor on that `h`, the
`VISUAL` badge a box of the palette's magenta from x 8, `source.lean` in
bold after it, and `2:13 50%` ending 8 short of the right edge, on a status
row 28 pixels tall whose background reaches both edges. Looking at it
checks that it shows text, a selection and a cursor; it does not judge how
the theme looks, which is left to the owner's day-to-day use.

## The tolerance, and what else is checked

No channel of any pixel of the drawn picture may differ from the file by
more than 2 of 255: the bound and the reason of the renderer's own
reference image (`../README.md`, "The tolerance"). The drawing is
deterministic on one machine; the 2 is for another processor's floating
point.

The scenario also checks that the colours of the palette's roles are where
they belong in the picture, with the expected colours written from the
placeholder palette (`Palette.placeholder`) and not read from the theme. It
finds each region by differencing pictures it draws itself, and names no
cell size, line height or other value layout or the renderer owns:

- **The paper** is the commonest colour of the picture.
- **The cursor**: the scene is drawn again with the cursor in a face no
  theme defines, which is drawn in the default face's paint, the ink on
  the paper. The pixels that change are the cursor's cell, and their
  commonest colour in the scene's picture is the cursor colour.
- **The text**: the scene is drawn with no selection, so no cursor, over
  the fixture and over the same text with every character but a newline
  a space. The pixels that change are the glyphs: every one is between
  the paper and the ink, channel by channel, within 2, and the one
  farthest from the paper is within 2 of the ink. When the check was
  written that held: hinting snaps the strokes of `-`, `=`, `_` and `|`
  to whole pixels, so some glyph pixels are fully inked.

## Making it again

```sh
mise run theme-references
```

which runs `ffi-test theme-pictures ../tests/render/themes
../tests/fonts/NotoSansMono-Regular.subset.ttf --write` in `lean/`, and
then the shipped themes' package's linked test with `--write`, which makes
that package's three again. It is run by hand and never by the gate.

Make it again when the built-in theme's definition, the fixture, the
font, the painter, the blend or the rasteriser's pins change, in the
commit that changes it. Then:

1. Open the new file, enlarged, and check it against "What it shows".
2. Update the table above: its bytes and its sha256.
3. Commit the file with the change that caused it.

If the comparison fails and nothing was meant to change, the picture
changed by accident: find out why before making the file again.
