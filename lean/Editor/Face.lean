import Editor.Scene

/-!
# Faces

What a face looks like. The scene names faces and says nothing of how they
look (`Editor/Scene.lean`); this is the other half: a face as a set of
optional attributes, a definition that gives a name its attributes, and a
theme, which is a list of definitions.

Lean only describes. It merges nothing it sends: which face wins where two
cover the same text, and what an attribute no face sets falls back to, are
layout's rules in the Rust library (`crates/editor-layout/src/face.rs`, "The
precedence"). The one exception is for checking a theme: `Face.over` and
`Theme.merged` model layout's merge so that the completeness check
(`Editor/Themes/Check.lean`) can know a cursor's colours with no layout.
What they give is never sent or drawn, and `ConfigTest.cursorResolutionChecks`
holds the model to the real layout. What matters here is the one rule that orders a list of
definitions: **where a list defines a name more than once, a later
definition's set attributes are over an earlier one's.** So a theme is
overridden by appending to it, and config's definitions are appended to the
theme in force (`Editor/Config/Reload.lean`): a face config sets takes
config's attributes over the theme's, attribute by attribute, and a face
config stops setting is the theme's again.

A theme has a name when it is registered (`NamedTheme`), as a command does
(`Editor/Config/Registry.lean`, "Themes"). The built-in theme is the one
called `default` (`Theme.defaultName`), in force until config names another
or one is loaded. `Theme.unknown` is the one sentence said of a name no
theme is registered under, by a reload and by the command that loads a
theme.

The real binding of the display sends a theme with a scene, in the same
call, and only when the theme changed (`Editor/Display/Real.lean`).

## Units

- A colour is red, green, blue and alpha, each 0 to 255 (`Color`).
- A length is a whole number of 64ths of a logical point (`Pixels`), and a
  numeric literal is whole points: `size := some 14`. A point is one
  physical pixel on a display at scale 1 and two at scale 2: what a window
  system calls a logical pixel, not the typographic point of a 72nd of an
  inch. A theme states points, and layout in the Rust library multiplies
  each length by the scale factor of the window it lays out for, before it
  shapes (`crates/editor-layout/src/face.rs`, "Units"). So a face is the
  same apparent size on every display, and nothing here knows a scale: Lean
  multiplies nothing, and reads no scale to state a face. The type keeps
  the name `Pixels` from when a theme stated physical pixels.
- A face's lengths are its size, a line height stated as a length, and its
  vertical padding. A status field's horizontal padding is the field's own
  (`StatusField.padding`, `Editor/Scene.lean`), in whole points too.
- Only a face's lengths and a status field's padding are points. A
  scene's sizes and rectangles
  (`Editor/Scene.lean`), a pointer's position and a resize's size
  (`Editor/Event.lean`) are physical pixels, as before.
- A weight is 1 to 1000: 400 is normal and 700 bold. The binding sends a
  weight outside that range as the nearest end of it.
- A size or a line height of 0 is sent as it is. The lines of such a font
  have no height, and how many of them a view shows is layout's rule
  (`crates/editor-layout/src/query.rs`, "The rows that fit").

## The built-in faces

`Theme.builtin`, the theme `default`, is the placeholder palette's theme
(`Palette.placeholder`, `Palette.theme`): it defines every face of the
vocabulary (`Face.vocabulary`, `Editor/Face/Vocabulary.lean`), `default`
first, which sets every attribute. Layout reads four names by itself:
`default`, under every other face; `selection`, which the selections are
drawn in; `mode-line`, under each field of a view's status line; and
`echo-area`, the echo in the frame's bottom row. Any other name is whatever
a scene names and a theme or config defines: a name nothing defines sets
nothing. So a cursor in a face nothing defines has the default face's
paint, and is drawn in the paper's colour on the paper: it cannot be seen.
That is why the palette mapping gives each state of the shipped scheme its
cursor face (`Theme.cursorStates`), the paper on the palette's cursor
colour; a state config registers needs config to define its face. Its
colours are placeholders.

## Where an addition goes

