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
built-in theme (`Editor/Config/Reload.lean`): a face config sets takes
config's attributes over the theme's, attribute by attribute, and a face
config stops setting is the theme's again.

The real binding of the display sends a theme with a scene, in the same
call, and only when the theme changed (`Editor/Display/Real.lean`).

## Units

- A colour is red, green, blue and alpha, each 0 to 255 (`Color`).
- A length is a whole number of 64ths of a physical pixel (`Pixels`), and a
  numeric literal is whole pixels: `size := some 14`. Nothing scales a
  length by a window's scale factor: a theme states physical pixels.
- A weight is 1 to 1000: 400 is normal and 700 bold. The binding sends a
  weight outside that range as the nearest end of it.

## The built-in faces

`Theme.builtin` defines `default` (every attribute set), `cursor`,
`selection`, `echo-area`, `minibuffer-prompt` and `mode-line`. Layout reads
three names by itself: `default`, under every other face; `selection`,
which the selections are drawn in; and `mode-line`, under each field of a
view's status line. `echo-area` and `minibuffer-prompt` are defined and
nothing draws them yet. Any other name is whatever a scene names and a
theme or config defines: a name nothing defines sets nothing, so a cursor
face per editing state is a definition, with no change here. Its colours
are placeholders.

## Where an addition goes

A new attribute is a field of `Face` here, a field of `Face` in
`crates/editor-layout/src/face.rs`, and two words of a definition as it
crosses (`crates/editor-ffi/src/display/wire.rs`, written by
`RealDisplay.encodeFace`). A new built-in face is a definition in
`Theme.builtin`, and a name in `ModelTest.faceChecks`. A face naming
another as its base is not built.
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

/-- A length in 64ths of a physical pixel. A numeric literal is whole
pixels. -/
structure Pixels where
  /-- The length, in 64ths of a pixel. -/
  sixtyFourths : UInt32
  deriving DecidableEq, Repr

/-- `pixels` whole pixels; the longest length for more than a `Pixels`
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
  /-- A height in pixels, whatever the font's own. -/
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

/-- The built-in theme: `default`, which sets every attribute, then
`cursor`, `selection`, `echo-area`, `minibuffer-prompt` and `mode-line`,
each of which sets only what it changes. Its colours are placeholders. -/
def Theme.builtin : Theme :=
  #[{ name := ⟨"default"⟩
      face :=
        { family := some "monospace", size := some 16, weight := some 400, slant := some .upright
          foreground := some (Color.rgb 216 222 233), background := some (Color.rgb 46 52 64)
          underline := some { style := .none }, strikeThrough := some false
          lineHeight := some (.multiple 64) } },
    { name := ⟨"cursor"⟩
      face :=
        { foreground := some (Color.rgb 46 52 64), background := some (Color.rgb 216 222 233) } },
    { name := ⟨"selection"⟩, face := { background := some (Color.rgb 67 76 94) } },
    { name := ⟨"echo-area"⟩, face := { foreground := some (Color.rgb 229 233 240) } },
    { name := ⟨"minibuffer-prompt"⟩
      face := { foreground := some (Color.rgb 136 192 208), weight := some 700 } },
    { name := ⟨"mode-line"⟩
      face :=
        { foreground := some (Color.rgb 236 239 244), background := some (Color.rgb 59 66 82) } }]

end Editor
