# The shipped themes' reference images

Each PNG file here is one shipped theme's picture of the fixture file
`source.lean`, as the headless CPU renderer draws it. The gate draws the
same picture again and compares it with the file: the package's linked
test (`ShippedThemesTest/Linked.lean`,
`ShippedThemesTest/Linked/ShippedThemes.lean`), which the package steps
build and run (`tools/package-set.sh`, in `mise run lean` and `mise run
ffi-test`). It hands the three themes, as `ShippedThemes.themes` holds
them, to the core's theme picture check (`lean/Editor/Theme/Picture.lean`,
`themePicturesScenario`), a test double of the core a package's tests may
import. The scene is built in Lean and published through the display's
real binding, so what is compared is what the editor sends, not a theme
written again in Rust.

Everything the test reads is in this directory, so the package reads
nothing of the repository outside itself:

- **`source.lean`**, the text the pictures show: a copy of the core's
  fixture `tests/render/themes/source.lean`, byte for byte, so the three
  pictures are the ones that were checked in before the themes became a
  package. It is no module of the package (`lean-fmt.toml` leaves `tests/`
  out).
- **`NotoSansMono-Regular.subset.ttf`**, the one font the pictures are
  laid out in: a copy of the core's fixture font of that name
  (`tests/fonts/README.md` says how it was made), 30488 bytes, sha256
  `5507eb3d4a941cbf77b4c7ede3959e4b2a18b12c764e2ee0ba37645afd28750b`.
- **`OFL-Noto.txt`**, that font's licence, the SIL Open Font License 1.1,
  a copy of `tests/fonts/OFL-Noto.txt`.

| File | Size | Bytes | sha256 |
|---|---|---|---|
| `solarized-dark.png` | 320 by 160 pixels, 8 bits a channel, no alpha | 15495 | `efa5fb8bb590520c13310a3182c840534328c0dae8f5ddf10d247bfd31cfe715` |
| `solarized-light.png` | 320 by 160 pixels, 8 bits a channel, no alpha | 15464 | `fe37d976ac452e208cd19eed0ac85696e066f76731f61c23e00f6cf40840abea` |
| `fairy-floss.png` | 320 by 160 pixels, 8 bits a channel, no alpha | 16054 | `6048381627cfee308b70a1eb3ff54167343f5d48e9755d75353a683d448fcd6f` |

Each is kept small on purpose: the scene's size, 320 by 160, and at most
20 KB, which the scenario checks.

## What they show

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

It is laid out by the real shaper over one font file, the copy here of
the fixture `NotoSansMono-Regular.subset.ttf`, the default family of a
font set with no font of the machine; the theme's `monospace` family is
not in the set and falls through to it. It is drawn at 16 points, the
theme's default size, at scale 1, with grayscale antialiasing and hinting,
at the linear weight.

The three files were made again for the window padding and looked at,
enlarged four times, when they were (2026-11-16), by the agent that
implemented it, and not yet by a person: in each, the text, the selection
and the block cursor on the `h` are as before but 8 pixels right and 8
down, the text's first ink at x 8; the badge is a box of its accent
(Solarized's magenta, Fairy Floss's lavender) 74 pixels across from x 8,
its text 8 pixels further in; the buffer's name follows in bold; line:col
and the position end 8 short of the row's right edge, their last ink at x
305 and their box at 312; the mode line's background reaches x 0 and x
319; and the status row is 28 pixels tall, from row 132, as before.
Measured too, by decoding the files' pixels. They were made again when the
selected window's row took the face `mode-line.active` (2026-11-17), by the
agent that implemented it: Solarized's two came out the same bytes, since
Solarized's selection colour is its `mode-line`'s, base02; Fairy Floss's
changed in the status row alone, rows 132 to 159, whose background went
from the theme's line highlight, 62, 61, 50, to its selection, 73, 72, 62,
found by decoding the old and the new file. The three files moved here unchanged, the same
bytes, when the themes became a package (2026-11-19). Looking at them
checks that they show text, a selection and a cursor; it does not judge
how the theme looks, which is left to the owner's day-to-day use.

## The tolerance, and what else is checked

No channel of any pixel of the drawn picture may differ from the file by
more than 2 of 255: the bound and the reason of the renderer's own
reference image (the repository's `tests/render/README.md`, "The
tolerance"). The drawing is
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

which, after the core's own picture, runs this package's linked test in
the package's directory with `--write` after its two arguments
(`.lake/build/bin/ShippedThemesTest-Linked <sysroot> <core olean dir>
--write`). It is run by hand and never by the gate.

Make them again when a shipped theme's definition, the fixture, the
font, the painter, the blend or the rasteriser's pins change, in the
commit that changes it. Then:

1. Open the new files, enlarged, and check them against "What they show".
2. Update the table above: their bytes and their sha256.
3. Commit the files with the change that caused it.

If the comparison fails and nothing was meant to change, the picture
changed by accident: find out why before making the files again.
