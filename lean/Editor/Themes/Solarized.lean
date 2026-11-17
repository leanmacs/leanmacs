import Editor.Face

/-!
# Solarized, light and dark

Ethan Schoonover's Solarized: sixteen colours, eight base tones and eight
accents, whose light and dark variants share the accents and swap the base
tones. `published` holds the sixteen values; `Colours.theme` is the one
mapping from them to the face vocabulary (`Editor/Face/Vocabulary.lean`),
written in the dark names; `dark` applies it to the published colours and
`light` to them with the base pairs swapped (`Colours.light`), as the
specification and Schoonover's own themes do. Both are shipped
(`Themes.shipped`, `Editor/Themes/Compiled.lean`).

## The source, and the licence

The values are those of the table "The Values" in `README.md` of the
repository `altercation/solarized`, at commit
`62f656a02f93c5190a8753159e34b385588d5ff3`, and of ethanschoonover.com/solarized;
the same sixteen appear verbatim in that commit's
`vim-colors-solarized/colors/solarized.vim` and
`emacs-colors-solarized/color-theme-solarized.el`. Solarized is
MIT-licensed. Its notice is beside this file, as
`Solarized-LICENSE.txt`: the `LICENSE` file of that repository at that
commit, byte for byte, 1061 bytes, sha256
`494aefdabf86acce06bd63001ad8aedad4ee38da23509d3f917d95aa3368b9a6`. The
colours are values, but the notice is kept because the palette and the
mapping follow Schoonover's published work and themes.

## The roles the specification names

