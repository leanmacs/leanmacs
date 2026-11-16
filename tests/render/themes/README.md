# The shipped themes' reference images

Each file here is one shipped theme's picture of the fixture file
`source.lean`, as the headless CPU renderer draws it. The gate draws the
same picture again and compares it with the file: `ffi-test
theme-pictures` in `mise run ffi-test` (`lean/FfiTest.lean`,
`themePicturesScenario`). The scene is built in Lean and published
through the display's real binding, in the theme as `Themes.shipped`
holds it (`lean/Editor/Themes/Compiled.lean`), so what is compared is
what the editor sends, not a theme written again in Rust.

| File | Size | Bytes | sha256 |
|---|---|---|---|
| `solarized-dark.png` | 320 by 160 pixels, 8 bits a channel, no alpha | 15482 | `3f64c5fd2deac25bd2e75ad13cea0b03d5e2523860ae6fb2c72d860779de0693` |
| `solarized-light.png` | 320 by 160 pixels, 8 bits a channel, no alpha | 15455 | `b1d66800a228667b8c572bbc614ceecf77e20f39a8b1d134bf20e95c4bd13104` |
| `fairy-floss.png` | 320 by 160 pixels, 8 bits a channel, no alpha | 16043 | `ec26893ec07cca9a03b7b8332fd2b13feaf4dabf5ef4a830ef447cae977bedae` |

Each is kept small on purpose: the scene's size, 320 by 160, and at most
20 KB, which the scenario checks.

## What they show

The fixture file `source.lean`, four lines of ASCII, in one view 320 by
160 that covers the picture, taller than the text, so rows of bare paper
remain below it:

- the text in the default face, the theme's ink on its paper;
- a selection from the `a` of `area` on the second line to its head on
  the `h` of `(w h`, in the theme's selection background;
- a block cursor on that `h`, in the face of the Vim scheme's visual state
  (`cursor.visual`): the paper on the cursor colour;
- the mode line across the bottom, the shipped one of a selected window
  in visual state (`FfiTest.themeStatus`, `lean/Editor/ModeLine.lean`):
  on the left the `VISUAL` badge in `mode-line.state.visual`, the paper on
  the theme's visual accent, with 8 points of it each side of the text,
  then `source.lean` in `mode-line.buffer`; on the right, ending at the
  row's end, the cursor's line:col `2:13` and its position `50%` in
  `mode-line.secondary`; over `mode-line`, in a row made taller by
  `mode-line`'s and `echo-area`'s padding of 3 points above and below (the
  font's 22-pixel line and 6, 28 pixels, the view's bottom row).

It is laid out by the real shaper over one font file, the fixture
`tests/fonts/NotoSansMono-Regular.subset.ttf`, the default family of a
font set with no font of the machine; the theme's `monospace` family is
not in the set and falls through to it. It is drawn at 16 points, the
theme's default size, at scale 1, with grayscale antialiasing and hinting,
at the linear weight.

The three files were made again for the segmented mode line and looked
at, enlarged four times, when they were (2026-11-16), by the agent that
implemented it, and not yet by a person: in each, the text, the selection
and the block cursor on the `h` are as before; the badge is a box of its
accent (Solarized's magenta, Fairy Floss's lavender) 74 pixels across from
the row's start, its text 8 pixels in; the buffer's name follows in bold;
line:col and the position end at the row's right edge; and the status row
is 28 pixels tall, from row 132. Measured too, by decoding the files'
pixels. Looking at them
checks that they show text, a selection and a cursor; it does not judge
how the theme looks, which is left to the owner's day-to-day use.

## The tolerance, and what else is checked

No channel of any pixel of the drawn picture may differ from the file by
more than 2 of 255: the bound and the reason of the renderer's own
reference image (`../README.md`, "The tolerance"). The drawing is
deterministic on one machine; the 2 is for another processor's floating
point.

The scenario also checks, in each variant's picture, that the colours of
the palette's roles are where they belong, with the expected colours
written from each theme's published record and not read from the theme. It
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

And it guards that the comparison discriminates: the light picture does
not match the dark reference.

## Making them again

```sh
mise run theme-references
```

which runs `ffi-test theme-pictures ../tests/render/themes
../tests/fonts/NotoSansMono-Regular.subset.ttf --write` in `lean/`. It is
run by hand and never by the gate.

Make them again when a shipped theme's definition, the fixture, the
font, the painter, the blend or the rasteriser's pins change, in the
commit that changes it. Then:

1. Open the new files, enlarged, and check them against "What they show".
2. Update the table above: their bytes and their sha256.
3. Commit the files with the change that caused it.

If the comparison fails and nothing was meant to change, the picture
changed by accident: find out why before making the files again.