A new attribute is a field of `Face` here, a field of `Face` in
`crates/editor-layout/src/face.rs`, and two words of a definition as it
crosses (`crates/editor-ffi/src/display/wire.rs`, written by
`RealDisplay.encodeFace`), and a line of `Face.over`. The vertical padding
was added so: it is neither font nor paint, and layout reads it only where
it sizes a status row. A new face a feature
draws is an entry of the vocabulary and a definition in `Palette.theme`.
A new shipped theme is a `Palette`, its theme plus the theme's own
definitions after it where it differs from the shared mapping, and a
`NamedTheme` of that in `Themes.shipped` (`Editor/Themes/Compiled.lean`),
which the completeness check holds; Solarized is written so
(`Editor/Themes/Solarized.lean`). A face naming another as its base is not built.
-/

namespace Editor

/-- A colour, as one word: `0xRRGGBBAA`. -/
structure Color where
  /-- The red, green, blue and alpha bytes, red first. -/
  word : UInt32
  deriving DecidableEq, Repr

/-- The colour of `red`, `green`, `blue` and `alpha`, each 0 to 255. -/
def Color.rgba (red green blue alpha : UInt8) : Color :=
  {
    word :=
      red.toUInt32 <<< 24 ||| green.toUInt32 <<< 16 ||| blue.toUInt32 <<< 8 ||| alpha.toUInt32 }

/-- The opaque colour of `red`, `green` and `blue`, each 0 to 255. -/
def Color.rgb (red green blue : UInt8) : Color :=
  Color.rgba red green blue 255

/-- A length a face states, in 64ths of a logical point: one physical pixel
at scale 1, which layout multiplies by the window's scale factor. A numeric
literal is whole points. The name is from when a theme stated physical
pixels. -/
structure Pixels where
  /-- The length, in 64ths of a point. -/
  sixtyFourths : UInt32
  deriving DecidableEq, Repr

/-- `pixels` whole points; the longest length for more than a `Pixels`
holds. -/
def Pixels.whole (pixels : Nat) : Pixels :=
  { sixtyFourths := (min (pixels * 64) (UInt32.size - 1)).toUInt32 }

instance {pixels : Nat} : OfNat Pixels pixels :=
  ⟨Pixels.whole pixels⟩

/-- A font's slant. -/
inductive Slant where
  /-- Upright. -/
  | upright
  /-- The family's italic design. -/
  | italic
  /-- The upright design, slanted. -/
  | oblique
  deriving DecidableEq, Repr

/-- How an underline is drawn. -/
inductive UnderlineStyle where
  /-- No underline: a face sets this to take away the underline of a face
  under it. -/
  | none
  /-- One line. -/
  | single
  /-- Two lines. -/
  | double
  /-- A wavy line. -/
  | curly
  /-- A dotted line. -/
  | dotted
  /-- A dashed line. -/
  | dashed
  deriving DecidableEq, Repr

/-- An underline, as a face sets it. -/
structure Underline where
  /-- Its style. -/
  style : UnderlineStyle
  /-- Its colour; with none, the foreground of the text it is under. -/
  color : Option Color := none
  deriving DecidableEq, Repr

/-- How tall the lines of a font are. -/
inductive LineHeight where
  /-- A multiple of the font's own line height at its size, in 64ths: 64 is
  the font's own, and 96 one and a half times it. -/
  | multiple (sixtyFourths : UInt32)
  /-- A height in points, whatever the font's own: layout multiplies it by
  the window's scale factor, as it does a size. -/
  | pixels (height : Pixels)
  deriving DecidableEq, Repr

/-- A face: each attribute set, or left unset to be whatever the faces under
it make it. -/
structure Face where
  /-- The font family's name. -/
  family : Option String := none
  /-- The font's size. -/
  size : Option Pixels := none
  /-- The font's weight, 1 to 1000: 400 is normal and 700 bold. -/
  weight : Option Nat := none
  /-- The font's slant. -/
  slant : Option Slant := none
  /-- The colour of the glyphs. -/
  foreground : Option Color := none
  /-- The colour behind them. -/
  background : Option Color := none
  /-- The underline. -/
  underline : Option Underline := none
  /-- Whether a line is drawn through the glyphs. -/
  strikeThrough : Option Bool := none
  /-- The line height. -/
  lineHeight : Option LineHeight := none
  /-- The space above and below the line of a status row drawn in it, in
  points. Layout reads it only from `mode-line` and `echo-area`, where it
  makes the status rows taller (`Display.Heights`); a field's face or a
  view's status face may set it, and it is ignored there. -/
  verticalPadding : Option Pixels := none
  deriving DecidableEq, Repr

