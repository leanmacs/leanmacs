import Editor.VersionControl
import Editor.VersionControl.Model

/-!
# The contract of the version-control interface

Properties every implementation of the version-control port
(`Editor/VersionControl.lean`) must have, each a program over the port and
the repository it starts from. One list, run three ways, so the model
cannot drift from git:

- by `model-test`, against the model (`Model.handle`), from the property's
  repository;
- by `model-test`, the git implementation's status read of each property's
  repository, on the job model whose scripts print the model's status as
  git would (`Repository.jobModel`): the job model holds static scripts, so
  only a read runs there;
- by `contract-test`, against the git implementation over the library's
  process service, in a temporary repository written from the property's
  repository with git's plumbing (`ContractTest.writeRepository`).

Property 1 is the adapter test of the phase's first criterion: git and the
model agree on a repository with a staged, an unstaged, an untracked, a
renamed and a conflicted file, and both give the status the property
states.

## Adding to this

A new request's behaviour is a new property here, with the repository that
shows it; what it needs written to disk is the writer's, in
`ContractTest`.
-/

namespace Editor.VersionControlContract

open VersionControl

/-- One property: what must hold, the repository it starts from, and the
program that observes it. -/
structure Property where
  /-- What must hold, as a sentence. -/
  name : String
  /-- The repository the program starts from. -/
  repository : Model.Repository
  /-- Observes the behaviour; `true` when it holds. -/
  holds : VersionControlM Bool

/-- The status, or `none` when the read failed. -/
def statusOf : VersionControlM (Option Status) := do
  match ← status with
  | .ok read =>
    return some read
  | .error _ =>
    return none

/-- The states of `path` in the status, in order; none when the read
failed. -/
def statesOf (path : String) : VersionControlM (Array FileState) := do
  match ← status with
  | .ok read =>
    return (read.files.filter (·.path == path)).map (·.state)
  | .error _ =>
    return #[]

/-- Whether `path` has exactly the one state `state`. -/
def stateIs (path : String) (state : FileState) : VersionControlM Bool := do
  return (← statesOf path) == #[state]

/-- Whether a write's reply is a success. -/
def succeeded (reply : Except Error Unit) : Bool :=
  reply matches .ok ()

/-- A repository on `main` whose `HEAD`, index and working tree all hold
`files`. -/
def clean (files : Array (String × String)) : Model.Repository :=
  { committed := files, index := files.map fun (path, content) => (path, .file content)
    worktree := files }

/-- `repository` with the working tree's `path` holding `content`. -/
def writing (repository : Model.Repository) (path content : String) : Model.Repository :=
  { repository with worktree := (repository.worktree.filter (·.1 != path)).push (path, content) }

/-- `repository` with `path` gone from the working tree. -/
def removing (repository : Model.Repository) (path : String) : Model.Repository :=
  { repository with worktree := repository.worktree.filter (·.1 != path) }

/-- The repository of property 1: a staged modification, an unstaged
modification, an untracked file, a staged rename and a both-modified
conflict. -/
def criterionRepository : Model.Repository :=
  { committed :=
      #[("conflict.txt", "base\n"), ("old.txt", "moved\n"), ("staged.txt", "one\n"),
        ("unstaged.txt", "one\n")]
    index :=
      #[("conflict.txt", .conflict (some "base\n") (some "ours\n") (some "theirs\n")),
        ("new.txt", .file "moved\n"), ("staged.txt", .file "two\n"),
        ("unstaged.txt", .file "one\n")]
    worktree :=
      #[("conflict.txt", "merged\n"), ("new.txt", "moved\n"), ("staged.txt", "two\n"),
        ("unstaged.txt", "two\n"), ("untracked.txt", "new\n")] }

/-- The status property 1 states of `criterionRepository`. -/
def criterionStatus : Status :=
  { head := .branch "main"
    files :=
      #[{ path := "conflict.txt", state := .conflicted .bothModified },
        { path := "new.txt", state := .renamed "old.txt" none },
        { path := "staged.txt", state := .changed (some .modified) none },
        { path := "unstaged.txt", state := .changed none (some .modified) },
        { path := "untracked.txt", state := .untracked }] }

