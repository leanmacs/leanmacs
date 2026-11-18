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

/-- The leaders the leader checks expand against: `SPC`, and `SPC m`. -/
def spaceLeaders : Key.Leaders :=
  { leader := [charKey " "], localLeader := [charKey " ", charKey "m"] }

/-- Whether `text` is read as exactly the strokes `strokes`. -/
def parsesStrokes (text : String) (strokes : List Key.Stroke) : Bool :=
  match Key.parseStrokes text with
  | .ok read => read == strokes
  | .error _ => false

/-- Whether `text` is refused as strokes, with a reason that names
`token`. -/
def refusesStrokes (text token : String) : Bool :=
  match Key.parseStrokes text with
  | .ok _ => false
  | .error reason => (reason.splitOn token).length > 1

/-- Whether `text`, read against `leaders`, names exactly `keys`. -/
def parsesUnder (leaders : Key.Leaders) (text : String) (keys : List Key) : Bool :=
  match Key.parse text (some leaders) with
  | .ok named => named == keys
  | .error _ => false

/-- The checks of key strings (`Editor/Key/Notation.lean`): the keys a
string names, the strings that are refused, and that a chord's notation
names it. -/
def keyNotationChecks : List Check :=
  [{  name :=
        "a key string is read as strokes: <leader> and <localleader> are the placeholders, in place, and every other stroke is its key"
      run :=
        pure
          (parsesStrokes "<leader> f <localleader> x"
              [.leader, .key (charKey "f"), .localLeader, .key (charKey "x")] &&
            parsesStrokes "C-x <Escape>" [.key (controlKey "x"), .key (namedKey .escape)] &&
            parsesStrokes "" []) },
    { name :=
        "the placeholders are lowercase and exact: <Leader> and <LocalLeader> are named keys of those names"
      run :=
        pure
          (parsesStrokes "<Leader>" [.key (namedKey ⟨"Leader"⟩)] &&
            parsesStrokes "<LocalLeader>" [.key (namedKey ⟨"LocalLeader"⟩)]) },
    { name :=
        "a modifier prefix on a placeholder is refused, naming the stroke, and a stroke that is not a key is refused as Key.parse refuses it"
      run :=
        pure
          (refusesStrokes "C-<leader>" "C-<leader>" &&
            refusesStrokes "x M-<localleader>" "M-<localleader>" &&
            refusesStrokes "C-x nope" "nope") },
    { name :=
        "a modifier prefix on a placeholder is refused with a message that names what the placeholder stands for: the leader for <leader>, the localleader for <localleader>"
      run :=
        pure
          (refusesStrokes "C-<leader>" "the keys the leader is on" &&
            refusesStrokes "C-<localleader>" "C-<localleader>" &&
            refusesStrokes "C-<localleader>" "the keys the localleader is on") },
    { name :=
        "a key string with placeholders, read against leaders, names the leaders' keys in their place, and the other keys as chords"
      run :=
        pure
          (parsesUnder spaceLeaders "<leader> f f" [charKey " ", charKey "f", charKey "f"] &&
            parsesUnder spaceLeaders "<localleader> x" [charKey " ", charKey "m", charKey "x"] &&
            parsesUnder { leader := [controlKey "c"] } "C-x <leader>"
              [controlKey "x", controlKey "c"]) },
    { name :=
        "a key string with a placeholder read with no leaders is refused, with a message that names the placeholder and says only a key binding expands it"
      run :=
        pure
          (refusesKey "<leader> f" "<leader>" && refusesKey "<leader> f" "bindKey" &&
            refusesKey "x <localleader>" "<localleader>" &&
            parses "<Leader>" [namedKey ⟨"Leader"⟩]) },
    { name :=
        "strokes are written back as key strings, the placeholders as <leader> and <localleader>, and a sequence with no placeholder gives its keys"
      run :=
        let strokes : List Key.Stroke := [.leader, .key (controlKey "x"), .localLeader]
        pure
          (Key.strokeNotations strokes == "<leader> C-x <localleader>" &&
            Key.strokeNotations [] == "" &&
            Key.Stroke.keys? strokes == none &&
            Key.Stroke.keys? [.key (controlKey "x"), .key (charKey "s")] ==
              some [controlKey "x", charKey "s"]) },
    { name :=
        "expanding strokes puts the leaders' keys in place of the placeholders, and an empty leader expands to nothing"
      run :=
        pure
          (Key.expand spaceLeaders [.localLeader, .key (charKey "x"), .leader] ==
              [charKey " ", charKey "m", charKey "x", charKey " "] &&
            Key.expand {} [.leader, .key (charKey "x")] == [charKey "x"]) },
    { name := "a key string names its strokes in order, each with the modifiers written before it"
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
