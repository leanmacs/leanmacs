# Fixture fonts

The fonts the shaping tests load (`crates/editor-shape-parley/tests`). They
are compiled into the tests, so no test reads a file at run time, and no
test uses a font of the machine it runs on.

Five Noto fonts, four of them subset to the characters the tests shape. The
whole upstream files are 7.7 MB; these are 119 KB.

| File | Family | What it is for | Bytes | sha256 |
|---|---|---|---|---|
| `NotoSans-Regular.subset.ttf` | Noto Sans | The primary: proportional, with a ligature for `fi`, no CJK and no emoji | 54632 | `e4fc53e3a47abb3848d3f900ef53425d1e7103537be1590a30973a0e2958955e` |
| `NotoSansMono-Regular.subset.ttf` | Noto Sans Mono | The monospace font of the mixed-fonts test | 30488 | `5507eb3d4a941cbf77b4c7ede3959e4b2a18b12c764e2ee0ba37645afd28750b` |
| `NotoSansHebrew-Regular.ttf` | Noto Sans Hebrew | Hebrew, for bidirectional text; the upstream file, whole | 26860 | `cdefaf8efd47045f6820928eba84db5bed7557539328952b5f828315485e02ee` |
| `NotoSansJP-Regular.subset.otf` | Noto Sans JP | The fallback that covers the CJK character | 3936 | `80fd094a4512c91f0c6482fb3f9547ec676a3a42bc7bf403c7ada5e2baf91d7b` |
| `NotoEmoji.subset.ttf` | Noto Emoji | The fallback that covers the emoji: monochrome, with a weight axis | 3276 | `1054b6315a17a8d7035bc4a7e4fccf22770b1d0695aa6cd428b8e1e6602598fe` |

## What the tests rest on

Seven facts of these files, and no other: no test states a glyph id, an
advance, an offset, a variation coordinate or a height of a font.

- Noto Sans has a ligature for `fi`: the two characters are one glyph.
- Noto Sans has no glyph for U+65E5 (日), U+1F600 (😀) or U+0E01 (ก). Noto
  Sans JP has the first and Noto Emoji the second; no fixture has the
  third.
- Noto Sans Hebrew draws the vav of `שלום` with an offset from its pen
  position: to the left of it, and no higher or lower.
- Noto Sans draws the combining acute accent, U+0301, at its own height
  over `x`, and raises it over `X`.
- Noto Emoji has a weight axis, and no other fixture varies: its bold is
  a place on the axis, not the regular outlines made bolder.
- Noto Sans is its upstream's hinted build, and the subset keeps the
  hints: at 16 pixels the `a` fitted to the pixel grid is another image
  than the `a` left as its outline is (the rasteriser's tests,
  `crates/editor-render-wgpu/src/raster.rs`).
- Noto Sans Mono draws `|` as one upright stem, so the coverage summed
  across its middle row is the stem's width in pixels (the rasteriser's
  dilation, `crates/editor-render-wgpu/src/raster.rs`). It is also the
  stand-in for Menlo that Core Text's reference drawing of the weight
  sentence is made from (`tests/coretext/README.md`).

## Where they come from

| File | Upstream repository, commit and path | Bytes | sha256 of the upstream file | Characters kept |
|---|---|---|---|---|
| `NotoSans-Regular.subset.ttf` | `notofonts/notofonts.github.io` at `3460ae9d93e7ac7a90d38a247d5d4d0f6147d239`, `fonts/NotoSans/hinted/ttf/NotoSans-Regular.ttf` | 621572 | `478c558ea716033cd60c03438f628dfa75694dcf6b5f6d505a2f05fd2b4f3823` | `U+0020-007E,U+00A0-00FF,U+0301,U+20AC,U+FFFD` |
| `NotoSansMono-Regular.subset.ttf` | the same repository and commit, `fonts/NotoSansMono/hinted/ttf/NotoSansMono-Regular.ttf` | 596428 | `65b5e2b2c4a1fba9ae8be1f026cb35b03dcb8886d9b2a4147054fde12f7e767d` | `U+0020-007E` |
| `NotoSansHebrew-Regular.ttf` | the same repository and commit, `fonts/NotoSansHebrew/hinted/ttf/NotoSansHebrew-Regular.ttf` | 26860 | `cdefaf8efd47045f6820928eba84db5bed7557539328952b5f828315485e02ee` | all: the file is checked in whole |
| `NotoSansJP-Regular.subset.otf` | `notofonts/noto-cjk` at `f8d157532fbfaeda587e826d4cd5b21a49186f7c`, `Sans/SubsetOTF/JP/NotoSansJP-Regular.otf` | 4533028 | `dff723ba59d57d136764a04b9b2d03205544f7cd785a711442d6d2d085ac5073` | `U+65E5,U+672C,U+8A9E` |
| `NotoEmoji.subset.ttf` | `google/fonts` at `29b4ec6df2522a8aee279414b78a07910b065874`, `ofl/notoemoji/NotoEmoji[wght].ttf` | 1982596 | `de6c18832938afc99caf132b39d6a30a19bac7f2e812e28db2535b4608d27551` | `U+1F600` |

## Making them again

`tools/fonts/subset.sh` makes all five from a directory that holds the
upstream files under the names above:

```sh
tools/fonts/subset.sh <directory of the upstream files>
```

It checks each upstream file against its sha256, copies the Hebrew file,
and for each of the other four runs fonttools' subsetter at an exact
version, through `uvx`:

```sh
uvx --from fonttools==4.61.0 pyftsubset <upstream file> \
    --output-file=<file> --unicodes=<characters kept> \
    --layout-features='*' --name-IDs='*' --name-languages='*' \
    --notdef-outline --no-recalc-timestamp
```

Every layout feature and every name record is kept, so the ligature, the
family names and the copyright and licence records of each font are the
upstream's. It is run by hand and never by the gate, which needs only the
files. Two runs give the same bytes: the sha256s above are what a run must
give, so a change of this table is a change of the fonts.

Checked when they were made (2026-11-13): the script run twice gave these
sha256s both times; `fc-query` reads each file's family as the table's and
its characters as those kept; and the ligature table of the Noto Sans
subset still maps `f`, `i` to one glyph.

## Licences

All five are under the SIL Open Font License 1.1, which permits
redistributing and modifying them with the copyright notice and the
licence kept. None declares a Reserved Font Name, so a subset keeps its
family's name. The licence texts are beside the fonts, each byte for
byte its repository's file at the commit named above:

| Licence file | From | Covers | Copyright, as the font's own record states it |
|---|---|---|---|
| `OFL-Noto.txt` | `fonts/LICENSE` of `notofonts/notofonts.github.io` | Noto Sans, Noto Sans Mono, Noto Sans Hebrew | Copyright 2022 The Noto Project Authors (Noto Sans, Noto Sans Mono); Copyright 2024 The Noto Project Authors (Noto Sans Hebrew) |
| `OFL-NotoSansCJK.txt` | `Sans/LICENSE` of `notofonts/noto-cjk` | Noto Sans JP | © 2014-2021 Adobe (http://www.adobe.com/). |
| `OFL-NotoEmoji.txt` | `ofl/notoemoji/OFL.txt` of `google/fonts` | Noto Emoji | Copyright 2013 Google LLC |
