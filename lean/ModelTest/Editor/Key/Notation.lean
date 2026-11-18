import Editor.Event
import Editor.Key.Notation
import Editor.Keymap
import ModelTest.Check
import ModelTest.Support.Keys

/-!
# Model tests: `Editor/Key/Notation.lean`

The model tests of `Editor/Key/Notation.lean`: `keyNotationChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- Whether `text` is a key string that names exactly `keys`. -/
def parses (text : String) (keys : List Key) : Bool :=
  match Key.parse text with
  | .ok named => named == keys
  | .error _ => false

/-- Whether `text` is refused as a key string, with a reason that names
`token`. -/
def refusesKey (text token : String) : Bool :=
  match Key.parse text with
  | .ok _ => false
  | .error reason => (reason.splitOn token).length > 1

/-- The checks of key strings (`Editor/Key/Notation.lean`): the keys a
string names, the strings that are refused, and that a chord's notation
names it. -/
def keyNotationChecks : List Check :=
  [{  name := "a key string names its strokes in order, each with the modifiers written before it"
      run := pure (parses "C-x C-s" [controlKey "x", controlKey "s"]) },
    { name :=
        "a stroke of one character is that character, whatever it is: a capital, the minus sign, an angle bracket"
      run :=
        pure
          (parses "A" [charKey "A"] && parses "-" [charKey "-"] && parses "C--" [controlKey "-"] &&
            parses "<" [charKey "<"] &&
            parses "x - >" [charKey "x", charKey "-", charKey ">"]) },
    { name := "a name in angle brackets is the named key of that name"
      run :=
        pure
          (parses "<Escape>" [namedKey .escape] && parses "<ArrowLeft>" [namedKey .arrowLeft] &&
            parses "<F5>" [namedKey ⟨"F5"⟩]) },
    { name := "RET, ESC and TAB are Enter, Escape and Tab, and SPC is the space character"
      run :=
        pure
          (parses "RET ESC TAB SPC"
            [namedKey .enter, namedKey .escape, namedKey .tab, charKey " "]) },
    { name :=
        "each modifier prefix holds its modifier: C- control, M- alt, s- super, and S- shift on a named key"
      run :=
        pure
          (parses "M-s-<ArrowLeft>" [namedKey .arrowLeft { alt := true, superKey := true }] &&
            parses "S-<Tab>" [namedKey .tab { shift := true }] &&
            parses "S-TAB" [namedKey .tab { shift := true }] &&
            parses "C-M-x" [charKey "x" { control := true, alt := true }] &&
            parses "s-s" [charKey "s" { superKey := true }]) },
    { name := "the empty string names no keys, and spaces around strokes name none"
      run :=
        pure
          (parses "" [] && parses "   " [] &&
            parses " C-x  C-s " [controlKey "x", controlKey "s"]) },
    { name :=
        "a string with a stroke that is not a key is refused, naming the stroke: shift on a character, a modifier with no key, two characters, a name that is not closed, an empty name"
      run :=
        pure
          (refusesKey "S-a" "S-a" && refusesKey "x C-" "C-" && refusesKey "C-x xy" "xy" &&
            refusesKey "<Escape" "<Escape" &&
            refusesKey "<>" "<>" &&
            refusesKey "S-SPC" "S-SPC") },
    { name :=
        "a name in angle brackets that is not letters and digits is refused, naming the stroke: a modifier prefix inside the brackets, an underscore"
      run := pure (refusesKey "<C-x>" "<C-x>" && refusesKey "x <a_b>" "<a_b>") },
    { name :=
        "a letter that is no modifier's is not a prefix: the stroke it begins is refused, naming it, and it is the minus key's stroke that stays a key"
      run :=
        pure
          (refusesKey "X-a" "X-a" && refusesKey "C-X-a" "C-X-a" && refusesKey "c-x" "c-x" &&
            parses "C-- X" [controlKey "-", charKey "X"]) },
    { name := "the keys a key string names are chords"
      run :=
        pure <|
          ["C-x C-s", "A", "S-<Tab>", "M-s-<ArrowLeft>", "RET SPC"].all fun text =>
            match Key.parse text with
            | .ok keys => keys.map Key.chord == keys
            | .error _ => false },
    { name := "a key's notation is its modifiers, then the character or the name in angle brackets"
      run :=
        pure
          (Key.notation (controlKey "x") == "C-x" && Key.notation (charKey "A") == "A" &&
            Key.notation (charKey " ") == "SPC" &&
            Key.notation (namedKey .enter) == "<Enter>" &&
            Key.notation
                (namedKey .arrowLeft
                  { shift := true, control := true, alt := true, superKey := true }) ==
              "C-M-s-S-<ArrowLeft>" &&
            Key.notation { logical := .dead none } == "<Dead>" &&
            Key.notation { logical := .unidentified } == "<Unidentified>" &&
            Key.notations [controlKey "x", controlKey "s"] == "C-x C-s" &&
            Key.notations [] == "") },
    { name := "the notation of chords of characters and named keys names those chords"
      run :=
        pure <|
          [[controlKey "x", controlKey "s"], [charKey "A"], [charKey "-"], [controlKey "-"],
                [charKey "<"], [charKey " ", charKey "s" { superKey := true }],
                [namedKey .escape, namedKey .enter, namedKey .tab { shift := true }],
                [namedKey .arrowLeft { control := true, alt := true, superKey := true }],
                [charKey "é" { alt := true }], []].all
            fun keys => parses (Key.notations keys) keys }]

end ModelTest
