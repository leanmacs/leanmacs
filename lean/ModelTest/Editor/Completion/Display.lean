import Editor.Completion.Candidate
import Editor.Completion.Display
import Editor.Completion.Keys
import Editor.Scene
import ModelTest.Check

/-!
# Model tests: `Editor/Completion/Display.lean`

The model tests of `Editor/Completion/Display.lean`: `completionDisplayChecks`,
the model, the core's own display and the choice, on displays written here.
The shipped display's are the `completion` package's
(`packages/completion/CompletionTest/Completion/Displays.lean`).
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

/-- The texts of `sheet`'s rows. -/
def rowTexts (sheet : Completion.Sheet) : Array String :=
  sheet.rows.map (·.text)

/-- The checks of the completion display interface
(`Editor/Completion/Display.lean`): its model, the core's own display and
the choice, over listings and displays written here. -/
def completionDisplayChecks : List Check :=
  [{  name :=
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
        "displaying picks a category's display when it has one and the default otherwise, and with no category the default; a host told of no display shows every listing with the core's own, plain, the interface's model; the report says a display chosen under a name nobody registered"
      run :=
        pure <|
          let displaying : Completion.Displaying :=
            { default := Completion.Display.plain "first"
              byCategory := fun category =>
                if category == "pick" then some (Completion.Display.plain "second") else none }
          let showing : Completion.Showing := { listed := listingOf #["w", "wq"], chosen := some 1 }
          (displaying.displayFor (some "pick")).name == "second" &&
            (displaying.displayFor (some "other")).name == "first" &&
            (displaying.displayFor none).name == "first" &&
            (Completion.Displaying.unregistered.displayFor (some "pick")).name == "plain" &&
            Completion.Display.unregistered.sheet showing ==
              (Completion.Display.plain "plain").sheet showing &&
            Completion.Display.unknown "nope" ==
              "no completion display is registered under `nope`" },
    { name :=
        "a listing of the key category with nothing chosen and no typed text is drawn by the display chosen for key"
      run :=
        pure <|
          let hints : Array KeyHint :=
            #[{ key := "f", leads := .prefix (some "file") 1 },
              { key := "s", leads := .binding (some "Save") }]
          let showing : Completion.Showing :=
            { listed := (Completion.Keys.candidates hints).map (Completion.Listed.of ·)
              category := some Completion.Keys.category }
          let displaying : Completion.Displaying :=
            { default := Completion.Display.plain "first"
              byCategory := fun category =>
                if category == "key" then some (Completion.Display.plain "fake") else none }
          let chosen := displaying.displayFor showing.category
          chosen.name == "fake" && rowTexts (chosen.sheet showing) == #["  f", "  s"] }]

end ModelTest
