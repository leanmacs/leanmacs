import Editor.Diff.Model
import Editor.VersionControl
import Editor.VersionControl.Hunk
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
  repository with git's plumbing (`ContractTest.writeGitRepository`),
  under a user config that asks for copies and for no untracked files,
  which the git implementation's command line pins away
  (`ContractTest.pinnedAwayConfig`).

Property 1 is the adapter test of the phase's first criterion: git and the
model agree on a repository with a staged, an unstaged, an untracked, a
renamed and a conflicted file, and both give the status the property
states.

The properties of a hunk take their hunks as the editor does, from the
texts the repository holds: the model's line diff (`DiffModel.hunks`), made
`LineHunk`s with their context from the index (`LineHunk.ofTexts`), so a
property tests the interface and not a diff engine. One of them is the
adapter test of phase 3's first criterion: staging one hunk of a file with
two changed hunks stages that hunk alone.

The properties of worktrees (`worktreeProperties`) never write a path:
each takes the main worktree's path from the `worktrees` reply and names
the others beside it (`beside`), so one program holds of the model's `/r`
and of a temporary directory, which git spells with links resolved. The
first is the adapter test of phase 4's third criterion: creating a
worktree for a new branch and removing it leaves the list as it was, with
the worktree on its branch in between. Its refusals compare the exit, and
a change's the exit and the message, so the model cannot drift from
git.

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

/-- `text` with its line at row `row` replaced by `line`. -/
def lineSet (text : String) (row : Nat) (line : String) : String :=
  String.join ((linesOf text).set! row line).toList

/-- The lines `1` to `10`, each ended by a line feed. -/
def tenLines : String :=
  String.join ((List.range 10).map fun row => s!"{row + 1}\n")

/-- `tenLines` with row 1 (`2`) changed. -/
def secondChanged : String :=
  lineSet tenLines 1 "two\n"

/-- `tenLines` with rows 1 (`2`) and 8 (`9`) changed: two hunks. -/
def twoChanged : String :=
  lineSet secondChanged 8 "nine\n"

/-- The hunks of `old` against `new`, going `side`, as the editor makes them:
the model's line diff, each with its context from the index. -/
def lineHunks (side : HunkSide) (old new : String) : Array LineHunk :=
  (DiffModel.hunks old new 100000).map (LineHunk.ofTexts side old new)

/-- The index's content of `path`, as `fileAt` reads it; none when it has no
merged file there or the read failed. -/
def indexOf (path : String) : VersionControlM (Option String) := do
  match ← fileAt "" path with
  | .ok content =>
    return content
  | .error _ =>
    return none

/-- Stages the first hunk of `path`'s working-tree content `worktree` against
its index, taken from the index read back: the reply, or a refusal when
there is no such hunk. -/
def stageFirst (path worktree : String) : VersionControlM (Except Error Unit) := do
  let some index ← indexOf path | return .error (.unparsable "no index content")
  match (lineHunks .stage index worktree)[0]? with
  | some hunk =>
    stageHunk path hunk
  | none =>
    return .error (.unparsable "no hunk")

/-- Whether a refusal's message holds each line of `printed`. -/
def saidEach (printed : String) : Except Error Unit → Bool
  | .error (.failed _ message) =>
    (linesOf printed).all fun line => (message.splitOn line.trimAsciiEnd.toString).length > 1
  | _ => false

