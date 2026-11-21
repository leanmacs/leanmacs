import Editor.Buffers
import Editor.Command
import Editor.Completion
import Editor.Completion.Candidate
import Editor.Completion.Contract
import Editor.Completion.Fake
import Editor.Completion.Keys
import Editor.Ex
import Editor.Program
import Editor.TabCommands
import Editor.Test.Completion
import Editor.Test.Sources
import Editor.Text
import Editor.Themes
import Editor.Workspace.FindFile
import Editor.Workspace.FindInProject
import ModelTest.Check

/-!
# Model tests: `Editor/Completion/Contract.lean`

The model tests of `Editor/Completion/Contract.lean`: `sourceContractChecks`.
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The checks of the completion sources' contract
(`Editor/Completion/Contract.lean`): it holds of the model, of the fake that
answers what it was asked, of every source the core ships and of the key
hints' source (`Completion.Keys.source`), and it reports a source that makes
a text and one that is refused. The sources of the command prompt and the
binding search are held to it by their own checks, on the same runner
(`Editor.Test.sourceHolds`, `Editor/Test/Sources.lean`), and so is the
files feature's file source (`ModelTest.pathsChecks`). -/
def sourceContractChecks : List Check :=
  let subjects : List Completion.Source :=
    [.fixed "fixed" "test" (offered #["wq", "w"]), Completion.Fake.echo "echo" "test",
      Ex.historySource, Ex.namesSource, Buffers.source, TabCommands.source, Themes.source,
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
      (sourceContract source).map fun (name, held) => { name, run := pure held }) ++
    [{  name :=
          "the contract reports a source that makes a text and one that is refused, and the shipped ones answer something on the fixture"
        run :=
          pure <|
            !holds writes && !holds (Completion.Fake.refusing "no" "test") &&
              [Ex.namesSource, Buffers.source, TabCommands.source, Themes.source].all
                answersSomething }]

end ModelTest