In the dark names; light swaps them. base03 is the background; base02 the
background highlights; base01 comments and secondary content; base0 body
text; base1 optional emphasized content ("the normal relationship for
background and body text is `base03:base0`", "text can be highlighted
using a combination of `base02:base1`"). Light is the same with base03 and
base3, base02 and base2, base01 and base1, and base00 and base0 swapped:
`solarized.vim`'s "Alternate light scheme", and `rotatef` in
`color-theme-solarized.el`.

So the shared palette's roles (`Palette`, `Editor/Face.lean`) are: the
paper base03, the ink base0, raised and selected base02, faint base01,
strong base1, the cursor base0, and each accent the accent of its name
(`Colours.palette`).

## The roles the specification does not name, and the choice made

Every row is a choice. The sources are `solarized.vim` (Vim) and
`color-theme-solarized.el` (Emacs, Greg Pfeil's port shipped in
Schoonover's repository), at the commit above. **Shared** is what
`Palette.theme` gives with the roles above; **Solarized** is what ships, in
dark names, and `+` marks a definition appended after the shared ones
(`Colours.schoonover`).

| Vocabulary face | Shared | Solarized | Source of the choice |
|---|---|---|---|
| `selection` | bg base02 | bg base02 | Emacs `region` bg base02, and the specification's background highlight. Vim's `Visual` (base01 reversed) needs a selection foreground, which the shared mapping does not set: not followed |
| `cursor`, `cursor.normal/insert/visual/visual-line/minibuffer` | base03 on base0 | base03 on base0 | Vim `Cursor` fg base03 bg base0; Emacs `cursor-color` base0. Vim and Emacs colour the cursor the same in every state |
| `mode-line` | base1 on base02, padded 3 | base1 on base02, padded 3 | Emacs `mode-line` fg base1 bg base02. Vim's `StatusLine` is the same pair reversed: not followed, because `echo-area` and `mode-line.buffer` share `strong`. The padding is the owner's picked look, shared |
| `mode-line.inactive` | base01 on base02 | + base0 on base02 | Emacs `mode-line-inactive` fg base0 bg base02 |
| `echo-area` | fg base1, padded 3 | + fg base0 (padding kept) | Emacs and Vim draw messages in the default face (Vim `Normal` base0) |
| `mode-line.state.normal` | base03 on blue, bold | base03 on blue, bold | lualine.nvim `solarized_dark` section `a` of `normal` (below) |
| `mode-line.state.insert` | base03 on green, bold | base03 on green, bold | lualine.nvim `solarized_dark` `insert` |
| `mode-line.state.visual`, `mode-line.state.visual-line` | base03 on magenta, bold | base03 on magenta, bold | lualine.nvim `solarized_dark` `visual`, which Vim's visual-line state shares |
| `mode-line.state.minibuffer` | base03 on cyan, bold | base03 on cyan, bold | lualine.nvim has no such mode; the shared mapping is kept, and the minibuffer's view draws no badge |
| `mode-line.buffer` | base1, bold | base1, bold | Emacs `mode-line-buffer-id` base1, bold |
| `mode-line.modified` | fg orange | fg orange | Neither theme has one. The shared mapping is kept |
| `mode-line.changed` | fg red | fg red | Neither theme has one. The shared mapping is kept |
| `mode-line.secondary` | fg base01 | fg base01 | The specification's "base01 secondary content" |
| `minibuffer.prompt` | cyan, bold | + fg blue (bold kept) | Emacs `minibuffer-prompt` blue |
| `minibuffer.candidate` | fg base01 | + fg base1 | Vim's wildmenu draws the other candidates in `StatusLine`, the status-line text (base1) |
| `minibuffer.chosen` | base03 on cyan | + base02 on base2 | Vim `WildMenu` (fg base2 bg base02 reversed) |
| `tab-bar` | base01 on base02 | + base0 on base02 | Vim `TabLine` fg base0 bg base02; its underline is not followed |
| `tab-bar.selected` | base1 on base02, bold | + base2 on base01, bold | Vim `TabLineSel` (fg base01 bg base2 reversed, bold); its underline is not followed |
| `compilation.error`, `compilation.warning`, `compilation.note` | fg red, orange, green, bold | fg red, orange, green, bold | Emacs `compilation-error`, `-warning`, `-info` inherit `error`, `warning`, `success`: the shared mapping's red, orange and green are kept |
| `syntax.attribute` | yellow | + orange | Vim `PreProc` |
| `syntax.comment` | base01, italic | base01, italic | Vim `Comment`; Emacs `font-lock-comment-face` |
| `syntax.constant` | violet | + cyan | Vim `Constant`; Emacs `font-lock-constant-face` |
| `syntax.constructor` | yellow | yellow | Vim `Type` (Structure) |
| `syntax.embedded` | base0 | base0 | Neither theme has one. The shared mapping is kept |
| `syntax.function` | cyan | + blue | Vim `Identifier` (Function); Emacs `font-lock-function-name-face` |
| `syntax.keyword` | blue | + green | Vim `Statement` (Keyword); Emacs `font-lock-keyword-face` |
| `syntax.module` | yellow | + orange | Vim `PreProc` (Include) |
| `syntax.number` | violet | + cyan | Vim `Constant` (Number) |
| `syntax.operator` | blue | + green | Vim `Statement` (Operator) |
| `syntax.property` | base0 | + blue | Vim `Identifier`; Emacs `font-lock-variable-name-face` |
| `syntax.punctuation` | base01 | + red | Vim `Special` (Delimiter) |
| `syntax.string` | green | + cyan | Vim `Constant` (String); Emacs `font-lock-string-face` |
| `syntax.tag` | blue | + red | Vim `Special` (Tag) |
| `syntax.type` | yellow | yellow | Vim `Type`; Emacs `font-lock-type-face` |
| `syntax.variable` | base0 | + blue | Vim `Identifier`; Emacs `font-lock-variable-name-face` |
| `diff.added/removed/changed` | fg green/red/yellow | + green/red/yellow on base02 | Vim `DiffAdd`/`DiffDelete`/`DiffChange`, the default diffmode "normal" (non-GUI branch) |
| `gutter` | base01 on base02 | base01 on base02 | Vim `LineNr`; Emacs `fringe` |
| `search-match` | base03 on yellow | base03 on yellow | Vim `Search` and Emacs `isearch`: yellow reversed |
| `review-unexamined` | orange single underline | orange single underline | Neither theme has one. The shared mapping is kept |
| `block-header` | base1 on base02, bold | base1 on base02, bold | The specification's highlighted pair `base02:base1`, its own example being Vim's folded text |

**The badges follow lualine.nvim**, since neither of Schoonover's themes
colours a mode line by state. Its `lua/lualine/themes/solarized_dark.lua`
(by shadmansaleh, MIT, crediting itchyny's lightline) gives section `a`
`base03` on `blue` in normal, on `green` in insert and on `magenta` in
visual, all bold, and section `c` `base1` on `base02`, which is
`mode-line` here. The shared mapping already gives exactly these (the
paper, base03, on the accents), so no `+` row is needed, and the light
variant's swap gives base3 on them. `solarized_light.lua` agrees with the
swap: its colour table names `#fdf6e3`, Schoonover's base3, as its
`base03`, so its badges are base3 on the same accents. Both files are read
at lualine.nvim's commit `221ce6b2d999187044529f49da6554a92f740a96` (its
`master` on 2026-05-31; neither file has changed since
`db448f41e66b1a58941c231fbb47198f2b7f2f6a`): `solarized_dark.lua`, 1151
bytes, sha256
`08618fc3bef548387c84ee7b9aefd192e7313581c188b15319d11c5631589479`, and
`solarized_light.lua`, 1151 bytes, sha256
`3c4e5130c78457354266c0661a00e5086884f4c49c8dc08858d73e8ab72bad65`. Only
the choice of colours is taken from it; no code and no text.

The appended definitions rely on the rule that a later definition's set
attributes are over an earlier one's (`Editor/Face.lean`): each sets only
the colours it changes, so `minibuffer.prompt` stays bold.

Pinned by `ModelTest.solarizedChecks`: the sixteen values, the swap, and
this table, read through `Theme.merged` for each variant. How the themes
look is left to the owner's day-to-day use; what the CPU renderer draws of
each is pinned by `ffi-test theme-pictures` (`tests/render/themes`).
-/

namespace Editor.Themes.Solarized

/-- Solarized's sixteen colours: the eight base tones, darkest first, and
the eight accents. Read as the dark variant's; `Colours.light` swaps the
base tones for the light one. -/
structure Colours where
  /-- The darkest base tone: the dark background. -/
  base03 : Color
  /-- The dark background highlights. -/
  base02 : Color
  /-- Dark comments and secondary content; light optional emphasis. -/
  base01 : Color
  /-- The light body text. -/
  base00 : Color
  /-- The dark body text. -/
  base0 : Color
  /-- Dark optional emphasis; light comments and secondary content. -/
  base1 : Color
  /-- The light background highlights. -/
  base2 : Color
  /-- The lightest base tone: the light background. -/
  base3 : Color
  /-- An accent: yellow. -/
  yellow : Color
  /-- An accent: orange. -/
  orange : Color
  /-- An accent: red. -/
  red : Color
  /-- An accent: magenta. -/
  magenta : Color
  /-- An accent: violet. -/
  violet : Color
  /-- An accent: blue. -/
  blue : Color
  /-- An accent: cyan. -/
  cyan : Color
  /-- An accent: green. -/
  green : Color
  deriving DecidableEq, Repr

/-- Solarized's published values (the module docs, "The source"). -/
def published : Colours where
  base03 := Color.rgb 0x00 0x2b 0x36
  base02 := Color.rgb 0x07 0x36 0x42
  base01 := Color.rgb 0x58 0x6e 0x75
  base00 := Color.rgb 0x65 0x7b 0x83
  base0 := Color.rgb 0x83 0x94 0x96
  base1 := Color.rgb 0x93 0xa1 0xa1
  base2 := Color.rgb 0xee 0xe8 0xd5
  base3 := Color.rgb 0xfd 0xf6 0xe3
  yellow := Color.rgb 0xb5 0x89 0x00
  orange := Color.rgb 0xcb 0x4b 0x16
  red := Color.rgb 0xdc 0x32 0x2f
  magenta := Color.rgb 0xd3 0x36 0x82
  violet := Color.rgb 0x6c 0x71 0xc4
  blue := Color.rgb 0x26 0x8b 0xd2
  cyan := Color.rgb 0x2a 0xa1 0x98
  green := Color.rgb 0x85 0x99 0x00

/-- `c` with its four base pairs swapped and its accents kept: the light
variant's colours under the dark names, as Schoonover's Vim and Emacs
themes swap them. -/
def Colours.light (c : Colours) : Colours :=
  { c with
    base03 := c.base3, base3 := c.base03, base02 := c.base2, base2 := c.base02, base01 := c.base1
    base1 := c.base01, base00 := c.base0, base0 := c.base00 }

/-- The shared palette's roles, in the dark names (the module docs, "The
roles the specification names"). -/
def Colours.palette (c : Colours) : Palette :=
  { paper := c.base03, ink := c.base0, raised := c.base02, selected := c.base02, faint := c.base01
    strong := c.base1, red := c.red, orange := c.orange, yellow := c.yellow, green := c.green
    cyan := c.cyan, blue := c.blue, violet := c.violet, magenta := c.magenta }

/-- The definitions where Schoonover's Vim or Emacs theme gives a face
another colour than the shared mapping: the rows marked `+` in the module
docs' table, in the dark names. -/
def Colours.schoonover (c : Colours) : Theme :=
  let ink (name : String) (foreground : Color) : FaceDefinition :=
    { name := ⟨name⟩, face := { foreground := some foreground } }
  let on (name : String) (foreground background : Color) : FaceDefinition :=
    { name := ⟨name⟩, face := { foreground := some foreground, background := some background } }
  #[on "mode-line.inactive" c.base0 c.base02, ink "echo-area" c.base0,
    ink "minibuffer.prompt" c.blue, ink "minibuffer.candidate" c.base1,
    on "minibuffer.chosen" c.base02 c.base2, on "tab-bar" c.base0 c.base02,
    { name := ⟨"tab-bar.selected"⟩
      face := { foreground := some c.base2, background := some c.base01, weight := some 700 } },
    ink "syntax.attribute" c.orange, ink "syntax.constant" c.cyan, ink "syntax.function" c.blue,
    ink "syntax.keyword" c.green, ink "syntax.module" c.orange, ink "syntax.number" c.cyan,
    ink "syntax.operator" c.green, ink "syntax.property" c.blue, ink "syntax.punctuation" c.red,
    ink "syntax.string" c.cyan, ink "syntax.tag" c.red, ink "syntax.variable" c.blue,
    on "diff.added" c.green c.base02, on "diff.removed" c.red c.base02,
    on "diff.changed" c.yellow c.base02]

/-- The one mapping: the palette's theme (`Palette.theme`), then
Schoonover's own definitions after it. -/
def Colours.theme (c : Colours) : Theme :=
  c.palette.theme ++ c.schoonover

/-- Solarized dark: the mapping over the published colours. -/
def dark : NamedTheme :=
  { name := "solarized-dark", theme := published.theme }

/-- Solarized light: the mapping over the published colours with the base
pairs swapped. -/
def light : NamedTheme :=
  { name := "solarized-light", theme := published.light.theme }

end Editor.Themes.Solarized
