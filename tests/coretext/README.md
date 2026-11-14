# Core Text's drawing of the weight sentence

`sentence.png` is the sentence `the window draws this` as Core Text draws
it on macOS: the macOS target for how heavy the renderer draws text. The
renderer's test draws the same sentence through its CPU path and holds
its dark pixels and its ink to this file's
(`crates/editor-render-wgpu/src/weight_tests.rs`). The file is compiled
into the test, so no test reads a file when it runs.

It is not a reference image of the renderer: the renderer never drew it,
`mise run render-reference` never writes it, and the renderer's one
reference image is still `tests/render/frame.png`.

| File | Size | Bytes | sha256 |
|---|---|---|---|
| `sentence.png` | 385 by 71 pixels, 8-bit grayscale | 2658 | `1c16d8153eecfacc12ae57b4dafa010de3f9a0b9059affe9afb890b5af76ab85` |

## What it shows

Black text on a white ground: the sentence in Noto Sans Mono
(`tests/fonts/NotoSansMono-Regular.subset.ttf`, the stand-in for Menlo) at
14 pt on a bitmap of scale 2, so 28 pixels to the em, as TextEdit draws
Menlo 14 pt on a display of scale 2. The baseline is on a whole pixel, 25
pixels up from the bottom, with a margin of 16 pixels around the line's
typographic bounds. No glyph reaches the border.

## How it was captured

```sh
mise run coretext-reference
```

which is `swift tools/coretext/capture.swift
tests/fonts/NotoSansMono-Regular.subset.ttf tests/coretext/sentence.png`.

- On 2026-11-14, on an Apple M5 Max (Mac17,7), macOS 27.2 (26B123), with
  Apple Swift 6.4.2. `AppleFontSmoothing` was not set
  (`defaults read -g AppleFontSmoothing` finds no such key), so the
  system's default smoothing applied.
- The font is loaded from the file's bytes (`CGDataProvider`, `CGFont`,
  `CTFontCreateWithGraphicsFont` at 14 pt); nothing is installed or
  registered on the system.
- The bitmap is 8-bit RGB with alpha, premultiplied first, little-endian,
  in the sRGB colour space, filled white, its transform scaled by 2.
  Antialiasing and font smoothing are allowed and on. Subpixel positioning
  and quantisation are left at the context's defaults, which CoreGraphics
  gives no way to read.
- The sentence is one `CTLine`, black.
- The script checked that red, green and blue agree within 1 at every
  pixel (they do: smoothing on macOS is not by colour stripes) and wrote
  the red channel as it is.
- Two runs gave the same bytes.

What the script printed:

| Drawing | Dark pixels (below 128) | Ink (255 less each value, summed) |
|---|---|---|
| Smoothed: the file | 1891 | 503470 |
| Not smoothed, for comparison | 1638 | 429519 |

So font smoothing makes the drawing about 15% darker in dark pixels and
17% in ink: Core Text did smooth, offscreen, in this bitmap.

The file was looked at, enlarged four times, when it was captured: by the
agent that implemented the weight, and not yet by a person.

## Capturing it again

Capture it again on a new major version of macOS, or when the fixture font
changes. Then:

1. Open the new file, enlarged, and check it against "What it shows".
2. Update the table and the capture's facts above.
3. Run the weight tests
   (`cargo test --locked -p editor-render-wgpu --lib weight_tests -- --nocapture`);
   if the macOS weight no longer matches within its tolerance, fit it
   again as `weight_tests.rs` says, in the same commit.
