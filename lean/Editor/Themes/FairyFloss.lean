import Editor.Face

/-!
# Fairy Floss

sailorhg's Fairy Floss: "pink, mint, lavender and lemon" on a purple paper.
`published` holds every colour the source publishes, nineteen of them;
`Colours.theme` is the one mapping from them to the face vocabulary
(`Editor/Face/Vocabulary.lean`): the shared palette's theme, then Fairy
Floss's own definitions after it. `fairyFloss` applies it to the published
colours, and is shipped (`Themes.Shipped.themes`,
`Editor/Themes/Shipped.lean`).

## The source, and the licence

The repository `sailorhg/fairyfloss`, at commit
`982e64a9e36160350125c0a82a7981dca6200150` (`commit`), the tip of `master`
and tag `v0.2.0`. The files read, with their sha256 at that commit:

| File | Bytes | sha256 |
|---|---|---|
| `fairyfloss.tmTheme` | 6558 | `5ca28763a4052bf224d28d910c9a442ef4e227caf3a927461f55dea2fe552dd5` |
| `styles/syntax-variables.less` | 950 | `edd874c321e5fc549f730c8cf22ee43b432213f4f5cd8e692c7998a9a217b6b7` |
| `styles/base.less` | 2795 | `67dcf28a442ba0e9a0faf50fc9cc61d7919e98eedff64c2f052611dae750e48e` |
| `package.json` | 346 | `1dd9b819130f0eb3a0e0758fc8ef627c5e67c9df3b321bcba51b0a74dd71e039` |

The tmTheme is the primary source. It is named `Monokai` inside, a leftover
of the editor it was made in, and its UI tones `invisibles`,
`lineHighlight` and `selection` are Monokai's. `syntax-variables.less`
restates its general colours and adds four git-diff colours; `base.less`
restates every scope's colour, and agrees with the tmTheme.

The repository has no `LICENSE` file; its `package.json` declares
`"license": "MIT"`, author Amy Wibowo. That declaration, written out as the
standard MIT licence, with its provenance, is beside this file, as
`FairyFloss-LICENSE.txt`.

## The published colours

Lines are those of the `<string>` holding the value in the tmTheme, or of
the declaration in the `.less` file.

| Field | Value | Source |
|---|---|---|
| `background` | `#5A5475` | tmTheme l.17; syntax-variables l.8, l.22 |
| `foreground` | `#F8F8F2` | tmTheme l.21; syntax-variables l.5, l.17, l.20, l.21 |
| `caret` | `#F8F8F0` | tmTheme l.19; syntax-variables l.6; `invalid`'s foreground, l.273, l.286 |
| `invisibles` | `#3B3A32` | tmTheme l.23; syntax-variables l.11–13, l.16 |
| `lineHighlight` | `#3E3D32` | tmTheme l.25; syntax-variables l.23; base.less l.52 |
| `selection` | `#49483E` | tmTheme l.27; syntax-variables l.7 |
| `gold` | `#E6C000` | tmTheme l.38 `comment`; base.less l.56 |
| `yellow` | `#FFEA00` | tmTheme l.49 `string`; base.less l.60 |
| `lavender` | `#C5A3FF` | tmTheme l.60, l.71, l.82 `constant.*`; base.less l.64, 68, 72 |
| `pink` | `#FFB8D1` | tmTheme l.104 `keyword`, l.117 `storage`, l.195 `entity.name.tag`; base.less l.79, 83, 112 |
| `mint` | `#C2FFDF` | tmTheme l.130 `storage.type`, l.221, l.234, l.247 `support.*`; base.less l.88, 120, 124, 129 |
| `lemon` | `#FFF352` | tmTheme l.143, l.156, l.169 `entity.name.function`, l.208; base.less l.93, 99, 103, 116 |
| `peach` | `#FF857F` | tmTheme l.182 `variable.parameter`; base.less l.108 |
| `invalid` | `#F92672` | tmTheme l.269; base.less l.137 |
| `deprecated` | `#AE81FF` | tmTheme l.284; base.less l.142 |
| `renamed` | `#96CBFE` | syntax-variables l.27 |
| `added` | `#A8FF60` | syntax-variables l.28 |
| `modified` | `#E9C062` | syntax-variables l.29 |
| `removed` | `#CC6666` | syntax-variables l.30 |

