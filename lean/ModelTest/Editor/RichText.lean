import Editor.Fold
import Editor.Link
import Editor.RichText
import Editor.Scene
import ModelTest.Check

/-!
# Model tests: `Editor/RichText.lean`

The model tests of `Editor/RichText.lean`: `richTextChecks`, pure. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- A span of `face` over the bytes `start` to `stop`. -/
def richSpan (start stop : Nat) (face : String) : Decoration :=
  { start, stop, face := ⟨face⟩ }

/-- A link over the bytes `start` to `stop` to the URL `url`. -/
def richLink (start stop : Nat) (url : String) : Link :=
  { start, stop, target := .url url }

/-- A foldable range keyed `key` over the bytes `start` to `stop`, its
placeholder `text` with a span of its own. -/
def richFold (key : String) (start stop : Nat) (text : String) (folded : Bool := false) :
    Foldable :=
  { start, stop, key, text, decorations := #[richSpan 0 1 "placeholder"], folded }

/-- A wrap indent over the bytes `start` to `stop`, `first` points in. -/
def richIndent (start stop first : Nat) : WrapIndent :=
  { start, stop, first }

/-- A description of 12 bytes, `abc\ndef\nghi\n`, with a part of each kind
on its first row and its second. -/
def richHeld : RichText :=
  { text := "abc\ndef\nghi\n"
    spans := #[richSpan 0 3 "a", richSpan 4 7 "b"]
    stops := #[{ offset := 1, x := 10 }, { offset := 5, x := 20 }]
    links := #[richLink 0 3 "held:a", richLink 4 7 "held:b"]
    folds := #[richFold "first" 0 4 "[held first]" true, richFold "whole" 0 12 "[held whole]"]
    indents := #[richIndent 0 4 2, richIndent 4 8 4] }

/-- A description of the same length that disagrees with `richHeld` on every
part and every byte. -/
def richOther : RichText :=
  { text := "ABC\nDEF\nGHI\n"
    spans := #[richSpan 0 3 "A", richSpan 4 7 "B", richSpan 8 11 "C"]
    stops := #[{ offset := 1, x := 11 }, { offset := 9, x := 21 }]
    links := #[richLink 0 3 "other:a", richLink 8 11 "other:c"]
    folds :=
      #[richFold "whole" 0 12 "[other whole]", richFold "first" 0 4 "[other first]",
        richFold "third" 8 12 "[other third]"]
    indents := #[richIndent 0 4 3, richIndent 8 12 5] }

/-- The checks of the rich-text description (`Editor/RichText.lean`). -/
def richTextChecks : List Check :=
  [{  name :=
        "shift moves every offset of every part, a fold's start and stop and a stop's offset among them, and leaves the text and a placeholder's own spans alone"
      run :=
        pure <|
          let moved := richHeld.shift 5
          moved.text == richHeld.text && moved.spans == #[richSpan 5 8 "a", richSpan 9 12 "b"] &&
            moved.stops == #[{ offset := 6, x := 10 }, { offset := 10, x := 20 }] &&
            moved.links == #[richLink 5 8 "held:a", richLink 9 12 "held:b"] &&
            moved.folds ==
              #[richFold "first" 5 9 "[held first]" true, richFold "whole" 5 17 "[held whole]"] &&
            moved.folds.all (·.decorations == #[richSpan 0 1 "placeholder"]) &&
            moved.indents == #[richIndent 5 9 2, richIndent 9 13 4] },
    { name :=
        "append is the two texts one after the other, with the second's parts moved past the first's text and placed after the first's"
      run :=
        pure <|
          let tail : RichText :=
            { text := "é\n", spans := #[richSpan 0 2 "t"], stops := #[{ offset := 0, x := 1 }]
              links := #[richLink 0 2 "tail"], folds := #[richFold "tail" 0 3 "[tail]"]
              indents := #[richIndent 0 3 6] }
          let joined := richHeld.append tail
          joined.text == "abc\ndef\nghi\né\n" &&
            joined.spans == richHeld.spans.push (richSpan 12 14 "t") &&
            joined.stops == richHeld.stops.push { offset := 12, x := 1 } &&
            joined.links == richHeld.links.push (richLink 12 14 "tail") &&
            joined.folds == richHeld.folds.push (richFold "tail" 12 15 "[tail]") &&
            joined.indents == richHeld.indents.push (richIndent 12 15 6) },
    { name :=
        "replaceFrom keeps the held text before start, whatever the description's bytes there, and takes the description's from start on"
      run := pure <| (RichText.replaceFrom richHeld 4 richOther).text == "abc\nDEF\nGHI\n" },
    { name :=
        "replaceFrom keeps each held part that lies before start and takes the description's parts that reach it: a part crossing start and an empty part at start are the description's"
      run :=
        pure <|
          let rich : RichText :=
            { richOther with
              spans := richOther.spans.push (richSpan 4 4 "empty") |>.push (richSpan 2 6 "cross") }
          let held : RichText :=
            { richHeld with
              spans :=
                richHeld.spans.push (richSpan 4 4 "held empty") |>.push
                  (richSpan 2 6 "held cross") }
          let replaced := RichText.replaceFrom held 4 rich
          replaced.spans ==
              #[richSpan 0 3 "a", richSpan 4 7 "B", richSpan 8 11 "C", richSpan 4 4 "empty",
                richSpan 2 6 "cross"] &&
            replaced.stops == #[{ offset := 1, x := 10 }, { offset := 9, x := 21 }] &&
            replaced.links == #[richLink 0 3 "held:a", richLink 8 11 "other:c"] &&
            replaced.indents == #[richIndent 0 4 2, richIndent 8 12 5] },
    { name :=
        "replaceFrom keeps a held fold before start, drops a held fold whose key a taken fold has, and orders the folds by start"
      run :=
        pure <|
          -- `first` lies before 4 and is kept, folded, with its placeholder;
          -- `whole` crosses 4, so the description's is taken and the held
          -- one dropped; the description's `first` lies before 4 and is not
          -- taken.
          (RichText.replaceFrom richHeld 4 richOther).folds ==
            #[richFold "first" 0 4 "[held first]" true, richFold "whole" 0 12 "[other whole]",
              richFold "third" 8 12 "[other third]"] },
    { name := "replaceFrom from 0 is the description"
      run := pure <| RichText.replaceFrom richHeld 0 richOther == richOther },
    { name :=
        "replaceFrom at the end of both texts keeps every held part that ends there and takes the description's empty parts at the end"
      run :=
        pure <|
          let rich : RichText :=
            { text := richOther.text, spans := #[richSpan 12 12 "end"]
              stops := #[{ offset := 12, x := 1 }], links := #[richLink 12 12 "end"]
              folds := #[richFold "end" 12 12 "[end]"], indents := #[richIndent 12 12 9] }
          let replaced := RichText.replaceFrom richHeld 12 rich
          replaced.text == richHeld.text &&
            replaced.spans == richHeld.spans.push (richSpan 12 12 "end") &&
            replaced.stops == richHeld.stops.push { offset := 12, x := 1 } &&
            replaced.links == richHeld.links.push (richLink 12 12 "end") &&
            replaced.folds == richHeld.folds.push (richFold "end" 12 12 "[end]") &&
            replaced.indents == richHeld.indents.push (richIndent 12 12 9) }]

end ModelTest