/-- A definition: the attributes a name sets. -/
structure FaceDefinition where
  /-- The face's name. -/
  name : FaceName
  /-- What it sets. -/
  face : Face
  deriving DecidableEq, Repr

/-- A theme: definitions, in the order they were made. Where it defines a
name more than once, a later definition's set attributes are over an earlier
one's. -/
abbrev Theme :=
  Array FaceDefinition

/-- `upper` over `lower`: each attribute `upper` sets, and `lower`'s where
`upper` sets none. Layout's merge, modelled for the completeness check
alone ("Lean only describes", in the module docs). -/
def Face.over (upper lower : Face) : Face where
  family := upper.family <|> lower.family
  size := upper.size <|> lower.size
  weight := upper.weight <|> lower.weight
  slant := upper.slant <|> lower.slant
  foreground := upper.foreground <|> lower.foreground
  background := upper.background <|> lower.background
  underline := upper.underline <|> lower.underline
  strikeThrough := upper.strikeThrough <|> lower.strikeThrough
  lineHeight := upper.lineHeight <|> lower.lineHeight
  verticalPadding := upper.verticalPadding <|> lower.verticalPadding

/-- The face `theme` gives `name`: its definitions of `name` in order, each
later one over the ones before; the empty face for a name it does not
define. For the completeness check alone: what is sent is the definitions,
unmerged. -/
def Theme.merged (theme : Theme) (name : FaceName) : Face :=
  theme.foldl
    (fun merged definition =>
      if definition.name == name then definition.face.over merged else merged)
    {}

/-- Whether `theme` defines `name`: gives it a definition, if only an empty
one, which draws the name in the faces under it. -/
def Theme.defines (theme : Theme) (name : FaceName) : Bool :=
  theme.any (·.name == name)

/-- The editing states of the shipped Vim scheme
(`Editor/InputScheme/Vim/Default.lean`), whose cursors are drawn in the face
`cursor.` followed by the state's name (`Vim.cursorFace`). The palette
mapping gives each a cursor face; the completeness check reads the states
from the scheme itself, so a state added there and not here fails it. -/
def Theme.cursorStates : Array String :=
  #["normal", "insert", "visual", "visual-line", "minibuffer"]

/-- The named colours a theme is written from (`Palette.theme`), so that one
mapping serves a light and a dark variant. -/
structure Palette where
  /-- The default face's background. -/
  paper : Color
  /-- The default face's foreground. -/
  ink : Color
  /-- The background of a mode line, a block header and the gutter. -/
  raised : Color
  /-- The selection's background. -/
  selected : Color
  /-- Text that recedes: comments, the gutter's numbers, an inactive mode
  line's text. -/
  faint : Color
  /-- Text that stands out: the mode line's and the echo area's. -/
  strong : Color
  /-- Every cursor's background; by default the ink. -/
  cursor : Color := ink
  /-- An accent: red. -/
  red : Color
  /-- An accent: orange. -/
  orange : Color
  /-- An accent: yellow. -/
  yellow : Color
  /-- An accent: green. -/
  green : Color
  /-- An accent: cyan. -/
  cyan : Color
  /-- An accent: blue. -/
  blue : Color
  /-- An accent: violet. -/
  violet : Color
  /-- An accent: magenta. -/
  magenta : Color
  deriving DecidableEq, Repr