`invisibles`, `invalid` and `deprecated` are drawn by no face yet: the
vocabulary has no face for them. They are kept so the record is the
source's whole palette. `variable` and `support.other.variable` set no
colour, so TextMate draws them, and every scope the theme does not match,
in the global foreground.

## The shared palette's roles

The paper `background`; the ink and strong `foreground` (the source has no
brighter text tone); the cursor `caret`; selected `selection`; raised
`lineHighlight`, the one tone the source sets for a highlighted band (a
choice: the source has no status bar); faint `lavender`, its softest accent
(a choice: the source has no muted text tone, and `invisibles` is
unreadable as text). The accents: red `removed`, orange `peach`, yellow
`lemon`, green `added`, cyan `mint`, blue `renamed`, violet `lavender`,
magenta `pink` (`Colours.palette`).

## Each face, and the choice made

**Shared** is what `Palette.theme` gives with the roles above; **Fairy
Floss** is what ships, and `+` marks a definition appended after the shared
ones (`Colours.sailorhg`). Each sets only what it changes, by the rule that
a later definition's set attributes are over an earlier one's
(`Editor/Face.lean`).

| Vocabulary face | Shared | Fairy Floss | Source of the choice |
|---|---|---|---|
| `default` | foreground on background | the same | tmTheme global colours; base.less l.3–6 |
| `selection` | bg selection | the same | tmTheme `selection`; base.less l.47–49 |
| `cursor`, `cursor.*` | background on caret | the same | tmTheme `caret`, the same in every state |
| `mode-line` | foreground on lineHighlight, padded 3 | the same | Not in a syntax theme: shared mapping kept |
| `mode-line.active` | foreground on selection | the same | Not covered: shared mapping kept |
| `mode-line.inactive` | lavender on background | the same | Not covered: shared mapping kept |
| `window-divider` | fg lavender | the same | Not covered: shared mapping kept |
| `echo-area` | fg foreground, padded 3 | the same | The default face's foreground |
| `mode-line.state.normal` | background on renamed, bold | + background on pink (bold kept) | Not covered; pink is the lead accent. A choice |
| `mode-line.state.insert` | background on added, bold | the same | Not covered: shared mapping kept |
| `mode-line.state.visual`, `mode-line.state.visual-line` | background on pink, bold | + background on lavender (bold kept) | Not covered. The shared magenta is pink, normal's badge here, so visual takes lavender to differ from it. A choice |
| `mode-line.state.minibuffer` | background on mint, bold | the same | Not covered: shared mapping kept |
| `mode-line.buffer` | foreground, bold | the same | Not covered: shared mapping kept |
| `mode-line.modified` | fg peach | the same | Not covered: shared mapping kept |
| `mode-line.changed` | fg removed | the same | Not covered: shared mapping kept |
| `mode-line.secondary` | fg lavender | the same | Not covered: shared mapping kept |
| `minibuffer.prompt` | mint, bold | the same | Not covered: shared mapping kept |
| `minibuffer.candidate` | fg lavender | the same | Not covered: shared mapping kept |
| `minibuffer.chosen` | background on mint | the same | Not covered: shared mapping kept |
| `minibuffer.match` | renamed, bold | the same | Not covered: shared mapping kept |
| `minibuffer.annotation` | lavender, italic | the same | Not covered: shared mapping kept |
| `minibuffer.group` | foreground, bold | the same | Not covered: shared mapping kept |
| `tab-bar` | lavender on lineHighlight | the same | Not covered: shared mapping kept |
| `tab-bar.selected` | foreground on selection, bold | the same | Not covered: shared mapping kept |
| `compilation.error`, `compilation.warning`, `compilation.note` | fg removed, peach, added, bold | the same | Not covered: shared mapping kept |
| `syntax.attribute` | lemon | the same | tmTheme `entity.other.attribute-name` l.208 |
| `syntax.comment` | lavender, italic | + gold, upright | tmTheme `comment` l.38, no `fontStyle` |
| `syntax.constant` | lavender | the same | tmTheme l.71, l.82 |
| `syntax.constructor` | lemon | the same | `entity.name.class` l.143, its underline not followed |
| `syntax.embedded` | foreground | the same | Unmatched: the foreground |
| `syntax.function` | mint | + lemon | tmTheme `entity.name.function` l.169 |
| `syntax.keyword` | renamed | + pink | tmTheme `keyword` l.104, `storage` l.117 |
| `syntax.module` | lemon | the same | No namespace scope: shared mapping kept |
| `syntax.number` | lavender | the same | tmTheme `constant.numeric` l.60 |
| `syntax.operator` | renamed | + pink | `keyword.operator` falls under `keyword` l.104 |
| `syntax.property` | foreground | the same | Unmatched: the foreground |
| `syntax.punctuation` | lavender | + foreground | Unmatched: the foreground |
| `syntax.string` | added | + yellow | tmTheme `string` l.49 |
| `syntax.tag` | renamed | + pink | tmTheme `entity.name.tag` l.195 |
| `syntax.type` | lemon | + mint, italic | tmTheme `storage.type` l.130, `support.type` l.247 |
| `syntax.variable` | foreground | the same | tmTheme `variable` sets no colour; `variable.parameter`'s peach not followed |
| `diff.added` | fg added | the same | syntax-variables `@syntax-color-added` |
| `diff.removed` | fg removed | the same | syntax-variables `@syntax-color-removed` |
| `diff.changed` | fg lemon | + fg modified | syntax-variables `@syntax-color-modified` |
| `gutter` | lavender on lineHighlight | + foreground on background | syntax-variables gutter colours; base.less l.8–11 |
| `search-match` | background on lemon | the same | Atom marks it with a border: shared mapping kept |
| `review-unexamined` | peach single underline | the same | Not covered: shared mapping kept |
| `block-header` | foreground on lineHighlight, bold | the same | Not covered: shared mapping kept |

