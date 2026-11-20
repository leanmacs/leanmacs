# Core Text's drawings of the weight sentence

The sentence `the window draws this` as Core Text draws it on macOS, in
five drawings, with the place of each of its glyphs. They are macOS's own
text, which the renderer is held to:

- `sentence.png` is the target for how heavy the renderer draws text with
  swash. The renderer's test draws the same sentence through its CPU path
  and holds its dark pixels and its ink to this file's
  (`crates/editor-render-wgpu/src/weight_tests.rs`). The file is compiled
  into the test, so no test reads a file when it runs.
- The other four drawings are what the Core Text rasteriser's masks are
  compared with, black on white and light on dark at 14 and 28 pixels,
  and grey on white (`crates/editor-raster-coretext/examples/check/`,
  `mise run coretext-check`, run on demand on macOS).
- `positions.txt` is where Core Text puts each glyph on the line. The
  shaper's test and the painter's test hold their places to it
  (`crates/editor-shape-parley/tests/core_text.rs`,
  `crates/editor-render-wgpu/src/placement_tests.rs`), in the gate.

None is a reference image of the renderer: the renderer never drew them,
`mise run render-reference` never writes them, and the renderer's one
reference image is still `tests/render/frame.png`.

| File | Size | Bytes | sha256 |
|---|---|---|---|
| `sentence.png` | 385 by 71 pixels, 8-bit grayscale | 2658 | `1c16d8153eecfacc12ae57b4dafa010de3f9a0b9059affe9afb890b5af76ab85` |
| `sentence-dark.png` | 385 by 71 pixels, 8-bit grayscale | 2731 | `dd66afd05c6743edfca74c29fdc2f1ad871d41188045a782b51b695a910809a6` |
| `sentence-14.png` | 209 by 52 pixels, 8-bit grayscale | 1255 | `16ac7f2af0a77ecfc7fa639496bc7ca8c3dbddfffc771d754cd580b8417d80da` |
| `sentence-14-dark.png` | 209 by 52 pixels, 8-bit grayscale | 1250 | `4a14121de90f3d8732129676d0605f00b90706b6c913ad530b3c6384a6983572` |
| `sentence-grey.png` | 385 by 71 pixels, 8-bit grayscale | 2677 | `b75c425c2dbdbba56af8c5ab1c5f5ca8705e40edc7137ed18506edc23e331ea5` |
| `positions.txt` | 42 lines of glyphs, under 2 of comment | 1295 | `f73652a3ad732f80da4b8606185067cd45351fcdbd687505a6d8333aa514c81d` |

## What they show

Every drawing is the sentence in Noto Sans Mono
(`tests/fonts/NotoSansMono-Regular.subset.ttf`, the stand-in for Menlo) at
14 pt, as one `CTLine`, with a margin of 16 pixels around the line's
typographic bounds and the baseline on a whole pixel. No glyph reaches the
border.

| File | Scale (pixels to the em) | Text on ground | Baseline, up from the bottom | Values |
|---|---|---|---|---|
| `sentence.png` | 2 (28) | black on white | 25 | the red channel as drawn: 255 is the white ground |
| `sentence-dark.png` | 2 (28) | `#d8dee9` on `#2e3440`, the default theme's | 25 | coverage: 255 is full ink |
| `sentence-14.png` | 1 (14) | black on white | 21 | coverage |
| `sentence-14-dark.png` | 1 (14) | `#d8dee9` on `#2e3440` | 21 | coverage |
| `sentence-grey.png` | 2 (28) | `#808080` on white | 25 | coverage |

`#808080` is in the luminance bucket 2 by its encoded value and in bucket
1 by its linear light (0.22), so its drawing tells which of the two Core
Text's smoothing follows.

`positions.txt` has one line for each glyph at scale 1 and at scale 2,
`<scale> <glyph id> <x px> <y px> <advance px>`, in device pixels from the
line's origin: x and y as the line's run places the glyph
(`CTRunGetGlyphs`, `CTRunGetPositions`), and the advance as the font's own
metrics give it (`CTFontGetAdvancesForGlyphs`). In this font every glyph
is 0.6 em on from the last, 8.4 pixels at scale 1 and 16.8 at scale 2, and
the line's positions are its advances summed: the script found no pen step
that differs from the glyph's advance.

## How they were captured

```sh
mise run coretext-reference
```

which is `swift tools/coretext/capture.swift
tests/fonts/NotoSansMono-Regular.subset.ttf tests/coretext`.

- `sentence.png`: on 2026-11-14, on an Apple M5 Max (Mac17,7), macOS 27.2
  (26B123), with Apple Swift 6.4.2. `AppleFontSmoothing` was not set
  (`defaults read -g AppleFontSmoothing` finds no such key), so the
  system's default smoothing applied. The capture of 2026-11-20 below
  drew it again to the same bytes, so the weight fit's target is still
  the 2026-11-14 capture.
- The other files: on 2026-11-20, on the same machine, macOS 27.2.1
  (26B131), with Apple Swift 6.4.2, `AppleFontSmoothing` not set. Two runs
  gave the same bytes, for every file.
- The font is loaded from the file's bytes (`CGDataProvider`, `CGFont`,
  `CTFontCreateWithGraphicsFont` at 14 pt); nothing is installed or
  registered on the system.
- Each bitmap is 8-bit RGB with alpha, premultiplied first, little-endian,
  in the sRGB colour space, filled with its ground, its transform scaled
  by its scale. Antialiasing and font smoothing are allowed and on.
- For `sentence.png`, subpixel positioning and quantisation are left at
  the context's defaults, as they were on 2026-11-14. For the other four,
  they are set as the rasteriser sets them: subpixel positioning on, and
  quantisation off.
- The script checked each drawing before writing it: nothing drawn on the
  border; for `sentence.png`, red, green and blue within 1 of each other
  at every pixel, and the red channel written as it is; for the others,
  each channel mapped back through its ground and its text colour
  (`(value - ground) / (text - ground)`) to one coverage within 2 of 255,
  and the mean written. They agreed: smoothing on macOS is not by colour
  stripes.

What the script printed:

| Drawing | Dark pixels (below 128) | Ink (255 less each value, summed) | Coverage, summed |
|---|---|---|---|
| `sentence.png`, smoothed: the file | 1891 | 503470 | |
| `sentence.png` not smoothed, for comparison | 1638 | 429519 | |
| `sentence-dark.png` | | | 564477 |
| `sentence-14.png` | | | 126131 |
| `sentence-14-dark.png` | | | 149163 |
| `sentence-grey.png` | | | 536580 |

So font smoothing makes the black drawing about 15% darker in dark pixels
and 17% in ink, and light text on a dark ground has about 12% more
coverage than black on white at the same size.

## Capturing them again

Capture them again on a new major version of macOS, or when the fixture
font changes. The script's checks stand in for looking at the files: it
refuses a drawing with ink on its border or with channels that are not one
coverage. Then:

1. Update the tables and the capture's facts above.
2. Run the weight tests
   (`cargo test --locked -p editor-render-wgpu --lib weight_tests -- --nocapture`);
   if the swash fallback's weight no longer matches within its tolerance,
   fit it again as `weight_tests.rs` says, in the same commit.
3. Run the placement tests (`cargo test --locked -p editor-shape-parley
   --test core_text`, `cargo test --locked -p editor-render-wgpu --lib
   placement_tests`) and `mise run coretext-check`, and record the
   figures in `docs/dev-practices/on-demand-checks.md`.
