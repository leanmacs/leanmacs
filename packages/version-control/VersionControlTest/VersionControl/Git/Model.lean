import VcApiTest.Contract
import VcApiTest.Fake
import VersionControl.Porcelain
import VersionControlTest.Check
import VersionControlTest.Git.Model
import VersionControlTest.Support.Git

/-!
# Model tests: `VersionControlTest/Git/Model.lean`

The model tests of git's half of the repository model
(`VersionControlTest/Git/Model.lean`): `gitModelChecks`, that the real
parser reads what its printer prints as the model's status. The test
driver's root, `VersionControlTest/Model.lean`, runs them; its module doc
says what each shows.
-/

namespace VersionControlTest

open Editor
open VcApiTest

/-- The checks of git's half of the repository model: the real parser
(`VersionControl/Porcelain.lean`) reads what the printer prints
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

end VersionControlTest
