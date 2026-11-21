import ContractTest.Check
import ContractTest.Support.Git
import ContractTest.Support.VersionControl
import Editor.Test.Linked.Rig
import Editor.Test.Linked.Trees
import VcApiTest.Contract

/-!
# Contract tests: `Editor/VersionControl/Log.lean`

The tests of `Editor/VersionControl/Log.lean`: `historyBufferChecks`, the log
buffer, the blame view (`Editor/VersionControl/Blame.lean`) and
`vc-review-since` (`Editor/VersionControl/Review.lean`) over real git. The
root module `ContractTest` runs them; its module doc says what each shows.
-/

namespace ContractTest

open Editor
open Editor.Test.Linked
open VcApiTest.Linked

/-- The name of the buffer the focused view of `loop` shows. -/
def focusedName (loop : Loop TestScheme.scheme) : Option String :=
  loop.state.focusedTarget?.map (·.buffer.name)

/-- The headers of the excerpts of the buffer the focused view of `loop`
shows that are not empty. -/
def focusedHeaders (loop : Loop TestScheme.scheme) : Array String :=
  ((loop.state.focusedTarget?.bind (·.buffer.excerpts)).map fun excerpts =>
        (excerpts.entries.map (·.header)).filter (!·.isEmpty)).getD
    #[]

/-- The first 8 characters of the commit `revision` names in the repository
at `directory`. -/
def shortRevision (home directory : System.FilePath) (revision : String) : IO String := do
  return ((← gitIn home directory #["rev-parse", revision]).trimAscii.take 8).toString

/-- The repository of the history buffer checks: on `main`, `HEAD`, written
by `b` a day after the others, changes `a.txt`'s second line over `B`; the
branch `feature` adds `f.txt` and then `g.txt` to `B`. -/
def historyCheckRepository : VersionControl.Model.Repository :=
  { VersionControlContract.clean
      #[("a.txt",
          "1\ntwo\n3\n")] with
    commits :=
      #[("B", { files := #[("a.txt", "1\n2\n3\n")] }),
        ("F1",
          { parents := #["B"], files := #[("a.txt", "1\n2\n3\n"), ("f.txt", "f\n")]
            authored := { VersionControl.Model.fixedAuthored with subject := "add f" } }),
        ("F2",
          { parents := #["F1"]
            files := #[("a.txt", "1\n2\n3\n"), ("f.txt", "f\n"), ("g.txt", "g\n")]
            authored := { VersionControl.Model.fixedAuthored with subject := "add g" } })]
    parents := #["B"], branches := #[("feature", "F2"), ("base", "B")]
    headAuthored := { author := "b", time := 1767312000, subject := "change two" } }

/-- The checks of the log buffer (`Editor/VersionControl/Log.lean`), the
blame view (`Editor/VersionControl/Blame.lean`) and `vc-review-since`
(`Editor/VersionControl/Review.lean`) over real git, wiring only: their
jobs run over the library's process, file and diff services and the real
text store in a temporary repository, every child's git under
`pinnedAwayConfig`, whose `blame.ignoreRevsFile` names every commit but
`HEAD`'s, and kept from the system's config. -/
def historyBufferChecks (services : Job.Services) : List Check :=
  [{  name :=
        "criteria 1 and 2 over real git: vc-log feature lists feature's two commits newest first, and visiting the older one's row opens its change as a review buffer with its one header"
      run :=
        withConfiguredRepository historyCheckRepository fun home config directory => do
          let rig ← ProjectRig.over (onIsolatedGit services home config)
          let some (logged, texts) ←
            runSettled rig directory
                [openFile (directory / "a.txt"),
                  { command := VersionControl.logName, arguments := [.str "feature"] }]
                reviewKeys statusJobs | return false
          let text ← bufferText rig texts logged "*vc-log: repo@main feature*"
          let some (visited, _) ←
            runSettledFrom rig logged texts [toRow 2, { command := VersionControl.logVisitName }]
                reviewKeys statusJobs | return false
          let (g, f, b) :=
            (← shortRevision home directory "feature", ← shortRevision home directory "feature~1",
              ← shortRevision home directory "base")
          return text ==
                some
                  (s!"repo@main: log of feature\n{g} 2026-01-01 add g (a)\n" ++
                    s!"{f} 2026-01-01 add f (a)\n{b} 2026-01-01 B (a)\n") &&
              focusedName visited == some s!"*vc-review: repo@main {f}*" &&
              focusedHeaders visited == #["f.txt @@ -0,0 +1 @@"] },
    { name :=
        "criterion 3 over real git, under a config that ignores every commit but HEAD's in blame: vc-blame in a.txt names on each row the commit that last changed it and its author, HEAD's and b on the changed line alone, the first commit's and a on the others"
      run :=
        withConfiguredRepository historyCheckRepository fun home config directory => do
          let rig ← ProjectRig.over (onIsolatedGit services home config)
          let some (blamed, texts) ←
            runSettled rig directory
                [openFile (directory / "a.txt"), { command := VersionControl.blameName }] reviewKeys
                statusJobs | return false
          let text ← bufferText rig texts blamed "*vc-blame: a.txt@HEAD*"
          let (head, base) :=
            (← shortRevision home directory "HEAD", ← shortRevision home directory "base")
          return text ==
              some
                (s!"{base} a 2026-01-01 | 1\n{head} b 2026-01-02 | two\n" ++
                  s!"{base} a 2026-01-01 | 3\n") },
    { name :=
        "criterion 4 over real git: after vc-review against base and a new commit, vc-review-since shows the new commit's hunk alone; after that commit is amended, vc-review-since opens the range-diff of the branch's commits since, which pairs the amended one !"
      run :=
        withConfiguredRepository historyCheckRepository fun home config directory => do
          let rig ← ProjectRig.over (onIsolatedGit services home config)
          let some (reviewed, texts) ←
            runSettled rig directory
                [openFile (directory / "a.txt"),
                  { command := VersionControl.reviewName, arguments := [.str "base"] }]
                reviewKeys statusJobs | return false
          let reviewedAt ← shortRevision home directory "HEAD"
          writeMaking (directory / "c.txt") VersionControlContract.tenLines
          discard <| gitIn home directory #["add", "-A"]
          discard <|
              gitIn home directory #["-c", "commit.gpgsign=false", "commit", "-q", "-m", "add c"]
          let committed ← shortRevision home directory "HEAD"
          let some (since, texts) ←
            runSettledFrom rig reviewed texts [{ command := VersionControl.reviewSinceName }]
                reviewKeys statusJobs | return false
          writeMaking (directory / "c.txt") VersionControlContract.sixChanged
          discard <| gitIn home directory #["add", "-A"]
          discard <|
              gitIn home directory
                #["-c", "commit.gpgsign=false", "commit", "-q", "--amend", "-m", "add c"]
          let some (rewritten, texts) ←
            runSettledFrom rig since texts [{ command := VersionControl.reviewSinceName }]
                reviewKeys statusJobs | return false
          let range ← bufferText rig texts rewritten "*vc-range-diff: repo@main*"
          return focusedName since == some s!"*vc-review: repo@main since {reviewedAt}*" &&
              focusedHeaders since == #["c.txt @@ -0,0 +1,10 @@"] &&
              focusedName rewritten == some "*vc-range-diff: repo@main*" &&
              range.any fun text =>
                text.startsWith
                    s!"repo@main: HEAD was rewritten since {committed}; its commits against base\n" &&
                  (text.splitOn "\n").any fun line => (line.splitOn " ! ").length > 1 }]

end ContractTest
