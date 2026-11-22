import Editor.Config.Packages
import Editor.Test.Loop
import VcApiTest.Contract
import VersionControl.Compiled
import VersionControlTest.Check

/-!
# Model tests: `VersionControl/Compiled.lean`

The model tests of `VersionControl/Compiled.lean`:
`versionControlPackageChecks`. The test driver's root,
`VersionControlTest/Model.lean`, runs them; its module doc says what each
shows.
-/

namespace VersionControlTest

open Editor

/-- The checks of the `version-control` package
(`VersionControl/Compiled.lean`): the ex names it binds are its own
to bind, and the gutter's package binds none; the gutter's jobs are
restarted by their owner, and none of version control's; and the two packages
together keep the registration check of the interface library `vc-api`
(`VcApiTest.registrationChecks`): the backend `git`, the gutter's jobs and
the segment `review`. -/
def versionControlPackageChecks : List Check :=
  -- The registration check of `vc-api`, which version control implements,
  -- over its two packages together, each of its sentences one check.
  ((VcApiTest.registrationChecks #[VersionControl.package, VersionControl.gutterPackage]).map
      fun (name, held) => { name, run := pure held }) ++
    [{  name :=
          "the registration check of vc-api this list runs bites: over a package of version control's name that registers nothing it fails, and over the gutter's package alone it fails for the backend and the segment and holds for the three jobs"
        run :=
          let broken : Package := { name := VersionControl.package.name, setup := pure () }
          let failing (packages : Array Package) : List String :=
            ((VcApiTest.registrationChecks packages).filter (!·.2)).map (·.1)
          pure
            ((VcApiTest.registrationChecks #[broken]).all (!·.2) &&
              (failing #[VersionControl.gutterPackage]).length == 2) },
      { name :=
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
              (VersionControl.package.registered.jobs.filter (·.restarted)).isEmpty) },
      { name :=
          "the package version-control registers exactly its status apply, hunk apply and commit, vc-status-apply, vc-hunk-apply and vc-commit-run, as reported, so one running when the process ends is said stopped by the next start's restore, and the gutter's package reports none"
        run :=
          pure
            (((VersionControl.package.registered.jobs.filter (·.reported)).map (·.name)) ==
                #[VersionControl.applyJob, VersionControl.hunkApplyJob, VersionControl.commitJob] &&
              (VersionControl.gutterPackage.registered.jobs.filter (·.reported)).isEmpty) },
      { name :=
          "the package version-control registers one codec, its reviews' store vc-review, which a restart keeps, and the gutter's package none"
        run :=
          pure
            ((VersionControl.package.registered.codecs.map (·.name)) ==
                #[VersionControl.reviewStore.name] &&
              VersionControl.reviewStore.name == "vc-review" &&
              VersionControl.gutterPackage.registered.codecs.isEmpty) }]

end VersionControlTest