/-- The interface's properties. -/
def properties : List Property :=
  [{  name :=
        "criterion 1: a repository with a staged modification, an unstaged modification, an untracked file, a staged rename and a both-modified conflict answers exactly those five files with those states, on main"
      repository := criterionRepository
      holds := return (← statusOf) == some criterionStatus },
    { name := "a clean repository answers no files"
      repository := clean #[("a.txt", "a\n")]
      holds := return (← statusOf) == some { head := .branch "main" } },
    { name := "staging an unstaged modification leaves it staged and nothing unstaged"
      repository := writing (clean #[("a.txt", "one\n")]) "a.txt" "two\n"
      holds := do
        let staged ← stage #["a.txt"]
        return succeeded staged && (← stateIs "a.txt" (.changed (some .modified) none)) },
    { name := "staging an untracked file leaves it staged as added"
      repository := writing (clean #[("a.txt", "a\n")]) "n.txt" "new\n"
      holds := do
        let staged ← stage #["n.txt"]
        return succeeded staged && (← stateIs "n.txt" (.changed (some .added) none)) },
    { name := "staging an unstaged deletion leaves it staged as deleted"
      repository := removing (clean #[("a.txt", "a\n"), ("b.txt", "b\n")]) "b.txt"
      holds := do
        let staged ← stage #["b.txt"]
        return succeeded staged && (← stateIs "b.txt" (.changed (some .deleted) none)) },
    { name := "staging a conflicted file resolves it to the working tree's content"
      repository :=
        { committed := #[("c.txt", "base\n")]
          index := #[("c.txt", .conflict (some "base\n") (some "ours\n") (some "theirs\n"))]
          worktree := #[("c.txt", "merged\n")] }
      holds := do
        let staged ← stage #["c.txt"]
        return succeeded staged && (← stateIs "c.txt" (.changed (some .modified) none)) },
    { name := "unstaging a staged modification leaves it unstaged"
      repository :=
        { committed := #[("a.txt", "one\n")], index := #[("a.txt", .file "two\n")]
          worktree := #[("a.txt", "two\n")] }
      holds := do
        let unstaged ← unstage #["a.txt"]
        return succeeded unstaged && (← stateIs "a.txt" (.changed none (some .modified))) },
    { name := "unstaging a staged new file leaves it untracked"
      repository :=
        { committed := #[("a.txt", "a\n")]
          index := #[("a.txt", .file "a\n"), ("n.txt", .file "new\n")]
          worktree := #[("a.txt", "a\n"), ("n.txt", "new\n")] }
      holds := do
        let unstaged ← unstage #["n.txt"]
        return succeeded unstaged && (← stateIs "n.txt" .untracked) },
    { name :=
        "unstaging a staged rename by both its paths leaves its origin an unstaged deletion and its new path untracked"
      repository :=
        { committed := #[("old.txt", "moved\n")], index := #[("new.txt", .file "moved\n")]
          worktree := #[("new.txt", "moved\n")] }
      holds := do
        let renamed ← stateIs "new.txt" (.renamed "old.txt" none)
        let unstaged ← unstage #["new.txt", "old.txt"]
        return renamed && succeeded unstaged &&
            (← stateIs "old.txt" (.changed none (some .deleted))) &&
            (← stateIs "new.txt" .untracked) },
    { name := "an empty file moved in the index is a rename, as a file with content is"
      repository :=
        { committed := #[("e.txt", "")], index := #[("f.txt", .file "")]
          worktree := #[("f.txt", "")] }
      holds := do
        return (← stateIs "f.txt" (.renamed "e.txt" none)) && (← statesOf "e.txt").isEmpty },
    { name :=
        "on an unborn branch a staged new file is staged as added on that branch, and unstaging it leaves it untracked"
      repository := { index := #[("a.txt", .file "a\n")], worktree := #[("a.txt", "a\n")] }
      holds := do
        let before ← statusOf
        let unstaged ← unstage #["a.txt"]
        return before ==
              some
                { head := .branch "main"
                  files := #[{ path := "a.txt", state := .changed (some .added) none }] } &&
            succeeded unstaged &&
            (← stateIs "a.txt" .untracked) },
    { name := "a detached checkout answers that it is detached"
      repository := { clean #[("a.txt", "a\n")] with head := .detached }
      holds := return ((← statusOf).map (·.head)) == some .detached },
    { name :=
        "a path with a space and a non-ASCII path round-trip through status, stage and unstage"
      repository :=
        writing (writing (clean #[("with space.txt", "one\n")]) "with space.txt" "two\n")
          "héllo.txt" "h\n"
      holds := do
        let before :=
          (← stateIs "with space.txt" (.changed none (some .modified))) &&
            (← stateIs "héllo.txt" .untracked)
        let staged ← stage #["with space.txt", "héllo.txt"]
        let afterStage :=
          (← stateIs "with space.txt" (.changed (some .modified) none)) &&
            (← stateIs "héllo.txt" (.changed (some .added) none))
        let unstaged ← unstage #["with space.txt", "héllo.txt"]
        let afterUnstage :=
          (← stateIs "with space.txt" (.changed none (some .modified))) &&
            (← stateIs "héllo.txt" .untracked)
        return before && succeeded staged && afterStage && succeeded unstaged && afterUnstage },
    { name :=
        "staging a path in neither the index nor the working tree is refused, and nothing is staged, the request's other paths included"
      repository := writing (clean #[("a.txt", "one\n")]) "a.txt" "two\n"
      holds := do
        let before ← statusOf
        let staged ← stage #["a.txt", "nope.txt"]
        return !succeeded staged && before.isSome && (← statusOf) == before }]

end Editor.VersionControlContract