/-- The theme `palette` gives: `default`, which sets every attribute, with
the ink on the paper; then `cursor` and a cursor face for each of
`Theme.cursorStates`, the paper on the cursor colour; then one definition
for each other face of the vocabulary (`Editor/Face/Vocabulary.lean`), each
setting only what it changes. -/
def Palette.theme (palette : Palette) : Theme :=
  let on (name : String) (foreground background : Color) : FaceDefinition :=
    { name := ⟨name⟩, face := { foreground := some foreground, background := some background } }
  let ink (name : String) (foreground : Color) : FaceDefinition :=
    { name := ⟨name⟩, face := { foreground := some foreground } }
  let defined (name : String) (face : Face) : FaceDefinition := { name := ⟨name⟩, face }
  let cursors := #["cursor"] ++ Theme.cursorStates.map (s!"cursor.{·}")
  #[defined "default"
        { family := some "monospace", size := some 16, weight := some 400, slant := some .upright
          foreground := some palette.ink, background := some palette.paper
          underline := some { style := .none }, strikeThrough := some false
          lineHeight := some (.multiple 64), verticalPadding := some 0 }] ++
    cursors.map (on · palette.paper palette.cursor) ++
    #[defined "selection" { background := some palette.selected },
      on "mode-line" palette.strong palette.raised, ink "echo-area" palette.strong,
      defined "status.state" { foreground := some palette.blue, weight := some 700 },
      ink "status.name" palette.strong, ink "status.modified" palette.orange,
      on "mode-line.inactive" palette.faint palette.raised,
      defined "minibuffer.prompt" { foreground := some palette.cyan, weight := some 700 },
      ink "minibuffer.candidate" palette.faint, on "minibuffer.chosen" palette.paper palette.cyan,
      ink "syntax.attribute" palette.yellow,
      defined "syntax.comment" { foreground := some palette.faint, slant := some .italic },
      ink "syntax.constant" palette.violet, ink "syntax.constructor" palette.yellow,
      ink "syntax.embedded" palette.ink, ink "syntax.function" palette.cyan,
      ink "syntax.keyword" palette.blue, ink "syntax.module" palette.yellow,
      ink "syntax.number" palette.violet, ink "syntax.operator" palette.blue,
      ink "syntax.property" palette.ink, ink "syntax.punctuation" palette.faint,
      ink "syntax.string" palette.green, ink "syntax.tag" palette.blue,
      ink "syntax.type" palette.yellow, ink "syntax.variable" palette.ink,
      ink "diff.added" palette.green, ink "diff.removed" palette.red,
      ink "diff.changed" palette.yellow, on "gutter" palette.faint palette.raised,
      on "search-match" palette.paper palette.yellow,
      defined "review-unexamined"
        { underline := some { style := .single, color := some palette.orange } },
      defined "block-header"
        { foreground := some palette.strong, background := some palette.raised,
          weight := some 700 }]

/-- The palette of the built-in theme: Nord's colours. They are
placeholders. -/
def Palette.placeholder : Palette where
  paper := Color.rgb 46 52 64
  ink := Color.rgb 216 222 233
  raised := Color.rgb 59 66 82
  selected := Color.rgb 67 76 94
  faint := Color.rgb 97 110 136
  strong := Color.rgb 236 239 244
  red := Color.rgb 191 97 106
  orange := Color.rgb 208 135 112
  yellow := Color.rgb 235 203 139
  green := Color.rgb 163 190 140
  cyan := Color.rgb 136 192 208
  blue := Color.rgb 129 161 193
  violet := Color.rgb 180 142 173
  magenta := Color.rgb 191 97 106

/-- The built-in theme, the theme `default`: the placeholder palette's
(`Palette.theme`). -/
def Theme.builtin : Theme :=
  Palette.placeholder.theme

/-- A theme with the name it is registered and chosen by
(`Editor/Config/Registry.lean`, "Themes"). In force, it stands in for
`Theme.builtin` wholesale, so it defines every face it needs; a theme that
keeps the built-in faces is built as `Theme.builtin ++ #[…]`. -/
structure NamedTheme where
  /-- The theme's name. -/
  name : String
  /-- Its definitions. -/
  theme : Theme
  deriving DecidableEq, Repr

/-- The name of the built-in theme, `Theme.builtin`, registered by compiled
code: the theme in force when no config has named one. -/
def Theme.defaultName : String :=
  "default"

/-- What is said of the theme name `name` when no theme is registered under
it: by a reload whose config names it, and by the command that loads a
theme. -/
def Theme.unknown (name : String) : String :=
  s!"no theme is registered as `{name}`"

end Editor
