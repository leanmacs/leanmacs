import Editor.Command
import Editor.Command.Model
import Editor.Config.Owner
import Editor.Config.Registry
import Editor.Event
import Editor.Face.Vocabulary
import Editor.Highlight
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Language
import Editor.Loop
import Editor.Mode
import Editor.Program
import Editor.Role
import Editor.Scene
import Editor.State
import Editor.SyntaxTree
import Editor.SyntaxTree.Model
import Editor.SyntaxTree.Model.Query
import Editor.Test.Models
import Editor.Test.States
import Editor.Text
import ModelTest.Check
import ModelTest.Support.Modes

/-!
# Model tests: `Editor/Highlight.lean`

The model tests of `Editor/Highlight.lean`: `highlightFaceChecks` and
`highlightEnterChecks`. The root module `ModelTest` runs them; its module doc
says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The checks of the capture-to-face rule (`Editor/Highlight.lean`), pure:
the shipped default, the fallback of a dotted capture to its first
component, and config's mapping over both. -/
def highlightFaceChecks : List Check :=
  let faceOf (config : List (String × Option FaceName)) (capture : String) : String :=
    ((Highlight.faceOf config capture).map (·.name)).getD "-"
  [{  name :=
        "by the shipped default, each capture of the face vocabulary's syntax captures is drawn in its syntax face, the vocabulary's own"
      run :=
        pure
          (Face.syntaxCaptures.all
              (fun (capture, _) => faceOf [] capture == s!"syntax.{capture}") &&
            Highlight.defaultFaces.map (·.2) ==
              (Face.syntaxEntries.map (·.name)).toList ++ (Face.markupCaptures.map (·.2)).toList) },
    { name := "by the shipped default, markdown's captures are drawn in the text faces"
      run :=
        let headings :=
          (List.range 6).all fun index =>
            faceOf [] s!"text.heading.{index + 1}" == s!"text.heading.{index + 1}"
        pure
          (headings && faceOf [] "text.emphasis" == "text.emphasis" &&
            faceOf [] "text.strong" == "text.strong" &&
            faceOf [] "text.literal" == "text.code-span" &&
            faceOf [] "text.code-block" == "text.code-block" &&
            faceOf [] "text.uri" == "text.link" &&
            faceOf [] "text.reference" == "text.link" &&
            faceOf [] "text.quote" == "text.quote" &&
            faceOf [] "text.list-marker" == "text.list-marker" &&
            faceOf [] "text.table-header" == "text.table-header" &&
            Face.markupCaptures.all (fun (_, face) => Face.vocabularyNames.contains face) &&
            faceOf [] "text.unknown" == "-" &&
            faceOf [] "text" == "-") },
    { name :=
        "a dotted capture with no mapping of its own is drawn in its first component's face, and a capture nothing maps draws nothing"
      run :=
        pure
          (faceOf [] "keyword.control" == "syntax.keyword" &&
            faceOf [] "function.method" == "syntax.function" &&
            faceOf [] "punctuation.bracket" == "syntax.punctuation" &&
            faceOf [] "string.special.key" == "syntax.string" &&
            faceOf [] "escape" == "-" &&
            faceOf [] "label" == "-" &&
            faceOf [] "escape.x" == "-") },
    { name :=
        "config's mapping wins over the default: a full name for itself alone, a first component for every dotted capture under it with no entry of its own, and none draws nothing"
      run :=
        pure
          (faceOf [("keyword.control", some ⟨"my-face"⟩)] "keyword.control" == "my-face" &&
            faceOf [("keyword.control", some ⟨"my-face"⟩)] "keyword" == "syntax.keyword" &&
            faceOf [("string", some ⟨"json-string"⟩)] "string.special.key" == "json-string" &&
            faceOf [("string", some ⟨"json-string"⟩)] "string" == "json-string" &&
            faceOf [("number", none)] "number" == "-" &&
            faceOf [("number", none)] "number.float" == "-" &&
            faceOf [("escape", some ⟨"syntax.string"⟩)] "escape" == "syntax.string") },
    { name := "a full name mapped to none stops the fallback to its first component"
      run :=
        pure
          (faceOf [("keyword.control", none)] "keyword.control" == "-" &&
            faceOf [("keyword.control", none)] "keyword.return" == "syntax.keyword") },
    { name := "a query's faces are each capture name's, in order"
      run :=
        pure
          (faceNames (Highlight.faces [("number", some ⟨"n"⟩)] #["string", "number", "label"]) ==
            #["syntax.string", "n", "-"]) }]

/-- A mode called `name` whose text is parsed and drawn as `syntaxTree`
says. -/
def parsedMode (name : String) (syntaxTree : Mode.SyntaxTree := { grammar := "json" }) : Mode :=
  { name, syntaxTree := some syntaxTree }

/-- Sets each mode of `steps`, in turn, as the major mode of buffer 1
through view 1, by an invocation of `enter` the loop runs, over the
registry of the on-enter checks with `modes` registered for config, and
config's syntax refresh delay `refreshDelay`, the compiled languages
`languages` and buffer 1's language `language`, on the editor's models: what each left in the echo area, buffer 1's major mode at
the end, and the syntax tree model then. `none` when the run was
refused. -/
def highlightedBy (modes : Array Mode) (steps : List String) (refreshDelay : Option Nat := none)
    (languages : Array Language := #[]) (language : Option String := none) :
    Option (List String × Option String × SyntaxTreeModel) :=
  let registry :=
    { (enterRegistry.replaceModes .config modes).replaceLanguages .compiled languages with
      syntaxRefreshDelay := refreshDelay }
  let program : EditorM (List String × EditorState) := do
    let mut state := ((← twoBuffers).setLanguage ⟨1⟩ language).2
    let mut echoes := []
    for name in steps do
      state := (← Loop.run (enterKeys registry) state (entersMode ⟨1⟩ name) []).state
      echoes := echoes ++ [state.echo]
    return (echoes, state)
  match program.runModel editorModel with
  | (.ok (echoes, state), model) =>
    some (echoes, (state.buffer? ⟨1⟩).bind (·.major), model.syntaxTree)
  | (.error _, _) => none

/-- The checks of setting a major mode with a syntax tree
(`Editor/Highlight.lean`, `Editor/Command/Dispatch.lean`), on the editor's
models through the loop's dispatch: what the syntax tree model is asked and
records. -/
def highlightEnterChecks : List Check :=
  [{  name :=
        "the code mode over a buffer whose language is json attaches its text with json and highlights it with the language's tree, the grammar's shipped query; the language's own query is compiled in its place when it has one"
      run :=
        pure <|
          let numbers :=
            { Language.json with
              syntaxTree := { grammar := "json", highlights := some "(number) @number" } }
          (match
              highlightedBy Language.modes ["code"] (languages := #[Language.json]) (language :=
                some "json") with
            | some (echoes, major, model) =>
              echoes == [""] && major == some "code" && model.attached.map (·.2) == #["json"] &&
                highlightedFaces model ==
                  some #["syntax.string", "syntax.string", "syntax.number", "syntax.constant"]
            | none => false) &&
            match
              highlightedBy Language.modes ["code"] (languages := #[numbers]) (language :=
                some "json") with
            | some (_, _, model) => highlightedFaces model == some #["syntax.number"]
            | none => false },
    { name :=
        "the code mode over a buffer with no language, or with a language no entry is registered under, is set and asks the syntax tree port nothing"
      run :=
        pure <|
          [none, some "cobol"].all fun language =>
            match
              highlightedBy Language.modes ["code"] (languages := #[Language.json]) (language :=
                language) with
            | some (echoes, major, model) =>
              echoes == [""] && major == some "code" && model.attached.isEmpty &&
                model.highlighted.isEmpty &&
                model.refreshAfter == none
            | none => false },
    { name :=
        "entering a major mode with a syntax tree hands the syntax service config's refresh delay, or the default when config sets none"
      run :=
        pure <|
          (match highlightedBy #[parsedMode "json"] ["json"] with
            | some (_, _, model) => model.refreshAfter == some Highlight.defaultRefreshDelay
            | none => false) &&
            Highlight.defaultRefreshDelay == 500 &&
            match highlightedBy #[parsedMode "json"] ["json"] (some 250) with
            | some (_, _, model) => model.refreshAfter == some 250
            | none => false },
    { name :=
        "a major mode with a syntax tree attaches its buffer's text and highlights it with the grammar's shipped query, each capture in its syntax face by the shipped default, and releases the query"
      run :=
        pure <|
          match highlightedBy #[parsedMode "json"] ["json"] with
          | some (echoes, major, model) =>
            echoes == [""] && major == some "json" && model.attached.map (·.2) == #["json"] &&
              highlightedFaces model ==
                some #["syntax.string", "syntax.string", "syntax.number", "syntax.constant"] &&
              model.queries.all (·.isNone)
          | none => false },
    { name := "a capture the mode's config maps to a face is highlighted in that face"
      run :=
        pure <|
          let mapped :=
            parsedMode "json" { grammar := "json", captures := [("string", some ⟨"json-string"⟩)] }
          match highlightedBy #[mapped] ["json"] with
          | some (_, _, model) =>
            highlightedFaces model ==
              some #["json-string", "json-string", "syntax.number", "syntax.constant"]
          | none => false },
    { name :=
        "a mode's own highlights query is compiled in place of the shipped one, a dotted capture falling to its first component and an unmapped one drawing nothing"
      run :=
        pure <|
          let own :=
            parsedMode "numbers"
              { grammar := "json", highlights := some "(number) @number.float\n(null) @label" }
          match highlightedBy #[own] ["numbers"] with
          | some (_, _, model) => highlightedFaces model == some #["syntax.number", "-"]
          | none => false },
    { name :=
        "a query that does not compile, and a grammar the service lacks, are said in the echo area under the mode's name; the mode is set and the command runs to its end"
      run :=
        pure <|
          let broken := parsedMode "broken" { grammar := "json", highlights := some "((" }
          let cobol := parsedMode "cobol-mode" { grammar := "cobol" }
          (match highlightedBy #[broken] ["broken"] with
            | some ([echo], major, model) =>
              echo.startsWith "highlights: `broken`: the query is not one" &&
                major == some "broken" &&
                model.highlighted.isEmpty
            | _ => false) &&
            match highlightedBy #[cobol] ["cobol-mode"] with
            | some ([echo], major, model) =>
              echo == "highlights: `cobol-mode`: no grammar of that name" &&
                major == some "cobol-mode" &&
                model.attached.isEmpty
            | _ => false },
    { name :=
        "a refused mode set over a highlighted one leaves its text detached, so nothing of the mode before is drawn: a grammar the service lacks, and a query of the same grammar that does not compile; the echo area still says the refusal"
      run :=
        pure <|
          let broken := parsedMode "broken" { grammar := "json", highlights := some "((" }
          let cobol := parsedMode "cobol-mode" { grammar := "cobol" }
          let modes := #[parsedMode "json", broken, cobol]
          (match highlightedBy modes ["json", "cobol-mode"] with
            | some (["", echo], major, model) =>
              echo == "highlights: `cobol-mode`: no grammar of that name" &&
                major == some "cobol-mode" &&
                model.attached.isEmpty &&
                model.highlighted.isEmpty
            | _ => false) &&
            match highlightedBy modes ["json", "broken"] with
            | some (["", echo], major, model) =>
              echo.startsWith "highlights: `broken`: the query is not one" &&
                major == some "broken" &&
                model.attached.isEmpty &&
                model.highlighted.isEmpty
            | _ => false },
    { name :=
        "a mode with an injections source finds its text's injections with it, and gives a language for the model's grammar, its shipped highlights in the default faces and the mode's injections; every query is released"
      run :=
        pure <|
          let injecting :=
            parsedMode "injecting"
              { grammar := "json", injections := some "(pair value: (string) @injection.content)" }
          match highlightedBy #[injecting] ["injecting"] with
          | some ([""], _, model) =>
            model.injected.size == 1 &&
              model.languages.map
                  (fun (_, name, _, faces, injections) =>
                    (name, faceNames faces, injections.isSome)) ==
                #[("json", #["syntax.string", "syntax.string", "syntax.number", "syntax.constant"],
                    true)] &&
              model.queries.all (·.isNone)
          | _ => false },
    { name :=
        "a grammar that ships no injections, text objects or indents query records no injection, no language and no kept query"
      run :=
        pure <|
          match highlightedBy #[parsedMode "json"] ["json"] with
          | some ([""], _, model) =>
            model.injected.isEmpty && model.languages.isEmpty && model.kept.isEmpty &&
              !model.highlighted.isEmpty
          | _ => false },
    { name :=
        "a mode's own text objects and indents sources are kept, each as its kind, and their queries released"
      run :=
        pure <|
          let keeping :=
            parsedMode "keeping"
              { grammar := "json", textObjects := some "(object) @function.outer"
                indents := some "(array) @indent.begin" }
          match highlightedBy #[keeping] ["keeping"] with
          | some ([""], _, model) =>
            model.kept.map (fun (_, kind, query) => (kind, query.names)) ==
                #[(.textObjects, #["function.outer"]), (.indents, #["indent.begin"])] &&
              model.queries.all (·.isNone)
          | _ => false },
    { name :=
        "an injections, text objects or indents source that does not compile is said in the echo area under the mode's name, stops its own step alone, and leaves the highlights and the text attached"
      run :=
        pure <|
          let broken (injections textObjects indents : Option String) :=
            parsedMode "broken" { grammar := "json", injections, textObjects, indents }
          let said (mode : Mode) (start : String) : Bool :=
            match highlightedBy #[mode] ["broken"] with
            | some ([echo], major, model) =>
              echo.startsWith start && major == some "broken" && !model.attached.isEmpty &&
                !model.highlighted.isEmpty
            | _ => false
          let keptIndents :=
            match
              highlightedBy #[broken (some "((") none (some "(array) @indent.begin")]
                ["broken"] with
            | some (_, _, model) => model.kept.map (·.2.1) == #[.indents]
            | none => false
          said (broken (some "((") none none) "injections: `broken`: the query is not one" &&
            said (broken none (some "((") none) "text objects: `broken`: the query is not one" &&
            said (broken none none (some "((")) "indents: `broken`: the query is not one" &&
            keptIndents },
    { name := "a derived mode that says nothing of a syntax tree takes its parent's"
      run :=
        pure <|
          let child : Mode := { name := "json-child", parent := some "json" }
          match highlightedBy #[parsedMode "json", child] ["json-child"] with
          | some (_, major, model) =>
            major == some "json-child" &&
              highlightedFaces model ==
                some #["syntax.string", "syntax.string", "syntax.number", "syntax.constant"]
          | none => false },
    { name :=
        "a major mode with no syntax tree set over one with a syntax tree detaches the text, which drops its highlights; one set over a mode with none asks the syntax tree port nothing"
      run :=
        pure <|
          (match highlightedBy #[parsedMode "json"] ["json", "listing"] with
            | some (_, major, model) =>
              major == some "listing" && model.attached.isEmpty && model.highlighted.isEmpty
            | none => false) &&
            match highlightedBy #[] ["listing", "other"] with
            | some (_, major, model) =>
              major == some "other" && model.texts.isEmpty && model.attached.isEmpty
            | none => false },
    { name :=
        "a major mode with no syntax tree set over the code mode on a buffer whose language has a tree detaches the text, which drops its highlights"
      run :=
        pure <|
          match
            highlightedBy Language.modes ["code", "listing"] (languages := #[Language.json])
              (language := some "json") with
          | some (_, major, model) =>
            major == some "listing" && model.attached.isEmpty && model.highlighted.isEmpty
          | none => false }]

end ModelTest
