import ContractTest.Check
import ContractTest.Support.Git
import Editor.Job
import Editor.Program
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Trees
import Editor.VersionControl.Git
import Editor.VersionControl.Git.Model
import VcApi
import VcApiTest.Contract
import VcApiTest.Fake

/-!
# Contract tests: `Editor/VersionControl/Git.lean`

The tests of `Editor/VersionControl/Git.lean`: `versionControlChecks`, the git
implementation of the version-control interface over real git, and
`inLanesChecks` and `versionControlFailures`, the contract of the interface
library `vc-api` (`VcApiTest/Contract.lean`) run against the git
implementation over real git, the implementation version control registers
as `vc-api`'s backend (D7 (c): the core keeps the model's run,
`ModelTest.versionControlContractFailures`). The root module
`ContractTest` runs them; its module doc says what each shows.
-/

namespace ContractTest

open Editor
open Editor.Test.Linked
open VcApiTest.Linked

/-- The checks of the git implementation over real git of what the model has
no value for: a branch's change asked from each of two worktrees made with
git itself, files added with intent to add, which git alone makes, what to
watch in a linked worktree, and a commit's message, which the model does
not keep. -/
def versionControlChecks (services : Job.Services) : List Check :=
  [{  name :=
        "criterion 4: in a temporary repository whose linked worktree on feature committed a.txt modified, c.txt added and d.txt deleted, while main committed m.txt after they forked, changes asked from the linked worktree (HEAD against main) and from the main one (feature against main) each answer those three files with their old and new content, and fileAt of the base reads a.txt's old content"
      run :=
        withRepository fun home directory => do
          writeGitRepository home directory
              (VersionControlContract.clean #[("a.txt", "1\n"), ("b.txt", "b\n"), ("d.txt", "d\n")])
          let linked := directory.parent.getD directory / "feature"
          discard <|
              gitIn home directory #["worktree", "add", "-q", "-b", "feature", linked.toString]
          writeMaking (linked / "a.txt") "2\n"
          writeMaking (linked / "c.txt") "new\n"
          IO.FS.removeFile (linked / "d.txt")
          discard <| gitIn home linked #["add", "-A"]
          discard <|
              gitIn home linked #["-c", "commit.gpgsign=false", "commit", "-q", "-m", "feature"]
          writeMaking (directory / "m.txt") "m\n"
          discard <| gitIn home directory #["add", "-A"]
          discard <|
              gitIn home directory #["-c", "commit.gpgsign=false", "commit", "-q", "-m", "main"]
          let expected : Array VersionControl.FileChange :=
            #[{ path := "a.txt", old := some "1\n", new := some "2\n" },
              { path := "c.txt", old := none, new := some "new\n" },
              { path := "d.txt", old := some "d\n", new := none }]
          let asked (root : System.FilePath) (revision : String) : JobM Bool := do
            let handler := VersionControl.Git.handler "git" root
            match ← Program.runM handler (VersionControl.changes revision "main") with
            | .ok change =>
              return change.files == expected &&
                  (← Program.runM handler (VersionControl.fileAt change.base "a.txt")) ==
                    .ok (some "1\n")
            | .error _ =>
              return false
          let fromLinked ← runOnTimers (onIsolatedGit services home) (asked linked "HEAD")
          let fromMain ← runOnTimers (onIsolatedGit services home) (asked directory "feature")
          return fromLinked == .finished true && fromMain == .finished true },
    { name :=
        "in a linked worktree, watched names the main repository's git directory to watch, and HEAD and the index of the worktree's own git directory under it"
      run :=
        withRepository fun home directory => do
          writeGitRepository home directory (VersionControlContract.clean #[("a.txt", "a\n")])
          let linked := directory.parent.getD directory / "linked"
          discard <| gitIn home directory #["worktree", "add", "-q", "--detach", linked.toString]
          -- git spells the common directory as it found it, which may be
          -- through a link (a temporary directory's on macOS), so the
          -- answer is held to the names of what it names.
          let asked : JobM Bool := do
            match
              ← Program.runM (VersionControl.Git.handler "git" linked) VersionControl.watched with
            | .ok answer =>
              let common := answer.directory
              let own := common / "worktrees" / "linked"
              return common.toString.endsWith "/repo/.git" &&
                  answer.paths == #[own / "HEAD", own / "index", common / "packed-refs"] &&
                  answer.trees == #[common / "refs"]
            | .error _ =>
              return false
          return (← runOnTimers (onIsolatedGit services home) asked) == .finished true },
    { name :=
        "files moved in the working tree and added with intent to add, which git reads as renames in the working tree, read as each origin's unstaged deletion, joined with its staged change, and each new path's unstaged addition"
      run :=
        withRepository fun home directory => do
          writeGitRepository home directory
              { committed := #[("a.txt", "a\n"), ("b.txt", "b\n")]
                index := #[("a.txt", .file "a\n"), ("b.txt", .file "staged\n")]
                worktree := #[("a.txt", "a\n"), ("b.txt", "staged\n")] }
          IO.FS.rename (directory / "a.txt") (directory / "c.txt")
          IO.FS.rename (directory / "b.txt") (directory / "d.txt")
          discard <| gitIn home directory #["add", "-N", "--", "c.txt", "d.txt"]
          gitStatusIs (onIsolatedGit services home) directory
              { head := .branch "main"
                files :=
                  #[{ path := "a.txt", state := .changed none (some .deleted) },
                    { path := "b.txt", state := .changed (some .modified) (some .deleted) },
                    { path := "c.txt", state := .changed none (some .added) },
                    { path := "d.txt", state := .changed none (some .added) }] } },
    { name :=
        "a commit's message is the message given, a line that starts with # kept, under a user config whose commit.cleanup is strip"
      run :=
        withConfiguredRepository
          { committed := #[("a.txt", "one\n")], index := #[("a.txt", .file "two\n")]
            worktree := #[("a.txt", "two\n")] } fun home config directory => do
          let message := "Subject\n\n# kept\nbody\n"
          let committed : JobM Bool := do
            return (←
                  Program.runM (VersionControl.Git.handler "git" directory)
                      (VersionControl.commit message)) matches
                .ok ()
          let ran ← runOnTimers (onIsolatedGit services home config) committed
          let object ← gitIn home directory #["cat-file", "commit", "HEAD"]
          return ran == .finished true && object.endsWith s!"\n\n{message}" }]

/-- How many of the version-control contract's properties run at once. It
is bounded, not one lane per property, because each property's job must end
within `patience` or fails as one that did not end, and on a runner with few
cores and every core busy, every property's git at once could push one past
it. -/
def versionControlLanes : Nat :=
  8

/-- Runs `run` on each of `items` in `width` lanes, each a dedicated task
that takes every `width`-th item in turn: one result per item, in `items`'
order. A width of 0 is taken as 1, so no item is ever left unrun. An item
whose run throws gives `failed` its error, and only that item: the lane
goes on to its next item, whose result is its own. The lanes are dedicated
threads, because each item may block on a process or on `eventually`, and
Lean's task pool must stay as the job checks measure it. -/
def inLanes {α β : Type} (width : Nat) (items : List α) (run : α → IO β)
    (failed : α → IO.Error → β) : IO (List β) := do
  let width := max width 1
  let numbered := items.zipIdx
  let lanes :=
    (List.range width).map fun lane => numbered.filter fun (_, index) => index % width == lane
  let tasks ←
    lanes.mapM fun lane =>
        IO.asTask (prio := .dedicated)
          (lane.mapM fun (item, index) => do
            try
              return (index, ← run item)
            catch error =>
              return (index, failed item error))
  let results ←
    tasks.flatMapM fun task => do
        -- A lane catches each item's error, so it cannot throw.
        IO.ofExcept (← IO.wait task)
  return (results.mergeSort fun a b => a.1 ≤ b.1).map (·.2)

/-- Runs `inLanes` at `width` over the numbers below `count`, where running
`thrown` throws and running any other number gives `ran` and the number. -/
def runInLanes (width count thrown : Nat) : IO (List String) :=
  inLanes width (List.range count) (failed := fun item error => s!"failed {item}: {error}")
    fun item => if item == thrown then throw (IO.userError "thrown") else return s!"ran {item}"

/-- What `runInLanes width count thrown` must give: one result per number, in
order, only the thrown one failed. -/
def ranInLanes (count thrown : Nat) : List String :=
  (List.range count).map fun item =>
    if item == thrown then s!"failed {item}: thrown" else s!"ran {item}"

/-- The checks of `inLanes` itself, over plain numbers, with no git and no
process: that it gives one result per item, in the items' order, at any
width, at a width of 0 too, so the version-control properties can never be
run as none; and that an item that throws fails alone, its lane's other
items run and keep their own results. -/
def inLanesChecks : List Check :=
  [{  name := "inLanes gives each item's result in the items' order in one lane"
      run := return (← runInLanes 1 7 7) == ranInLanes 7 7 },
    { name := "inLanes gives each item's result in the items' order in three lanes"
      run := return (← runInLanes 3 10 10) == ranInLanes 10 10 },
    { name := "inLanes gives each item's result in order with more lanes than items"
      run := return (← runInLanes 20 5 5) == ranInLanes 5 5 },
    { name := "inLanes at a width of 0 runs every item, as in one lane"
      run := return (← runInLanes 0 5 5) == ranInLanes 5 5 },
    { name := "inLanes over no items gives no results"
      run := return (← runInLanes 3 0 0) == [] },
    { name :=
        "inLanes fails only the item that threw, and its lane's other items keep their results"
      run := return (← runInLanes 3 10 4) == ranInLanes 10 4 },
    { name := "inLanes fails only the item that threw in a single lane"
      run := return (← runInLanes 1 6 0) == ranInLanes 6 0 }]

/-- The names of the version-control contract's properties
(`Editor/VersionControl/Contract.lean`) that do not hold of the git
implementation over the library's process service, each property's
repository written out with real git in a temporary directory and home of
its own (`writeGitRepository`), every child's git kept from the system's
config and given `pinnedAwayConfig` as the user's (`onIsolatedGit`); and
that every child it ran, in every lane, is reaped once all have ended. The
properties run `versionControlLanes` at a time (`inLanes`), and their
failures are reported in the contract's order. Property 1 is the phase's
adapter test of git against the model. -/
def versionControlFailures (services : Job.Services) : IO (List String) := do
  let before ← Ffi.processesPending
  let outcomes ←
    inLanes versionControlLanes VersionControlContract.properties (failed := fun property error =>
        some s!"{property.name} ({error})") fun property =>
        withRepository fun home directory => do
          try
            writeGitRepository home directory property.repository
            let config := home / "gitconfig"
            IO.FS.writeFile config pinnedAwayConfig
            let outcome ←
              runOnTimers (onIsolatedGit services home config)
                  (property.holds.runM (VersionControl.Git.handler "git" directory))
            return if outcome == .finished true then none
              else some s!"{property.name} ({repr outcome})"
          catch error =>
            return some s!"{property.name} (writing its repository: {error})"
  let failed := outcomes.filterMap id
  let reaped ← eventually (return (← Ffi.processesPending) == before)
  return failed.map (s!"the version-control interface over git: {·}") ++
      if reaped then [] else ["every child the git implementation ran is reaped"]

end ContractTest
