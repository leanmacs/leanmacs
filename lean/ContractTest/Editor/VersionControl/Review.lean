import ContractTest.Check
import ContractTest.Support.Git
import ContractTest.Support.VersionControl
import Editor.Test.Linked.Rig
import Editor.Test.Linked.Trees
import Editor.VersionControl.Contract

/-!
# Contract tests: `Editor/VersionControl/Review.lean`

The tests of `Editor/VersionControl/Review.lean`: `reviewBufferChecks`, the
review buffer over real git. The root module `ContractTest` runs them; its
module doc says what each shows.
-/

namespace ContractTest

open Editor
open Editor.Test.Linked

/-- The lines `1` to `20`, each ended by a line feed. -/
def twentyLines : String :=
  String.join ((List.range 20).map fun row => s!"{row + 1}\n")

/-- The checks of the review buffer (`Editor/VersionControl/Review.lean`) over
real git, wiring only: its jobs run over the library's process, file and
diff services and the real text store in a temporary repository, every
child's git under `pinnedAwayConfig` and kept from the system's config. -/
def reviewBufferChecks (services : Job.Services) : List Check :=
  [{  name :=
        "criteria 1 and 2 over real git: in a linked worktree on feature, whose commit changes a.txt in two hunks and b.txt, vc-review with no text reviews against the main worktree's branch, both files' hunks under their headers; vc-review-revert on a.txt's first hunk makes a.txt's buffer hold the base's lines for it and the branch's for the other, and leaves b.txt"
      run :=
        withConfiguredRepository
          (VersionControlContract.clean #[("a.txt", twentyLines), ("b.txt", "b\n")])
          fun home config directory => do
          let linked := directory.parent.getD directory / "feature"
          discard <|
              gitIn home directory #["worktree", "add", "-q", "-b", "feature", linked.toString]
          let changed :=
            VersionControlContract.lineSet (VersionControlContract.lineSet twentyLines 1 "two\n") 15
              "sixteen\n"
          writeMaking (linked / "a.txt") changed
          writeMaking (linked / "b.txt") "bee\n"
          discard <| gitIn home linked #["add", "-A"]
          discard <|
              gitIn home linked #["-c", "commit.gpgsign=false", "commit", "-q", "-m", "feature"]
          let rig ← ProjectRig.over (onIsolatedGit services home config)
          let some (reviewed, texts) ←
            runSettled rig linked
                [openFile (linked / "a.txt"), { command := VersionControl.reviewName }] reviewKeys
                statusJobs | return false
          let headers :=
            ((reviewed.state.focusedTarget?.bind (·.buffer.excerpts)).map fun excerpts =>
                  (excerpts.entries.map (·.header)).filter (!·.isEmpty)).getD
              #[]
          let some (reverted, texts) ←
            runSettledFrom rig reviewed texts
                [{ command := "to-excerpt", arguments := [.nat 1] },
                  { command := VersionControl.reviewRevertName }]
                reviewKeys statusJobs | return false
          let first ← bufferText rig texts reverted "a.txt"
          let other ← bufferText rig texts reverted "b.txt"
          return headers ==
                #["a.txt @@ -1,5 +1,5 @@", "a.txt @@ -13,7 +13,7 @@", "b.txt @@ -1 +1 @@"] &&
              first == some (VersionControlContract.lineSet twentyLines 15 "sixteen\n") &&
              other == some "bee\n" &&
              reverted.state.echo == "reverted a hunk of a.txt" }]

end ContractTest
