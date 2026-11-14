# The renderer's reference image

`frame.png` is one frame of real text as the headless renderer draws it.
The gate compares the same frame, drawn again, with this file
(`crates/editor-render-wgpu/tests/reference.rs`). The file is compiled
into the test, so no test reads or writes a file when it runs.

| File | Size | Bytes | sha256 |
|---|---|---|---|
| `frame.png` | 256 by 96 pixels, 8 bits a channel, no alpha | 5334 | `a4d552a5bab109a3f289020934b2f1ab868aad698f428eb0ce608a929f64a700` |

It is kept small on purpose: at most 256 by 96 pixels and 20 KB, which
the test checks. There is one such image and no more.

## What it shows

The fixture frame of `crates/editor-render-wgpu/tests/common/mod.rs`: one
view, 256 by 96, laid out by the real shaper over the fixture fonts under
`tests/fonts`, drawn at scale 1 with subpixel antialiasing in the order
red, green, blue, and hinting.

- First row: `fine`, whose `f` and `i` are one glyph, a ligature; then a
  Hebrew word, which runs right to left; then a character of the CJK
  fallback font.
- The selection, in pale blue, is from the `n` of `fine` across the space
  to the first Hebrew letter, which is the rightmost of the word. Its
  head is on the second Hebrew letter: a red block cursor, with the
  letter drawn again in white.
- Second row: `under` in blue with a single underline; `line` on a
  yellow background with a red curly underline, which is drawn as a
  stepped line; then a face from the emoji fallback font, in outline (the
  fixture font has no colour glyphs).
- A status row across the bottom: light text on dark grey.
- The edges of the glyphs have colour fringes when enlarged: that is
  subpixel antialiasing, a coverage for each of a pixel's three stripes.

The file was looked at, enlarged four times, when it was made
(2026-11-14), and each of those was seen: by the agent that implemented
the renderer, and not yet by a person. A reference image nobody looked at
pins whatever was drawn, so whoever makes it again looks again.

## The tolerance

No channel of any pixel of the drawn frame may differ from the file by
more than 2 of 255. The drawing is deterministic on one machine: fixed
font bytes, a font set with the system's fonts off, glyphs rasterised on
the CPU, and a compositor of our own with no GPU, no clock and no
thread. The 2 is for what was never run: another processor's floating
point (the image was made on aarch64; x86_64 is unverified).

The tolerance is not slack, and the tests beside the comparison hold it
to that: the same frame with one letter changed does not match, and the
file differs from its own background in more than a stated number of
pixels. When the comparison was written it was seen to fail with the
rasteriser's subpixel bin ignored: 1479 pixels differed, one by 212.

## Making it again

```sh
mise run render-reference
```

which is `cargo run --locked --package editor-render-wgpu --example
reference -- tests/render/frame.png`. It is run by hand and never by the
gate, which builds the example and never runs it.

Make it again when the picture is meant to change: when the fixture
frame, the painter, the blend or the rasteriser's settings change, and
when the pin of Parley (shaping) or of swash (rasterising) moves, in the
commit that moves it. Then:

1. Open the new file, enlarged, and check it against "What it shows".
2. Update the table above: its bytes and its sha256.
3. Commit the file with the change that caused it.

If the comparison fails and nothing was meant to change, the picture
changed by accident: find out why before making the file again.