/-- The interface's properties of hunks and commits (phase 3). -/
def hunkProperties : List Property :=
  [{  name :=
        "criterion 1: staging one hunk of a file with two changed hunks stages that hunk alone"
      repository := writing (clean #[("a.txt", tenLines)]) "a.txt" twoChanged
      holds := do
        let hunks := lineHunks .stage tenLines twoChanged
        let some first := hunks[0]? | return false
        let staged ← stageHunk "a.txt" first
        return hunks.size == 2 && succeeded staged && (← indexOf "a.txt") == some secondChanged &&
            (← stateIs "a.txt" (.changed (some .modified) (some .modified))) },
    { name :=
        "staging a file's second hunk after its first is staged leaves the index as the working tree"
      repository := writing (clean #[("a.txt", tenLines)]) "a.txt" twoChanged
      holds := do
        let first ← stageFirst "a.txt" twoChanged
        let second ← stageFirst "a.txt" twoChanged
        return succeeded first && succeeded second && (← indexOf "a.txt") == some twoChanged &&
            (← stateIs "a.txt" (.changed (some .modified) none)) },
    { name :=
        "staging one of two changes three lines apart stages it alone: its context overlaps the other change and is the index's"
      repository :=
        writing (clean #[("a.txt", tenLines)]) "a.txt" (lineSet secondChanged 4 "five\n")
      holds := do
        let staged ← stageFirst "a.txt" (lineSet secondChanged 4 "five\n")
        return succeeded staged && (← indexOf "a.txt") == some secondChanged },
    { name := "unstaging one of two staged hunks leaves the index HEAD's with the other hunk"
      repository :=
        { committed := #[("a.txt", tenLines)], index := #[("a.txt", .file twoChanged)]
          worktree := #[("a.txt", twoChanged)] }
      holds := do
        let some first := (lineHunks .unstage tenLines twoChanged)[0]? | return false
        let unstaged ← unstageHunk "a.txt" first
        return succeeded unstaged && (← indexOf "a.txt") == some (lineSet tenLines 8 "nine\n") &&
            (← stateIs "a.txt" (.changed (some .modified) (some .modified))) },
    { name := "a hunk whose lines are not in the index is refused, and the index is as it was"
      repository := writing (clean #[("a.txt", tenLines)]) "a.txt" twoChanged
      holds := do
        let staged ← stageHunk "a.txt" (LineHunk.make 0 0 "" "nowhere\n" "else\n" "")
        let unstaged ← unstageHunk "a.txt" (LineHunk.make 0 0 "" "nowhere\n" "else\n" "")
        return !succeeded staged && !succeeded unstaged && (← indexOf "a.txt") == some tenLines },
    { name :=
        "a hunk changing a last line without a line feed, and one adding the line feed, each stage exactly"
      repository :=
        writing (writing (clean #[("c.txt", "a\nb\nc"), ("f.txt", "a\nb\nc")]) "c.txt" "a\nb\nC")
          "f.txt" "a\nb\nc\n"
      holds := do
        let changed ← stageFirst "c.txt" "a\nb\nC"
        let fed ← stageFirst "f.txt" "a\nb\nc\n"
        return succeeded changed && succeeded fed && (← indexOf "c.txt") == some "a\nb\nC" &&
            (← indexOf "f.txt") == some "a\nb\nc\n" },
    { name :=
        "a hunk of CRLF lines stages with its carriage returns, and an added line ending in spaces keeps them"
      repository :=
        writing
          (writing (clean #[("crlf.txt", "a\r\nb\r\nc\r\n"), ("spaces.txt", "a\nb\n")]) "crlf.txt"
            "a\r\nB\r\nc\r\n")
          "spaces.txt" "a\nb\nc  \n"
      holds := do
        let crlf ← stageFirst "crlf.txt" "a\r\nB\r\nc\r\n"
        let spaces ← stageFirst "spaces.txt" "a\nb\nc  \n"
        return succeeded crlf && succeeded spaces &&
            (← indexOf "crlf.txt") == some "a\r\nB\r\nc\r\n" &&
            (← indexOf "spaces.txt") == some "a\nb\nc  \n" },
    { name := "a hunk of a path with a space and of a non-ASCII path stages"
      repository :=
        writing
          (writing (clean #[("with space.txt", "one\n"), ("héllo.txt", "one\n")]) "with space.txt"
            "two\n")
          "héllo.txt" "two\n"
      holds := do
        let spaced ← stageFirst "with space.txt" "two\n"
        let accented ← stageFirst "héllo.txt" "two\n"
        return succeeded spaced && succeeded accented &&
            (← indexOf "with space.txt") == some "two\n" &&
            (← indexOf "héllo.txt") == some "two\n" },
    { name := "a hunk into a file the index holds empty stages"
      repository := writing (clean #[("e.txt", "")]) "e.txt" "a\nb\n"
      holds := do
        let staged ← stageFirst "e.txt" "a\nb\n"
        return succeeded staged && (← indexOf "e.txt") == some "a\nb\n" },
    { name :=
        "committing a staged change makes HEAD the index, and the status then shows only the unstaged change"
      repository :=
        { committed := #[("a.txt", "one\n")], index := #[("a.txt", .file "two\n")]
          worktree := #[("a.txt", "three\n")] }
      holds := do
        let committed ← commit "a message\n"
        return succeeded committed && (← fileAt "HEAD" "a.txt") == .ok (some "two\n") &&
            (← stateIs "a.txt" (.changed none (some .modified))) },
    { name := "committing on an unborn branch makes its first commit"
      repository := { index := #[("a.txt", .file "a\n")], worktree := #[("a.txt", "a\n")] }
      holds := do
        let committed ← commit "first\n"
        return succeeded committed && (← fileAt "HEAD" "a.txt") == .ok (some "a\n") &&
            (← statusOf) == some { head := .branch "main" } },
    { name := "committing with nothing staged is refused, and HEAD is as it was"
      repository := writing (clean #[("a.txt", "one\n")]) "a.txt" "two\n"
      holds := do
        let before ← statusOf
        let committed ← commit "nothing\n"
        return !succeeded committed && (← fileAt "HEAD" "a.txt") == .ok (some "one\n") &&
            before.isSome &&
            (← statusOf) == before },
    { name :=
        "committing with a conflicted file is refused with status 128 before a hook runs, and HEAD and the index are as they were"
      repository :=
        { committed := #[("a.txt", "one\n"), ("c.txt", "base\n")]
          index :=
            #[("a.txt", .file "two\n"),
              ("c.txt", .conflict (some "base\n") (some "ours\n") (some "theirs\n"))]
          worktree := #[("a.txt", "two\n"), ("c.txt", "merged\n")]
          hook := some "the hook ran\n" }
      holds := do
        let before ← statusOf
        let committed ← commit "conflicted\n"
        return committed matches .error (.failed (.code 128) _) &&
            saidEach "error: Committing is not possible because you have unmerged files."
              committed &&
            !saidEach "the hook ran" committed &&
            (← fileAt "HEAD" "a.txt") == .ok (some "one\n") &&
            (← indexOf "a.txt") == some "two\n" &&
            before.isSome &&
            (← statusOf) == before },
    { name :=
        "a commit a hook refuses fails with every line the hook printed on either stream, and HEAD and the index are as they were"
      repository :=
        { committed := #[("a.txt", "one\n")], index := #[("a.txt", .file "two\n")]
          worktree := #[("a.txt", "two\n")]
          hook := some "the hook says no on its output\nthe hook says no on its error\n" }
      holds := do
        let committed ← commit "refused\n"
        return saidEach "the hook says no on its output\nthe hook says no on its error\n"
              committed &&
            (← fileAt "HEAD" "a.txt") == .ok (some "one\n") &&
            (← indexOf "a.txt") == some "two\n" }]

/-- The directory named `name` beside `path`: in the directory that holds
`path`, spelled with one separator under the root. -/
def beside (path : System.FilePath) (name : String) : System.FilePath :=
  match path.parent with
  | some parent => if parent.toString == "/" then ⟨"/" ++ name⟩ else parent / name
  | none => name

/-- The worktrees, and the main one, the first; none when the read failed or
listed none. -/
def listed : VersionControlM (Option (Array Worktree × Worktree)) := do
  match ← worktrees with
  | .ok all =>
    return all[0]?.map (all, ·)
  | .error _ =>
    return none

/-- The branches, or none when the read failed. -/
def branchesOf : VersionControlM (Option (Array String)) := do
  return (← branches).toOption

/-- Whether a reply is a refusal before anything ran (`Error.invalid`). -/
def invalidReply {α : Type} : Except Error α → Bool
  | .error (.invalid _) => true
  | _ => false

/-- The changed files of `revision` against `against`, or none when the
request was refused. -/
def changedFiles (revision against : String) : VersionControlM (Option (Array FileChange)) := do
  return ((← changes revision against).toOption).map (·.files)

/-- A repository on `main` whose `HEAD` holds `files` and has the parent `B`,
which holds `base`, with the branches `branches`, each a name and a commit
of `commits`. -/
def forked (base files : Array (String × String)) (commits : Array (String × Model.Commit))
    (branches : Array (String × String)) : Model.Repository :=
  { clean files with
    commits := #[("B", { files := base })] ++ commits, parents := #["B"], branches }

/-- The interface's properties of worktrees, branches and a branch's change
(phase 4). Paths are never written into a property: each takes the main
worktree's path from the `worktrees` reply and names the others beside it
(`beside`), so the same program holds of the model's root and of a
temporary directory. -/
def worktreeProperties : List Property :=
  [{  name :=
        "criterion 3: creating a worktree for a new branch and then removing it leaves the worktree list as it was, with the worktree on its branch in between"
      repository := clean #[("a.txt", "a\n")]
      holds := do
        let some (before, main) ← listed | return false
        let path := beside main.path "feature"
        let added ← addWorktree path "feature" (some "HEAD")
        let during ← worktrees
        let removed ← removeWorktree path
        let after ← worktrees
        let names ← branchesOf
        return succeeded added &&
            during == .ok (before ++ #[{ path, head := .branch "feature" }]) &&
            succeeded removed &&
            after == .ok before &&
            names == some #["feature", "main"] },
    { name := "a repository with no linked worktree lists its main worktree alone, on its branch"
      repository := clean #[("a.txt", "a\n")]
      holds := do
        let some (all, main) ← listed | return false
        return all.size == 1 && main.head == .branch "main" && main.path.isAbsolute },
    { name := "a detached main worktree is listed as detached"
      repository := { clean #[("a.txt", "a\n")] with head := .detached }
      holds := do
        let some (all, main) ← listed | return false
        return all.size == 1 && main.head == .detached },
    { name :=
        "linked worktrees are listed after the main one in path order, each with its branch, a detached one as detached"
      repository :=
        { clean #[("a.txt", "a\n")] with
          branches := #[("b", "head")]
          linked :=
            #[{ path := "/b-wt", branch := some "b" }, { path := "/a-wt", branch := none }] }
      holds := do
        let some (all, main) ← listed | return false
        return all ==
            #[main, { path := beside main.path "a-wt", head := .detached },
              { path := beside main.path "b-wt", head := .branch "b" }] },
    { name := "creating a worktree on an existing branch checks that branch out there"
      repository := { clean #[("a.txt", "a\n")] with branches := #[("b", "head")] }
      holds := do
        let some (before, main) ← listed | return false
        let path := beside main.path "b-wt"
        let added ← addWorktree path "b"
        return succeeded added &&
            (← worktrees) == .ok (before ++ #[{ path, head := .branch "b" }]) },
    { name :=
        "creating a worktree for a branch that exists, or at the main worktree's path, is refused, and the list and the branches are as they were"
      repository := { clean #[("a.txt", "a\n")] with branches := #[("b", "head")] }
      holds := do
        let some (before, main) ← listed | return false
        let names ← branchesOf
        let existing ← addWorktree (beside main.path "x") "b" (some "HEAD")
        let atRoot ← addWorktree main.path "z" (some "HEAD")
        return !succeeded existing && !succeeded atRoot && (← worktrees) == .ok before &&
            names.isSome &&
            (← branchesOf) == names },
    { name := "creating a worktree on a branch checked out elsewhere is refused"
      repository :=
        { clean #[("a.txt", "a\n")] with
          branches := #[("b", "head")], linked := #[{ path := "/b-wt", branch := some "b" }] }
      holds := do
        let some (before, main) ← listed | return false
        let onMain ← addWorktree (beside main.path "x") "main"
        let onB ← addWorktree (beside main.path "y") "b"
        return onMain matches .error (.failed (.code 128) _) &&
            onB matches .error (.failed (.code 128) _) &&
            (← worktrees) == .ok before },
    { name :=
        "creating a worktree from a start that is not there, or on a branch that is not there, is refused, and no branch is made"
      repository := clean #[("a.txt", "a\n")]
      holds := do
        let some (before, main) ← listed | return false
        let fromNothing ← addWorktree (beside main.path "x") "n" (some "nope")
        let onNothing ← addWorktree (beside main.path "y") "nope"
        return fromNothing matches .error (.failed (.code 128) _) &&
            onNothing matches .error (.failed (.code 128) _) &&
            (← worktrees) == .ok before &&
            (← branchesOf) == some #["main"] },
    { name :=
        "creating a worktree on a name that is a tag or a commit's id, and no branch, is refused with status 128, and the list and the branches are as they were"
      repository := { clean #[("a.txt", "a\n")] with revisions := #[("v1", #[("a.txt", "v\n")])] }
      holds := do
        let some (before, main) ← listed | return false
        let some head := ((← changes "HEAD" "HEAD").toOption).map (·.base) | return false
        let onTag ← addWorktree (beside main.path "x") "v1"
        let onId ← addWorktree (beside main.path "y") head
        return onTag matches .error (.failed (.code 128) _) &&
            onId matches .error (.failed (.code 128) _) &&
            (← worktrees) == .ok before &&
            (← branchesOf) == some #["main"] },
    { name :=
        "creating a worktree for a new branch at an existing worktree's path spelled with a trailing separator or through .., or in a directory that holds a file and is no worktree, is refused with status 128, and the list and the branches are as they were"
      repository :=
        { clean #[("a.txt", "a\n")] with
          branches := #[("b", "head")], linked := #[{ path := "/w", branch := some "b" }]
          occupied := #["/full"] }
      holds := do
        let some (before, main) ← listed | return false
        let names ← branchesOf
        let linked := beside main.path "w"
        let slashed ← addWorktree ⟨linked.toString ++ "/"⟩ "f1" (some "HEAD")
        let dotted ← addWorktree (linked / ".." / "w") "f2" (some "HEAD")
        let full ← addWorktree (beside main.path "full") "f3" (some "HEAD")
        return slashed matches .error (.failed (.code 128) _) &&
            dotted matches .error (.failed (.code 128) _) &&
            full matches .error (.failed (.code 128) _) &&
            (← worktrees) == .ok before &&
            names == some #["b", "main"] &&
            (← branchesOf) == names },
    { name :=
        "removing a worktree with an untracked file in it is refused with status 128, and it is still listed"
      repository :=
        { clean #[("a.txt", "a\n")] with
          linked := #[{ path := "/w", branch := none, dirty := true }] }
      holds := do
        let some (before, main) ← listed | return false
        let removed ← removeWorktree (beside main.path "w")
        return removed matches .error (.failed (.code 128) _) && (← worktrees) == .ok before },
    { name :=
        "removing the main worktree, or a path that is no worktree, is refused with status 128"
      repository := clean #[("a.txt", "a\n")]
      holds := do
        let some (before, main) ← listed | return false
        let removedMain ← removeWorktree main.path
        let removedNothing ← removeWorktree (beside main.path "nowhere")
        return removedMain matches .error (.failed (.code 128) _) &&
            removedNothing matches .error (.failed (.code 128) _) &&
            (← worktrees) == .ok before },
    { name :=
        "a name that starts with - is refused before anything runs, and a relative worktree path too"
      repository := { clean #[("a.txt", "a\n")] with branches := #[("b", "head")] }
      holds := do
        let some (before, main) ← listed | return false
        let path := beside main.path "x"
        let replies :=
          #[← changes "-x" "main", ← changes "main" "--all"].map invalidReply ++
            #[← addWorktree path "-b" (some "HEAD"), ← addWorktree path "n" (some "-x"),
                  ← addWorktree "relative" "n" (some "HEAD"), ← removeWorktree "relative"].map
              invalidReply
        return replies.all id && (← worktrees) == .ok before &&
            (← branchesOf) == some #["b", "main"] },
    { name :=
        "branches lists every local branch in byte order, and an unborn checked-out branch is not among them"
      repository :=
        { index := #[("a.txt", .file "a\n")], worktree := #[("a.txt", "a\n")]
          commits := #[("C", { files := #[("c.txt", "c\n")] })]
          branches := #[("b", "C"), ("a/x", "C")] }
      holds := return (← branchesOf) == some #["a/x", "b"] },
    { name :=
        "criterion 4 on the model's terms: a branch's change against main is each file changed since their merge base, with its old and new content, and main's later commits are not in it"
      repository :=
        forked #[("a", "1\n"), ("b", "b\n"), ("d", "d\n")]
          #[("a", "1\n"), ("b", "b\n"), ("d", "d\n"), ("m", "m\n")]
          #[("F", { parents := #["B"], files := #[("a", "2\n"), ("b", "b\n"), ("c", "new\n")] })]
          #[("feature", "F")]
      holds := do
        match ← changes "feature" "main" with
        | .error _ =>
          return false
        | .ok change =>
          return change.files ==
                #[{ path := "a", old := some "1\n", new := some "2\n" },
                  { path := "c", old := none, new := some "new\n" },
                  { path := "d", old := some "d\n", new := none }] &&
              (← fileAt change.base "a") == .ok (some "1\n") &&
              (← fileAt change.base "m") == .ok none },
    { name :=
        "a branch made from HEAD stays where it was when main commits after: its change against main is empty, and main's against it is the committed file"
      repository := writing (clean #[("a.txt", "one\n")]) "a.txt" "two\n"
      holds := do
        let some (_, main) ← listed | return false
        let added ← addWorktree (beside main.path "f") "f" (some "HEAD")
        let staged ← stage #["a.txt"]
        let committed ← commit "two\n"
        return succeeded added && succeeded staged && succeeded committed &&
            (← changedFiles "f" "main") == some #[] &&
            (← changedFiles "main" "f") ==
              some #[{ path := "a.txt", old := some "one\n", new := some "two\n" }] },
    { name :=
        "a file moved on a branch is its old path deleted and its new path added, and a copied file an addition, under a config that asks for copies"
      repository :=
        forked #[("a.txt", "moved\n"), ("k.txt", "kept\n")]
          #[("a.txt", "moved\n"), ("k.txt", "kept\n")]
          #[("M",
              { parents := #["B"]
                files := #[("b.txt", "moved\n"), ("c.txt", "kept\n"), ("k.txt", "kept\n")] })]
          #[("mv", "M")]
      holds := do
        return (← changedFiles "mv" "main") ==
            some
              #[{ path := "a.txt", old := some "moved\n", new := none },
                { path := "b.txt", old := none, new := some "moved\n" },
                { path := "c.txt", old := none, new := some "kept\n" }] },
    { name := "a change keeps a byte that is not UTF-8 as its escape, and a path with a space whole"
      repository :=
        forked #[("with space.txt", "a\n")] #[("with space.txt", "a\n")]
          #[("X",
              { parents := #["B"]
                files := #[("with space.txt", "a".push (Char.ofNat 0x10DC80) ++ "\n")] })]
          #[("x", "X")]
      holds := do
        return (← changedFiles "x" "main") ==
            some
              #[{ path := "with space.txt", old := some "a\n"
                  new := some ("a".push (Char.ofNat 0x10DC80) ++ "\n") }] },
    { name :=
        "a revision that is not there is refused with status 1 as not a commit, on either side, and two with no merge base with status 1 as such"
      repository := { clean #[("a.txt", "a\n")] with revisions := #[("v1", #[("o.txt", "o\n")])] }
      holds := do
        return (← changes "nope" "main") == .error (.failed (.code 1) "nope is not a commit") &&
            (← changes "main" "nope") == .error (.failed (.code 1) "nope is not a commit") &&
            (← changes "v1" "main") ==
              .error (.failed (.code 1) "v1 and main have no merge base") },
    { name := "fileAt of a branch is that branch's content, and of the checked-out branch HEAD's"
      repository :=
        { clean #[("a.txt", "a\n")] with
          commits := #[("F", { files := #[("a.txt", "b\n")] })], branches := #[("b", "F")] }
      holds := do
        return (← fileAt "b" "a.txt") == .ok (some "b\n") &&
            (← fileAt "main" "a.txt") == .ok (some "a\n") &&
            (← fileAt "HEAD" "a.txt") == .ok (some "a\n") }]

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
    { name :=
        "a file copied in the index from a file modified in the index is a staged addition beside the staged modification, never a copy"
      repository :=
        { committed := #[("a.txt", "a\n")]
          index := #[("a.txt", .file "a\nmore\n"), ("c.txt", .file "a\n")]
          worktree := #[("a.txt", "a\nmore\n"), ("c.txt", "a\n")] }
      holds := do
        return (← statusOf) ==
            some
              { head := .branch "main"
                files :=
                  #[{ path := "a.txt", state := .changed (some .modified) none },
                    { path := "c.txt", state := .changed (some .added) none }] } },
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
        return !succeeded staged && before.isSome && (← statusOf) == before },
    { name := "fileAt of HEAD and a committed file is its content"
      repository := writing (clean #[("a.txt", "one\n"), ("src/b.txt", "b\n")]) "a.txt" "two\n"
      holds := do
        return (← fileAt "HEAD" "a.txt") == .ok (some "one\n") &&
            (← fileAt "HEAD" "src/b.txt") == .ok (some "b\n") },
    { name := "fileAt of a path HEAD lacks, an untracked file's among them, is none"
      repository := writing (clean #[("a.txt", "a\n")]) "n.txt" "new\n"
      holds := do
        return (← fileAt "HEAD" "n.txt") == .ok none && (← fileAt "HEAD" "gone.txt") == .ok none },
    { name := "fileAt of a revision that is not there is none"
      repository := clean #[("a.txt", "a\n")]
      holds := return (← fileAt "nope" "a.txt") == .ok none },
    { name := "fileAt of a named revision is the content that revision has, not HEAD's"
      repository :=
        { clean #[("src/a.txt", "now\n")] with
          revisions := #[("v1", #[("src/a.txt", "then\n"), ("old.txt", "old\n")])] }
      holds := do
        return (← fileAt "v1" "src/a.txt") == .ok (some "then\n") &&
            (← fileAt "v1" "old.txt") == .ok (some "old\n") &&
            (← fileAt "HEAD" "old.txt") == .ok none },
    { name := "fileAt keeps a byte that is not UTF-8 as the store's escape of it"
      repository := clean #[("bin.txt", "a".push (Char.ofNat 0x10DC80) ++ "b\n")]
      holds :=
        return (← fileAt "HEAD" "bin.txt") == .ok (some ("a".push (Char.ofNat 0x10DC80) ++ "b\n")) },
    { name := "fileAt on an unborn branch is none"
      repository := { index := #[("a.txt", .file "a\n")], worktree := #[("a.txt", "a\n")] }
      holds := return (← fileAt "HEAD" "a.txt") == .ok none },
    { name :=
        "watched names a directory, and HEAD and the index under it, and its refs as a tree under it"
      repository := clean #[("a.txt", "a\n")]
      holds := do
        match ← watched with
        | .error _ =>
          return false
        | .ok answer =>
          let under (path : System.FilePath) :=
            path.toString.startsWith (answer.directory.toString ++ "/")
          return answer.directory.isAbsolute &&
              answer.paths.any (fun path => under path && path.fileName == some "HEAD") &&
              answer.paths.any (fun path => under path && path.fileName == some "index") &&
              answer.trees == #[answer.directory / "refs"] }] ++
    hunkProperties ++
    worktreeProperties

end Editor.VersionControlContract
