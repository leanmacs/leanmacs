import Editor.Scene

/-!
# Faces

What a face looks like. The scene names faces and says nothing of how they
look (`Editor/Scene.lean`); this is the other half: a face as a set of
optional attributes, a definition that gives a name its attributes, and a
theme, which is a list of definitions.

Lean only describes. It merges nothing: which face wins where two cover the
same text, and what an attribute no face sets falls back to, are layout's
rules in the Rust library (`crates/editor-layout/src/face.rs`, "The
precedence"). What matters here is the one rule that orders a list of
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
- Only a face's lengths are points. A scene's sizes and rectangles
  (`Editor/Scene.lean`), a pointer's position and a resize's size
  (`Editor/Event.lean`) are physical pixels, as before.
- A weight is 1 to 1000: 400 is normal and 700 bold. The binding sends a
  weight outside that range as the nearest end of it.
- A size or a line height of 0 is sent as it is. The lines of such a font
  have no height, and how many of them a view shows is layout's rule
  (`crates/editor-layout/src/query.rs`, "The rows that fit").

## The built-in faces

`Theme.builtin`, the theme `default`, defines `default` (every attribute set), `cursor`, a
cursor face for each editing state of the shipped Vim scheme
(`cursor.normal`, `cursor.insert`, `cursor.visual`, `cursor.visual-line`
and `cursor.minibuffer`, `Theme.cursorStates`), `selection`, `echo-area`,
`minibuffer-prompt` and `mode-line`. Layout reads three names by itself:
`default`, under every other face; `selection`, which the selections are
drawn in; and `mode-line`, under each field of a view's status line.
`echo-area` and `minibuffer-prompt` are defined and nothing draws them yet.
Any other name is whatever a scene names and a theme or config defines: a
name nothing defines sets nothing. So a cursor in a face nothing defines
has the default face's paint, and is drawn in the paper's colour on the
paper: it cannot be seen. That is why each state the shipped scheme has
gets its cursor face here, each the default face's colours the other way
round (`Face.cursor`), and why a state added to the shipped scheme is added
to `Theme.cursorStates`; a state config registers needs config to define
its face. Its colours are placeholders.

## Where an addition goes

A new attribute is a field of `Face` here, a field of `Face` in
`crates/editor-layout/src/face.rs`, and two words of a definition as it
crosses (`crates/editor-ffi/src/display/wire.rs`, written by
`RealDisplay.encodeFace`). A new built-in face is a definition in
`Theme.builtin`, and a name in `ModelTest.faceChecks`. A new shipped theme
is a `NamedTheme` in `Themes.shipped` (`Editor/Themes/Compiled.lean`). A
face naming another as its base is not built.
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

/-- What the built-in cursor faces set: the default face's colours the other
way round, so that a block is the text's colour with the glyph under it in
the paper's, and a bar, an underline or a hollow box is the text's colour. -/
def Face.cursor : Face :=
  { foreground := some (Color.rgb 46 52 64), background := some (Color.rgb 216 222 233) }

/-- The editing states of the shipped Vim scheme
(`Editor/InputScheme/Vim/Default.lean`), whose cursors are drawn in the face
`cursor.` followed by the state's name (`Vim.cursorFace`). -/
def Theme.cursorStates : Array String :=
  #["normal", "insert", "visual", "visual-line", "minibuffer"]

/-- The built-in theme: `default`, which sets every attribute, then
`cursor` and a cursor face for each of `Theme.cursorStates`, `selection`,
`echo-area`, `minibuffer-prompt` and `mode-line`, each of which sets only
what it changes. Its colours are placeholders. -/
def Theme.builtin : Theme :=
  #[{   name := ⟨"default"⟩
        face :=
          { family := some "monospace", size := some 16, weight := some 400, slant := some .upright
            foreground := some (Color.rgb 216 222 233), background := some (Color.rgb 46 52 64)
            underline := some { style := .none }, strikeThrough := some false
            lineHeight := some (.multiple 64) } },
      { name := ⟨"cursor"⟩, face := Face.cursor }] ++
    Theme.cursorStates.map (fun state => { name := ⟨s!"cursor.{state}"⟩, face := Face.cursor }) ++
    #[{ name := ⟨"selection"⟩, face := { background := some (Color.rgb 67 76 94) } },
      { name := ⟨"echo-area"⟩, face := { foreground := some (Color.rgb 229 233 240) } },
      { name := ⟨"minibuffer-prompt"⟩
        face := { foreground := some (Color.rgb 136 192 208), weight := some 700 } },
      { name := ⟨"mode-line"⟩
        face :=
          { foreground := some (Color.rgb 236 239 244), background := some (Color.rgb 59 66 82) } }]

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
