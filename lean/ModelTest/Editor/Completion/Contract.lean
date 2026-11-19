import Editor.BindingSearch
import Editor.Buffers
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Compile.Contribution
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.Candidate
import Editor.Completion.Contract
import Editor.Completion.Fake
import Editor.Completion.Keys
import Editor.Completion.Paths
import Editor.Completion.Styles
import Editor.DisplayRules
import Editor.Ex
import Editor.Ex.Line
import Editor.ExecuteCommand
import Editor.File
import Editor.Language
import Editor.Mode
import Editor.Program
import Editor.State
import Editor.TabCommands
import Editor.Text
import Editor.Text.Model
import Editor.Themes
import Editor.Workspace
import Editor.Workspace.FindFile
import Editor.Workspace.FindInProject
import ModelTest.Check
import ModelTest.Support.Completion
import ModelTest.Support.Keys
import ModelTest.Support.Models
import ModelTest.Support.States

/-!
# Model tests: `Editor/Completion/Contract.lean`

The model tests of `Editor/Completion/Contract.lean`: `sourceContractChecks`.
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The contract's runner on the editor's models (`Completion.Contract.Runner`):
the source asked with `text` from the focused view of `twoBuffers`, dispatched
with a loop told two ex names, two themes, two commands and one key binding, so the shipped
sources that ask for them answer some. `some` with what it answered and whether the editor
state and the texts the store holds were left as they were; `none` when it
was refused, or the fixture could not be made. -/
def sourceRunner : Completion.Contract.Runner := fun text source =>
  let fixture : EditorM EditorState := do
    return ← twoBuffers
  match fixture.runModel editorModel with
  | (.error _, _) => none
  | (.ok start, model) =>
    match start.focusedTarget? with
    | none => none
    | some target =>
      let registered : Loop.Registered :=
        { exNames := #["w", "q"], themeNames := #["default", "second"]
          commandNames := #["load-theme", "quit"]
          keyBindings := fun _ =>
            #[{ keys := keys "C-c m", command := "load-theme", desc := some "Load" }] }
      let asking : EditorM (Guarded (Array Completion.Candidate) × EditorState) :=
        (source.candidates { text, view := target.window.id }).dispatched registered start
      match asking.runModel model with
      | (.ok (.finished answer, after), left) =>
        some (answer, after == start && left.texts.contents == model.texts.contents)
      | _ => none

/-- The checks of the completion sources' contract
(`Editor/Completion/Contract.lean`): it holds of the model, of the fake that
answers what it was asked, of every shipped source and of the key hints'
source (`Completion.Keys.source`), and it reports a
source that makes a text and one that is refused. -/
def sourceContractChecks : List Check :=
  let subjects : List Completion.Source :=
    [.fixed "fixed" "test" (offered #["wq", "w"]), Completion.Fake.echo "echo" "test",
      Ex.historySource, Ex.namesSource, Buffers.source, TabCommands.source, Themes.source,
      ExecuteCommand.source, BindingSearch.source, Completion.Paths.source,
      Workspace.FindFile.source, Workspace.FindInProject.source,
      Completion.Keys.source
        #[{ key := "s", leads := .binding (some "Save") }, { key := "f", leads := .prefix none 2 }]]
  let writes : Completion.Source :=
    { name := "writes", category := "test"
      candidates := fun _ => do
        discard <| createText "made"
        return #[] }
  let holds (source : Completion.Source) : Bool :=
    Completion.Contract.properties.all (·.holds sourceRunner source)
  (subjects.flatMap fun source =>
      Completion.Contract.properties.map fun property =>
        { name := s!"the source {source.name}: {property.name}"
          run := pure (property.holds sourceRunner source) }) ++
    [{  name :=
          "the contract reports a source that makes a text and one that is refused, and the shipped ones answer something on the fixture"
        run :=
          pure <|
            !holds writes && !holds (Completion.Fake.refusing "no" "test") &&
              [Ex.namesSource, Buffers.source, TabCommands.source, Themes.source,
                    ExecuteCommand.source, BindingSearch.source].all
                fun source => (sourceRunner "" source).any (!·.1.isEmpty) }]

end ModelTest
