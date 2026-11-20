import Editor.Config.Packages
import Editor.Config.Registry
import Editor.VersionControl.Compiled
import ModelTest.Check

/-!
# Model tests: `Editor/VersionControl/Compiled.lean`

The model tests of `Editor/VersionControl/Compiled.lean`:
`versionControlPackageChecks`. The root module `ModelTest` runs them; its
module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the `version-control` package
(`Editor/VersionControl/Compiled.lean`): the ex names it binds are its own
to bind, and the gutter's package binds none; the gutter's jobs are
restarted by their owner, and none of version control's. -/
def versionControlPackageChecks : List Check :=
  [{  name :=
        "the package version-control binds its twelve vc- ex names, in order, each to a command it registers, vc-show, vc-review, vc-log and vc-blame taking text, and the gutter's package binds none"
      run :=
        let registered := VersionControl.package.registered
        pure
          (registered.ex.map (·.name) ==
              #["vc-status", "vc-show", "vc-stage-hunk", "vc-unstage-hunk", "vc-commit",
                "vc-worktrees", "vc-commit-accept", "vc-commit-abort", "vc-review",
                "vc-review-since", "vc-log", "vc-blame"] &&
            registered.ex.all
              (fun binding => registered.commands.any (·.name == binding.command)) &&
            (registered.ex.filter (·.takes == .text)).map (·.name) ==
              #["vc-show", "vc-review", "vc-log", "vc-blame"] &&
            VersionControl.gutterPackage.registered.ex.isEmpty) },
    { name :=
        "the gutter's package registers its three jobs, vc-gutter-head, vc-gutter-diff and vc-gutter-refs, as restarted by their owner, since its reconciler starts them again for every buffer tracked once restored; the package version-control registers none, so a read or a show running at a restart is counted among the other jobs"
      run :=
        pure
          (((VersionControl.gutterPackage.registered.jobs.filter (·.restarted)).map (·.name)) ==
              #[VersionControl.headJob, VersionControl.diffJob, VersionControl.refsJob] &&
            VersionControl.gutterPackage.registered.jobs.size == 3 &&
            (VersionControl.package.registered.jobs.filter (·.restarted)).isEmpty) }]

end ModelTest