Pinned by `ModelTest.fairyFlossChecks`: the nineteen values, the commit,
and this table, read through `Theme.merged`. How the theme looks is left to
the owner's day-to-day use; what the CPU renderer draws of it is pinned by
`ffi-test theme-pictures` (`tests/render/themes`).
-/

namespace Editor.Themes.FairyFloss

/-- Fairy Floss's nineteen colours, each named for its colour in sailorhg's
description or for its tmTheme key (the module docs, "The published
colours"). -/
structure Colours where
  /-- The global background, and the gutter's. -/
  background : Color
  /-- The global foreground, and every scope the theme does not colour. -/
  foreground : Color
  /-- The caret; also `invalid`'s foreground. -/
  caret : Color
  /-- Invisible characters and indent guides. -/
  invisibles : Color
  /-- The cursor line and the selected gutter row. -/
  lineHighlight : Color
  /-- The selection. -/
  selection : Color
  /-- `comment`. -/
  gold : Color
  /-- `string`. -/
  yellow : Color
  /-- `constant.numeric`, `constant.language`, `constant.character`,
  `constant.other`. -/
  lavender : Color
  /-- `keyword`, `storage`, `entity.name.tag`. -/
  pink : Color
  /-- `storage.type`, `support.function`, `support.constant`,
  `support.type`, `support.class`. -/
  mint : Color
  /-- `entity.name.class`, `entity.other.inherited-class`,
  `entity.name.function`, `entity.other.attribute-name`. -/
  lemon : Color
  /-- `variable.parameter`. -/
  peach : Color
  /-- `invalid`'s background. -/
  invalid : Color
  /-- `invalid.deprecated`'s background. -/
  deprecated : Color
  /-- Atom's git-diff colour for a renamed line. -/
  renamed : Color
  /-- Atom's git-diff colour for an added line. -/
  added : Color
  /-- Atom's git-diff colour for a modified line. -/
  modified : Color
  /-- Atom's git-diff colour for a removed line. -/
  removed : Color
  deriving DecidableEq, Repr

/-- The commit of `sailorhg/fairyfloss` the colours are read from. -/
def commit : String :=
  "982e64a9e36160350125c0a82a7981dca6200150"

/-- Fairy Floss's published values (the module docs, "The published
colours"). -/
def published : Colours where
  background := Color.rgb 0x5a 0x54 0x75
  foreground := Color.rgb 0xf8 0xf8 0xf2
  caret := Color.rgb 0xf8 0xf8 0xf0
  invisibles := Color.rgb 0x3b 0x3a 0x32
  lineHighlight := Color.rgb 0x3e 0x3d 0x32
  selection := Color.rgb 0x49 0x48 0x3e
  gold := Color.rgb 0xe6 0xc0 0x00
  yellow := Color.rgb 0xff 0xea 0x00
  lavender := Color.rgb 0xc5 0xa3 0xff
  pink := Color.rgb 0xff 0xb8 0xd1
  mint := Color.rgb 0xc2 0xff 0xdf
  lemon := Color.rgb 0xff 0xf3 0x52
  peach := Color.rgb 0xff 0x85 0x7f
  invalid := Color.rgb 0xf9 0x26 0x72
  deprecated := Color.rgb 0xae 0x81 0xff
  renamed := Color.rgb 0x96 0xcb 0xfe
  added := Color.rgb 0xa8 0xff 0x60
  modified := Color.rgb 0xe9 0xc0 0x62
  removed := Color.rgb 0xcc 0x66 0x66

/-- The shared palette's roles (the module docs, "The shared palette's
roles"). -/
def Colours.palette (c : Colours) : Palette :=
  { paper := c.background, ink := c.foreground, cursor := c.caret, selected := c.selection
    raised := c.lineHighlight, strong := c.foreground, faint := c.lavender, red := c.removed
    orange := c.peach, yellow := c.lemon, green := c.added, cyan := c.mint, blue := c.renamed
    violet := c.lavender, magenta := c.pink }

/-- The definitions where the tmTheme or the Atom styles give a face another
colour than the shared mapping: the rows marked `+` in the module docs'
table, in vocabulary order. -/
def Colours.sailorhg (c : Colours) : Theme :=
  let ink (name : String) (foreground : Color) : FaceDefinition :=
    { name := ⟨name⟩, face := { foreground := some foreground } }
  let defined (name : String) (face : Face) : FaceDefinition := { name := ⟨name⟩, face }
  let badge (state : String) (accent : Color) : FaceDefinition :=
    { name := ⟨s!"mode-line.state.{state}"⟩
      face := { foreground := some c.background, background := some accent } }
  #[badge "normal" c.pink, badge "visual" c.lavender, badge "visual-line" c.lavender,
    defined "syntax.comment" { foreground := some c.gold, slant := some .upright },
    ink "syntax.function" c.lemon, ink "syntax.keyword" c.pink, ink "syntax.operator" c.pink,
    ink "syntax.punctuation" c.foreground, ink "syntax.string" c.yellow, ink "syntax.tag" c.pink,
    defined "syntax.type" { foreground := some c.mint, slant := some .italic },
    ink "diff.changed" c.modified,
    defined "gutter" { foreground := some c.foreground, background := some c.background }]

/-- The one mapping: the palette's theme (`Palette.theme`), then Fairy
Floss's own definitions after it. -/
def Colours.theme (c : Colours) : Theme :=
  c.palette.theme ++ c.sailorhg

/-- Fairy Floss: the mapping over the published colours. -/
def fairyFloss : NamedTheme :=
  { name := "fairy-floss", theme := published.theme }

end Editor.Themes.FairyFloss
