import Editor.Job
import Editor.Job.Model
import Editor.Program
import Editor.VersionControl
import Editor.VersionControl.Contract
import Editor.VersionControl.Model
import ModelTest.Support.Git

/-!
# Model tests: `Editor/VersionControl/Contract.lean`

The model tests of `Editor/VersionControl/Contract.lean`:
`versionControlContractFailures`. The version-control contract is run here
against the model of a repository, and the git implementation's status read of
each of its repositories on the job model. The root module `ModelTest` runs
them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The names of the version-control contract's properties
(`Editor/VersionControl/Contract.lean`) that do not hold of the model
(`Model.handle`), and of those whose repository's status the git
implementation, run on the job model that prints it (`Repository.jobModel`),
does not read as the model's. -/
def versionControlContractFailures : IO (List String) :=
  pure <|
    VersionControlContract.properties.flatMap fun property =>
      let repository := property.repository
      let (read, _) := gitStatus (repository.jobModel "git" "/r")
      (if (property.holds.run VersionControl.Model.handle repository).1 then []
        else [s!"the version-control model: {property.name}"]) ++
        if read == .finished (.ok repository.status) then []
        else [s!"the git implementation's status on the job model: {property.name}"]

end ModelTest
