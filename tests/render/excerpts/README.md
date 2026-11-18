# The excerpt picture's reference image

`excerpts.png` is a view of an excerpt document with each excerpt's header
drawn as a block above it, as the headless CPU renderer draws it. The gate
draws the same picture again and compares it with the file: `ffi-test
excerpt-picture` in `mise run ffi-test`
(`lean/FfiTest/Editor/ExcerptView.lean`, `excerptPictureScenario`). The
scene is built in Lean and published through the display's real binding,
its blocks placed by the list the
excerpt document's snapshot carries (`Ffi.Snapshot.excerpts`) and made by
the editor's own rule (`ExcerptView.headers`,
`lean/Editor/ExcerptView.lean`), in `solarized-dark` as `Themes.shipped`
holds it, so what is compared is what the editor sends.

| File | Size | Bytes | sha256 |
|---|---|---|---|
| `excerpts.png` | 320 by 160 pixels, 8 bits a channel, no alpha | 4559 | `5294ac02dd6a5ba8a4a777d3d4110b1e0691111f6b6c33a61dc6856160fc6420` |

It is kept small on purpose: the scene's size, 320 by 160, and at most
20 KB, which the scenario checks, as the shipped themes' images are
(`tests/render/themes/README.md`).

## What it shows

Two source documents, `a.txt` holding `alpha\nbeta\ngamma\n` and `b.txt`
holding `one\ntwo\n`, and an excerpt document of `a.txt` from 6 to 11
(`beta\n`) and of `b.txt` from 0 to 8 (`one\ntwo\n`), which reads
`beta\n\none\ntwo\n`. It is one view 320 by 160 that covers the picture,
padded as the editor pads a window, 8 points across and down
(`Loop.padding`), with no status line:

- the header `a.txt` above `beta`, the first excerpt;
- `beta`, then the empty separator row, which holds the end of the first
  excerpt;
- the header `b.txt` above `one`, the second excerpt;
- `one` and `two`, with a block cursor on the `t` of `two` in the Vim
  scheme's normal-state face (`cursor.normal`), and the empty last row.

Each header is a block (`Editor/Scene.lean`, `Block`) all of whose text
is in the face `block-header`, which `solarized-dark` defines as base1 on
base02, bold: the background is behind the header's glyphs only, not
across the row. Rows of bare paper remain below the text.

It is laid out by the real shaper over one font file, the fixture
`tests/fonts/NotoSansMono-Regular.subset.ttf`, at 16 points, the theme's
default size, at scale 1, with grayscale antialiasing and hinting, as the
theme pictures are.

The scenario also checks, with pictures it draws itself and naming no
layout constant: that the same scene with no blocks differs from it; that
the pixels where the header's face changes when its background is made the
paper are mostly base02, `block-header`'s background; and that the
cursor's cell, found where the scene differs from it with the cursor in a
face nothing defines, is lower than in the scene with no blocks.

The file was made when the excerpt display was built (2026-11-17) and
looked at, enlarged four times, by the agent that implemented it, and not
yet by a person: the two headers are bold light-grey `a.txt` and `b.txt`
on a box of base02 that covers their glyphs, each one row above its
excerpt; `beta`, an empty row, `one` and `two` are in the theme's ink on
its paper, and the block cursor covers the `t` of `two`.

## Making it again

`mise run excerpt-reference` draws the picture and writes it here; it is
never part of the gate. Run it when the scene, the header's face, the font,
the painter, the blend or the rasteriser's pins change. Then look at the
file enlarged before committing it, and update the table above.
