import Editor.VersionControl.Git.Model
import Editor.VersionControl.Porcelain
import ModelTest.Check
import ModelTest.Support.Git
import VcApiTest.Contract
import VcApiTest.Fake

/-!
# Model tests: `Editor/VersionControl/Git/Model.lean`

The model tests of git's half of the repository model
(`Editor/VersionControl/Git/Model.lean`): `gitModelChecks`, that the real
parser reads what its printer prints as the model's status. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open VcApiTest

/-- The checks of git's half of the repository model: the real parser
(`Editor/VersionControl/Porcelain.lean`) reads what the printer prints
(`Repository.porcelain`) as the model's status. -/
def gitModelChecks : List Check :=
  let pairs : VersionControl.Model.Repository :=
    { committed := #[("a.txt", "x"), ("b.txt", "x"), ("e.txt", "")]
      index := #[("c.txt", .file "x"), ("f.txt", .file ""), ("z.txt", .file "x")]
      worktree := #[("c.txt", "x"), ("f.txt", ""), ("z.txt", "x")] }
  let printed (repository : VersionControl.Model.Repository) : Bool :=
    (VersionControl.Porcelain.parseStatus repository.porcelain).toOption == some repository.status
  [{  name := "the real parser reads what the model prints as the model's status, in every state"
      run :=
        pure <|
          printed mixedRepository && printed pairs &&
            printed { mixedRepository with head := .detached } &&
            printed { index := #[("a.txt", .file "a")], worktree := #[("a.txt", "a")] } },
    { name :=
        "the real parser reads what the model prints as the model's status, for every repository of the contract"
      run :=
        pure (VersionControlContract.properties.all fun property => printed property.repository) }]

end ModelTest
