import Editor.Extension
import Editor.Job.Model
import VcApi
import VcApiTest.Check
import VcApiTest.Contract
import VcApiTest.Fake

/-!
# Model tests: `VcApi.lean`

`vcApiChecks`: the interface library `vc-api`'s choice of a backend
(`VcApi.connect?`), its names, its fake's backend over the model, and its
registration check biting on packages that leave something out. The test
driver's root, `VcApiTest/Model.lean`, runs them; its module doc says what
each shows. The port's own contract over the model is
`versionControlContractFailures` (`VcApiTest/VcApiTest/Contract.lean`).
-/

namespace VcApiTest

open Editor

/-- A backend named `name` over the model of a repository on `branch`, its
handler the model's (`VcApiTest.backend`). -/
def namedBackend (name branch : String) : VcApi.Backend :=
  { VcApiTest.backend { head := .branch branch } with name }

/-- The branch the handler `connect` makes answers for `HEAD`'s status, run
on the model; `none` when there is no connection or the read fails. -/
def branchThrough (connect : Option (String → System.FilePath → VersionControl.Handler)) :
    Option String := do
  let connect ← connect
  match ((connect "git" "/r" .status : JobM _).runModel {}).1 with
  | .finished (.ok status) =>
    match status.head with
    | .branch name =>
      some name
    | .detached =>
      none
  | _ =>
    none

/-- A package named `name` that registers each of `backends` and, when
`jobs` is true, a job under each gutter job name, and the segment `review`
when `segment` is true. -/
def vcRegistering (name : String) (backends : List VcApi.Backend) (jobs : Bool := true)
    (segment : Bool := true) : Package :=
  { name
    setup := do
      for backend in backends do
        Extension.add backend
      if jobs then
        for job in VcApi.gutterJobs do
          workJob job fun _ _ => pure (pure ())
      if segment then
        defineSegment VcApi.reviewSegmentName fun _ => #[] }

/-- Whether every check of the registration contract over `packages` holds. -/
def vcKeeps (packages : Array Package) : Bool :=
  (VcApiTest.registrationChecks packages).all (·.2)

/-- The checks of `vc-api` (`VcApi.lean`). -/
def vcApiChecks : List Check :=
  [{  name :=
        "the backend point is a choice by the name git: a consumer connects through the latest backend named git, so config's git, registered after a package's, is the one used; a backend of another name, registered after it, is not; with no git backend, one of another name alone or none at all, it has no connection"
      run :=
        pure <|
          branchThrough
                (VcApi.connect? #[namedBackend "git" "package", namedBackend "git" "config"]) ==
              some "config" &&
            branchThrough
                (VcApi.connect? #[namedBackend "git" "package", namedBackend "jj" "config"]) ==
              some "package" &&
            branchThrough (VcApi.connect? #[namedBackend "git" "package"]) == some "package" &&
            (VcApi.connect? #[namedBackend "jj" "config"]).isNone &&
            (VcApi.connect? #[]).isNone },
    { name :=
        "the gutter's job names are the core's (`Gutter.headJob`, `.diffJob`, `.refsJob`), the review segment's name is the one the mode line's default order names, and the backend the implementation registers is called git"
      run :=
        pure <|
          VcApi.gutterJobs == #[Gutter.headJob, Gutter.diffJob, Gutter.refsJob] &&
            VcApi.reviewSegmentName == "review" &&
            ModeLine.Order.standard.left.contains VcApi.reviewSegmentName &&
            VcApi.gitBackendName == "git" },
    { name :=
        "the fake's backend answers every request from the model of its repository: its status is the model's"
      run :=
        pure <|
          let repository := VersionControlContract.clean #[("a.txt", "a\n")]
          match
            (((VcApiTest.backend repository).connect "git" "/r" .status : JobM _).runModel
                {}).1 with
          | .finished (.ok status) => status == repository.status
          | _ => false },
    { name :=
        "the registration contract holds of a package that registers the backend git, the three gutter jobs and the review segment, split over two packages too"
      run :=
        pure <|
          vcKeeps #[vcRegistering "vc" [namedBackend "git" "main"]] &&
            vcKeeps
              #[vcRegistering "vc" [namedBackend "git" "main"] (jobs := false),
                vcRegistering "vc-gutter" [] (segment := false)] },
    { name :=
        "the registration contract fails a package that registers no backend, one whose backend is not called git, one with no gutter jobs, and one with no review segment"
      run :=
        pure <|
          !vcKeeps #[vcRegistering "vc" []] &&
            !vcKeeps #[vcRegistering "vc" [namedBackend "jj" "main"]] &&
            !vcKeeps #[vcRegistering "vc" [namedBackend "git" "main"] (jobs := false)] &&
            !vcKeeps #[vcRegistering "vc" [namedBackend "git" "main"] (segment := false)] }]

end VcApiTest
