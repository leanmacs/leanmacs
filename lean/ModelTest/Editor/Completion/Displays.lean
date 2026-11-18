import Editor.Completion.Candidate
import Editor.Completion.Display
import Editor.Completion.Displays
import Editor.Completion.Keys
import Editor.Scene
import ModelTest.Check

/-!
# Model tests: `Editor/Completion/Displays.lean`

The model tests of `Editor/Completion/Displays.lean`: `completionDisplayChecks`.
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- A listed candidate of `text` for the display checks, with `ranges`, and
a label, an annotation and a group when given. -/
def listedOf (text : String) (ranges : Array Completion.Span := #[])
    (label annotation group : Option String := none) : Completion.Listed :=
  { candidate := { text, label, annotation, group }, ranges }

/-- The listing of a candidate of each of `texts`, with no ranges. -/
def listingOf (texts : Array String) : Array Completion.Listed :=
  texts.map (listedOf ·)

/-- The sheet the minibuffer display at `rows` rows answers for `showing`. -/
def minibufferSheet (showing : Completion.Showing) (rows : Nat := Completion.Displays.rows) :
    Completion.Sheet :=
  (Completion.Displays.minibuffer rows).sheet showing

/-- The texts of `sheet`'s rows. -/
def rowTexts (sheet : Completion.Sheet) : Array String :=
  sheet.rows.map (·.text)

/-- The checks of the completion display interface
(`Editor/Completion/Display.lean`) and the shipped minibuffer display
(`Editor/Completion/Displays.lean`): its rule, pure, over listings written
here. -/
def completionDisplayChecks : List Check :=
  let texts := (Array.range 15).map (s!"c{·}")
  [{  name :=
        "the minibuffer display shows at most its rows, one candidate a row from the top in the listing's order, and fewer when fewer are listed"
      run :=
        pure <|
          let sheet := minibufferSheet { listed := listingOf texts }
          let short := minibufferSheet { listed := listingOf (texts.extract 0 4) }
          Completion.Displays.rows == 10 && rowTexts sheet == texts.extract 0 10 &&
            sheet.first == 0 &&
            rowTexts short == texts.extract 0 4 &&
            rowTexts (minibufferSheet { listed := listingOf texts } 3) == texts.extract 0 3 },
    { name :=
        "the minibuffer display draws each row whole in the candidate face, and the chosen one's in the chosen face"
      run :=
        pure <|
          let sheet := minibufferSheet { listed := listingOf #["ab", "cde", "f"], chosen := some 1 }
          sheet.rows.map (·.decorations) ==
            #[#[{ start := 0, stop := 2, face := Completion.Displays.candidateFace }],
              #[{ start := 0, stop := 3, face := Completion.Displays.chosenFace }],
              #[{ start := 0, stop := 1, face := Completion.Displays.candidateFace }]] },
    { name :=
        "the minibuffer display draws each candidate's matched ranges in the match face over its row, and the sheet's decorations are each row's offset by the bytes of the rows and line feeds before it"
      run :=
        pure <|
          let sheet :=
            minibufferSheet
              {
                listed :=
                  #[listedOf "wq" #[⟨0, 1⟩], listedOf "éw" #[⟨2, 3⟩],
                    listedOf "xwyw" #[⟨1, 2⟩, ⟨3, 4⟩]] }
          let candidate (start stop : Nat) : Decoration :=
            { start, stop, face := Completion.Displays.candidateFace }
          let matched (start stop : Nat) : Decoration :=
            { start, stop, face := Completion.Displays.matchFace }
          sheet.rows.map (·.decorations) ==
              #[#[candidate 0 2, matched 0 1], #[candidate 0 3, matched 2 3],
                #[candidate 0 4, matched 1 2, matched 3 4]] &&
            sheet.text == "wq\néw\nxwyw" &&
            sheet.decorations ==
              #[candidate 0 2, matched 0 1, candidate 3 6, matched 5 6, candidate 7 11, matched 8 9,
                matched 10 11] },
    { name :=
        "a candidate whose label ends its text has the text's ranges within that end drawn on the label, shifted, a range that crosses into it cut at its start; a label that does not end the text draws none"
      run :=
        pure <|
          let sheet :=
            minibufferSheet
              {
                listed :=
                  #[listedOf "/w/notes/" #[⟨1, 2⟩, ⟨3, 5⟩] (label := some "notes/"),
                    listedOf "/w/alps.md" #[⟨1, 5⟩] (label := some "alps.md"),
                    listedOf "/w/x" #[⟨3, 4⟩] (label := some "y")] }
          let candidate (stop : Nat) : Decoration :=
            { start := 0, stop, face := Completion.Displays.candidateFace }
          let matched (start stop : Nat) : Decoration :=
            { start, stop, face := Completion.Displays.matchFace }
          sheet.rows.map (·.decorations) ==
            #[#[candidate 6, matched 0 2], #[candidate 7, matched 0 2], #[candidate 1]] },
    { name := "a candidate with a label is shown by its label, with no matched range drawn"
      run :=
        pure <|
          let sheet :=
            minibufferSheet { listed := #[listedOf "w" #[⟨0, 1⟩] (label := some "write")] }
          rowTexts sheet == #["write"] &&
            sheet.rows.map (·.decorations) ==
              #[#[{ start := 0, stop := 5, face := Completion.Displays.candidateFace }]] },
    { name :=
        "an annotation is drawn in the annotation face at a column the longest shown text and the gap past the row's start, counted in characters, and a row without one has no trailing spaces"
      run :=
        pure <|
          let sheet :=
            minibufferSheet
              {
                listed :=
                  #[listedOf "é" (annotation := some "one"), listedOf "abc",
                    listedOf "w" (label := some "wide") (annotation := some "two")] }
          let column := 4 + Completion.Displays.gap
          Completion.Displays.gap == 2 &&
            rowTexts sheet ==
              #["é" ++ "".pushn ' ' (column - 1) ++ "one", "abc",
                "wide" ++ "".pushn ' ' (column - 4) ++ "two"] &&
            sheet.rows[0]?.map (·.decorations) ==
              some
                #[{ start := 0, stop := column + 4, face := Completion.Displays.candidateFace },
                  { start := column + 1, stop := column + 4
                    face := Completion.Displays.annotationFace }] },
    { name :=
        "with a listing of two groups and two rows or more, a header in the group face comes before the first candidate shown and before each whose group differs from the one above it, counted in the rows and never the last; with one row, or one group, there is none"
      run :=
        pure <|
          let listed :=
            #[listedOf "a1" (group := some "A"), listedOf "a2" (group := some "A"),
              listedOf "b1" (group := some "B"), listedOf "a3" (group := some "A")]
          let showing : Completion.Showing := { listed, grouped := Completion.grouped listed }
          let header (name : String) : Completion.Row :=
            { text := name
              decorations :=
                #[{ start := 0, stop := name.utf8ByteSize,
                    face := Completion.Displays.groupFace }] }
          (minibufferSheet showing).rows.map (·.text) == #["A", "a1", "a2", "B", "b1", "A", "a3"] &&
            (minibufferSheet showing).rows[0]? == some (header "A") &&
            rowTexts (minibufferSheet showing 4) == #["A", "a1", "a2"] &&
            rowTexts (minibufferSheet showing 5) == #["A", "a1", "a2", "B", "b1"] &&
            rowTexts (minibufferSheet showing 1) == #["a1"] &&
            rowTexts (minibufferSheet { showing with grouped := false } 3) == #["a1", "a2", "b1"] },
    { name :=
        "the window starts where it last did, earlier at the chosen candidate when it is above, and later, headers counted, until the chosen candidate is shown; with nothing chosen it is kept, and past the listing's end it is the last"
      run :=
        pure <|
          let listed := listingOf texts
          let windowAt := fun (chosen : Option Nat) (first rows : Nat) =>
            minibufferSheet { listed, chosen, first } rows
          let groupedListed :=
            (Array.range 6).map fun index =>
              listedOf s!"g{index}" (group := some (if index < 3 then "A" else "B"))
          let headed := fun (chosen first rows : Nat) =>
            minibufferSheet
              { listed := groupedListed, chosen := some chosen, first, grouped := true } rows
          (windowAt (some 9) 0 10).first == 0 && (windowAt (some 10) 0 10).first == 1 &&
            rowTexts (windowAt (some 10) 0 10) == texts.extract 1 11 &&
            (windowAt (some 3) 5 10).first == 3 &&
            (windowAt none 4 10).first == 4 &&
            (windowAt none 40 10).first == 14 &&
            (windowAt (some 14) 0 10).first == 5 &&
            (headed 3 0 4).first == 2 &&
            rowTexts (headed 3 0 4) == #["A", "g2", "B", "g3"] &&
            (headed 5 0 4).first == 3 &&
            rowTexts (headed 5 0 4) == #["B", "g3", "g4", "g5"] &&
            Completion.Displays.window
                { listed := groupedListed, chosen := some 5, grouped := true } 4 ==
              3 },
    { name := "zero rows show nothing, and an empty listing shows no rows with its window at 0"
      run :=
        pure <|
          (minibufferSheet { listed := listingOf texts, chosen := some 3 } 0).rows.isEmpty &&
            minibufferSheet { first := 4 } == {} &&
            (Completion.Display.plain "p").sheet {} == {} },
    { name :=
        "a sheet's text joins its rows with line feeds and puts a space for a line feed in a row; whether a listing is grouped is whether two of its groups differ"
      run :=
        pure <|
          ({ rows := #[{ text := "a\nb" }, { text := "c" }] } : Completion.Sheet).text ==
              "a b\nc" &&
            ({} : Completion.Sheet).text == "" &&
            Completion.grouped
              #[listedOf "a" (group := some "A"), listedOf "b" (group := some "B")] &&
            !Completion.grouped
                #[listedOf "a" (group := some "A"), listedOf "b" (group := some "A")] &&
            !Completion.grouped #[] &&
            ((Completion.Display.plain "plain").sheet
                  { listed := listingOf #["w", "wq"], chosen := some 1 }).text ==
              "  w\n> wq" },
    { name :=
        "displaying picks a category's display when it has one and the default otherwise, and with no category the default; the standard displaying is the minibuffer display; the shipped displays are the minibuffer's"
      run :=
        pure <|
          let displaying : Completion.Displaying :=
            { default := Completion.Displays.minibuffer
              byCategory := fun category =>
                if category == "pick" then some (Completion.Display.plain "plain") else none }
          (displaying.displayFor (some "pick")).name == "plain" &&
            (displaying.displayFor (some "other")).name == "minibuffer" &&
            (displaying.displayFor none).name == "minibuffer" &&
            (Completion.Displaying.standard.displayFor (some "pick")).name == "minibuffer" &&
            Completion.Displays.shipped.map (·.name) == #["minibuffer"] &&
            Completion.Displays.unknown "nope" ==
              "no completion display is registered under `nope`" },
    { name :=
        "a listing of the key category with nothing chosen and no typed text is drawn by the display chosen for key, and the minibuffer display starts its window at 0 and shows the annotations in their column"
      run :=
        pure <|
          let hints : Array KeyHint :=
            #[{ key := "f", leads := .prefix (some "file") 1 },
              { key := "s", leads := .binding (some "Save") }]
          let showing : Completion.Showing :=
            { listed := (Completion.Keys.candidates hints).map (Completion.Listed.of ·)
              category := some Completion.Keys.category }
          let displaying : Completion.Displaying :=
            { default := Completion.Displays.minibuffer
              byCategory := fun category =>
                if category == "key" then some (Completion.Display.plain "fake") else none }
          let chosen := displaying.displayFor showing.category
          let shipped := Completion.Displays.minibuffer.sheet showing
          chosen.name == "fake" && rowTexts (chosen.sheet showing) == #["  f", "  s"] &&
            shipped.first == 0 &&
            rowTexts shipped == #["f  +file (1)", "s  Save"] }]

end ModelTest
