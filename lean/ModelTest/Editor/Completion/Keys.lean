import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Completion
import Editor.Completion.Candidate
import Editor.Completion.Keys
import Editor.Scene
import ModelTest.Check
import ModelTest.Support.Models

/-!
# Model tests: `Editor/Completion/Keys.lean`

The model tests of `Editor/Completion/Keys.lean`: `keyHintSourceChecks`.
The root module `ModelTest` runs them; its module doc says what each shows.
The `key` source is also held to the sources' contract
(`sourceContractChecks`).
-/

namespace ModelTest

open Editor

/-- Hints of a sample prefix: a described binding, an undescribed one, a
named prefix and an unnamed one. -/
def sampleHints : Array KeyHint :=
  #[{ key := "s", leads := .binding (some "Save") }, { key := "q", leads := .binding none },
    { key := "f", leads := .prefix (some "file") 2 }, { key := "w", leads := .prefix none 2 }]

/-- What `source` answers `text` with, asked from view 0 on the editor's
models; none when it is refused. -/
def keyAnswers (source : Completion.Source) (text : String) : Option (Array Completion.Candidate) :=
  let asking : EditorM (Guarded (Array Completion.Candidate) × EditorState) :=
    (source.candidates { text, view := ⟨0⟩ }).dispatched {} EditorState.none
  match (asking.runModel editorModel).1 with
  | .ok (.finished answer, _) => some answer
  | _ => none

/-- The checks of the `key` source (`Editor/Completion/Keys.lean`): a
candidate of each kind of hint, and a source that is filtered, of the
category `key`, and answers the same whatever the typed text. -/
def keyHintSourceChecks : List Check :=
  [{  name :=
        "a key hint's candidate is its key, annotated with a binding's description, or +name and the count for a named prefix and +prefix and the count for an unnamed one, and of the kind binding or prefix"
      run :=
        pure
          (Completion.Keys.candidates sampleHints ==
            #[{ text := "s", annotation := some "Save", kind := some "binding" },
              { text := "q", annotation := none, kind := some "binding" },
              { text := "f", annotation := some "+file (2)", kind := some "prefix" },
              { text := "w", annotation := some "+prefix (2)", kind := some "prefix" }]) },
    { name :=
        "the key source is called keys, of the category key, has filtered already, and answers the same candidates whatever text it is asked with"
      run :=
        let source := Completion.Keys.source sampleHints
        pure
          (source.name == "keys" && source.category == "key" && Completion.Keys.category == "key" &&
            source.filtered &&
            source.later.isNone &&
            keyAnswers source "" == some (Completion.Keys.candidates sampleHints) &&
            keyAnswers source "zz" == some (Completion.Keys.candidates sampleHints)) },
    { name :=
        "a key hint delay is written as milliseconds or .never, and a delay longer than a minute is refused with a sentence that names .never"
      run :=
        let written : Completion.Keys.Delay := 250
        pure
          (written == .after 250 && (0 : Completion.Keys.Delay) == .after 0 &&
            Completion.Keys.longest == 60000 &&
            Completion.Keys.keyHintDelayTooLong 60001 ==
              "a key hint delay of 60001 ms is longer than a minute: write `keyHintDelay .never` to turn the hints off") }]

end ModelTest
