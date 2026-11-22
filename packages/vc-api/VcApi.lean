import Editor.Diff.Script
import Editor.Gutter.Track
import Editor.Job
import Editor.Program

/-!
# The interface library `vc-api`: the version-control interface

The interface package `vc-api` (`packages/vc-api/`), staged in the core's
Lake package until features-as-packages phase 6, when its last user in the
core moved out, and moved here with a `git mv` and a lakefile, no import
line in it changed. It imports only the core's API, and its test library
(`VcApiTest`) only that, this library and the core's test kit.

What the editor asks of a version-control system, in its own terms: which
files of a repository have changed and how, to stage or unstage files or
one hunk of a file, to commit what is staged, its worktrees and branches, a
branch's change against its base, to make and remove a worktree, and a
branch's history: its log, a file's blame, and two ranges of commits
compared.
It is a port like the others (`Editor/Program.lean`): requests, a reply
type for each, a pure model of a repository (`VcApiTest/Fake.lean`, the
interface's fake) and a contract every implementation is held to
(`VcApiTest/Contract.lean`). Git is one implementation (the
`version-control` package's `VersionControl/Git.lean`), which runs git as
jobs; jj would be
another handler of the same requests (`docs/design/version-control.md`).

An implementation runs inside a job: its handler answers each request in
`JobM` (`Handler`), and a program over this port runs against it with
`Program.runM`. The model answers each request as a pure function of a
repository (`Model.handle`), and `Program.run` runs the same program
against it.

## The rules

- **Paths** are relative to the repository's root, `/`-separated, as UTF-8
  strings. A path the system prints that is not UTF-8 makes a status
  `unparsable`.
- **A status** (`Status`) is what is checked out (`Head`) and every file
  that differs from it, sorted by path, then by state in the order of
  `FileState.rank`. A path appears once, with one exception: a path
  removed from the index and still on disk is a staged deletion and also
  untracked. The model does the same. A rename only in the working tree (a
  file added with intent to add after a move) is no state of its own: it is
  the origin's unstaged deletion and the new path's unstaged addition, the
  origin's staged change, if it has one, joined to the first.
- **`stage paths`** makes the index hold each path as the working tree has
  it: a path that is gone from the working tree is removed from the index,
  and a conflict is resolved to the working tree's content. A path in
  neither the index nor the working tree refuses the whole request, and
  nothing is staged.
- **`unstage paths`** makes the index hold each path as `HEAD` has it, or
  removes it from the index when `HEAD` lacks it, an unborn branch's
  included.
- **A hunk** (`LineHunk`) is one run of changed lines with the lines of
  the index around it: the change a hunk makes, with the context that
  locates it in the index. Each line keeps its line feed; only the last
  line of a text may lack one, which is how "no newline at end of file"
  is carried. Its context always comes from the index, the text the change
  is applied to: the old side when staging, the new side when unstaging.
- **`stageHunk path hunk`**: `hunk` is of the file against the index, and
  the index's lines `before ++ removed ++ after` at row `oldLine` become
  `before ++ added ++ after`. Lines that are not there refuse it, and the
  index is as it was.
- **`unstageHunk path hunk`**: `hunk` is of the index against `HEAD`, and
  its reverse is applied to the index: the index's lines `before ++ added
  ++ after` at row `newLine` become `before ++ removed ++ after`. Lines
  that are not there refuse it.
- **`commit message`** makes `HEAD` a new commit of the index whose message
  is `message`. A refusal (nothing staged, a conflict, a hook that says no)
  is `failed`, with everything the system printed.
- **`fileAt revision path`** is the content of `path` at `revision`, decoded
  by the store's escape rule (`File.decodeBytes`), so a byte that is not
  UTF-8 is kept as its escape: `none` when the revision does not have the
  path, which is so of a revision that is not there and of `HEAD` on an
  unborn branch. The empty revision is the index (git's `:<path>`). A path
  that names a directory is refused.
- **`watched`** is what to watch so as to see `HEAD` or the index move
  (`Watched`): one directory, the files in it whose change matters, and
  the trees in it under which any change matters (`Watched.matters`). It
  is neutral data: git names its common directory, with `HEAD` and the
  index of the checkout's own git directory, `packed-refs` and `refs`, and
  jj would name its operation heads.
- **`worktrees`** is every worktree of the repository (`Worktree`): the
  main one first, then the linked ones in path order, each its absolute
  path as the system spells it and what is checked out there. A bare main
  repository is no worktree and is not listed; a worktree whose directory
  is gone is still listed.
- **`branches`** is every local branch's name, in byte order; an unborn
  branch has no commit and is not one.
- **`changes revision against`** is committed content only (`Changes`):
  the merge base of `revision` and `against`, and every path whose content
  differs between that base and `revision`, sorted, each with its content
  on both sides, `none` where a side lacks it. A change is of content:
  renames are off, so a moved file is its old path deleted and its new
  path added, and a change of mode alone is not listed. Content is decoded
  by the store's escape rule, as `fileAt`'s is; a submodule's side reads
  `Subproject commit <id>` and a line feed, as git prints it. A name that
  is not a commit is refused with status 1, `<name> is not a commit`, and
  two with no merge base with status 1, `<revision> and <against> have no
  merge base`. The reply's `tip` is the id `revision` resolved to. An empty
  `against` is no base: every file of `revision` is added, and the reply's
  `base` is empty, which is a root commit's change.
- **`log revision limit`** is `revision` and its first parents, newest
  first, at most `limit` (`LogEntry`): each its id, its parents (the first
  first; none for a root) and who wrote it (`Authored`: the author's name,
  the author time in seconds and the subject, the message's first paragraph
  joined by spaces). A merge is one entry. A name that is not a commit, an
  unborn `HEAD` among them, is refused with status 1, `<name> is not a
  commit`, as `changes` refuses it.
- **`blame revision path`** is each line of `path` at `revision` with the
  commit that last changed it (`Blame`): a line is passed to the first
  parent, then each other parent in order, whose file has it unchanged, and
  stays with the commit that has no such parent. Each named commit is
  listed once, in the order of its first line, with who wrote it. A line
  has no line feed: git's porcelain cannot tell a last line without one.
  `none` when the revision lacks the path; a name that is not a commit is
  refused as `log` refuses it.
- **`rangeDiff base old new`** is the commits of `base..old` against those
  of `base..new` (`RangeDiff`), merges left out, oldest first, each pair
  (`RangePair`) naming each side's commit by its 1-based index in its range,
  or none, and how they stand: the same change (`=`), the same commit
  changed (`!`), or in one range alone (`<`, `>`), in the order git's
  `range-diff` prints them; and the text it printed. Each name that is not
  a commit is refused as `log` refuses it.
- **`addWorktree path branch start`** makes a worktree at `path`: with
  `start`, on a new branch `branch` made there; without it, on the
  existing local branch `branch`. A branch that exists (with `start`), a
  missing branch or one checked out in another worktree (without it), or a
  path that is a worktree, refuses it, and nothing changes.
- **`removeWorktree path`** removes the linked worktree at `path` and its
  directory, and keeps its branch. The main worktree, a path that is no
  worktree and one holding a modified or untracked file refuse it, and
  nothing changes.
- **A name that starts with `-`** (a revision, `against`, a branch, a
  start, a range's base and tips), which a system could read as an option, and a worktree path that
  is not absolute refuse the request before anything runs, as `invalid`
  (`Request.invalid?`). Every implementation calls it first.
- **Errors are values** (`Error`): a reply is an `Except`, and nothing is
  thrown. A command says `Error.describe` of a refusal.

## Where an addition goes

Each request comes with the phase that first uses it, with its tests and
both implementations behind it; none goes in ahead of them.

| Addition | Where |
|---|---|
| Another question of the repository or another write. A file at a revision (`fileAt`) and what to watch (`watched`) are here (phase 2), staging and unstaging a hunk (`stageHunk`, `unstageHunk`) and committing (`commit`) (phase 3), and the worktrees (`worktrees`), the branches (`branches`), a branch's change against its base (`changes`) and making and removing a worktree (`addWorktree`, `removeWorktree`) (phase 4), and a branch's log (`log`), a file's blame (`blame`) and two ranges compared (`rangeDiff`) (phase 5) | A constructor of `Request`, its case in `Request.Reply`, an operation here, a clause of `Model.handle`, a clause of `Git.handler`, and a property of the contract |
| Another way a file differs | A constructor of `FileState` (or of `Change` or `Conflict`), its case in the parser (`packages/version-control/VersionControl/Porcelain.lean`), in the model's status and printer, and in the status buffer's view (`packages/version-control/VersionControl/Status.lean`) |
| Another way a request fails | A constructor of `Error`, with its sentence in `Error.describe`; one refused before anything runs is a case of `Request.invalid?` |
| Another system (jj) | A handler of these requests, held to the contract; nothing here |

## Hunks

The port's own hunk helpers make a `LineHunk` of a hunk of the diff
service (`Diff.Hunk`, byte ranges of whole lines), so a consumer and the
model build one the same way:

- **The context** (`Hunk.context`) is 3 lines on each side, git's default,
  taken from the index, the text the change is applied to: the old side of
  a hunk of the file against the index (`HunkSide.stage`), the new side of a
  hunk of the index against `HEAD` (`HunkSide.unstage`). It is clamped at the
  index's start and end, so short context is only ever at an end, where
  git then holds the hunk.
- **A hunk is located** (`LineHunk.locate`) through a `Lines` of each
  text: the row of an offset, the offset of a row and a slice. The texts
  as strings (`Lines.ofText`, used by `LineHunk.ofTexts`) and as snapshots
  (`packages/version-control/VersionControl/Stage.lean`) are both one, so the one walk is
  pinned on strings.
- **Rows** are counted in line feeds, from 0: `oldLine` and `newLine` are
  the rows of the first context line, in the old and the new text.

## The backend point

`VcApi.Backend` is a **choice** by name (docs/design/extension-points.md,
"A hook, or a choice"): each value is a name and how to connect to a
repository (`connect`, given the git program of the workspace settings and
the repository's root), and a consumer connects through one of them, the
latest registered under the name `git` (`gitBackendName`, `VcApi.connect?`),
as `Extension.named` reads a choice. So config's backend named `git`,
registered after version control's, replaces it, and a backend of another
name is never used, however late it registers: which backend a workspace
uses is not configurable yet (a second backend needs a setting of its own,
docs/design/extension-points.md, "Open questions"). With no backend named
`git` it takes the case "no repository": working-set writes an empty
commit, and find-in-project lists no other worktree. Version control
registers `{ name := "git", connect := VersionControl.Git.handler }`. A
consumer that reads it from a job registers that job over the point
(`Extension.workJob`), which hands it every value; `connect?` makes the
choice among them.

## Names others reach

The three gutter jobs the core's reconciler starts (`VcApi.gutterJobs`,
the core's `Gutter.headJob`, `.diffJob` and `.refsJob`) and the mode line's
segment `review` (`VcApi.reviewSegmentName`), which the default order names.
Its registration check (`VcApiTest.registrationChecks`) holds an
implementation to them and to the backend `git`.

Pinned by the contract, which this package's test driver,
`vc-api-test`, runs against the model, and the `version-control` package's
linked test against the git implementation over the real process service,
in a temporary repository; and by `VcApiTest.vcApiChecks`.
-/

namespace Editor.VersionControl

/-- How the content of a file changed between two of its versions. A type
change (git's `T`) reads as modified. -/
inductive Change where
  /-- It is new. -/
  | added
  /-- Its content differs. -/
  | modified
  /-- It is gone. -/
  | deleted
  deriving DecidableEq, Repr

/-- How a file is in conflict, by which of the merge's three versions the
index holds: the base, ours and theirs. -/
inductive Conflict where
  /-- All three (`UU`). -/
  | bothModified
  /-- Ours and theirs, no base (`AA`). -/
  | bothAdded
  /-- The base alone (`DD`). -/
  | bothDeleted
  /-- Ours alone (`AU`). -/
  | addedByUs
  /-- Theirs alone (`UA`). -/
  | addedByThem
  /-- The base and theirs (`DU`). -/
  | deletedByUs
  /-- The base and ours (`UD`). -/
  | deletedByThem
  deriving DecidableEq, Repr

/-- How a file differs from what is checked out. -/
inductive FileState where
  /-- A change staged in the index against `HEAD`, and a change in the
  working tree against the index; at least one of them is there. -/
  | changed (staged : Option Change) (unstaged : Option Change)
  /-- Staged as renamed from `origin`, with a change in the working tree
  against the index. -/
  | renamed (origin : String) (unstaged : Option Change)
  /-- In the working tree and not in the index. -/
  | untracked
  /-- In conflict, `how`. -/
  | conflicted (how : Conflict)
  deriving DecidableEq, Repr

/-- Where a state sorts among the states of one path: a change, a rename, a
conflict, then untracked. -/
def FileState.rank : FileState → Nat
  | .changed .. => 0
  | .renamed .. => 1
  | .conflicted _ => 2
  | .untracked => 3

/-- A file that differs, and how. -/
structure FileStatus where
  /-- Its path, relative to the repository's root. -/
  path : String
  /-- How it differs. -/
  state : FileState
  deriving DecidableEq, Repr

/-- Whether `a` sorts before `b`: by path, then by the rank of the state. -/
def FileStatus.before (a b : FileStatus) : Bool :=
  decide (a.path < b.path) || (a.path == b.path && a.state.rank < b.state.rank)

/-- `files` sorted as a status holds them (`FileStatus.before`). -/
def sorted (files : Array FileStatus) : Array FileStatus :=
  files.qsort FileStatus.before

/-- What is checked out. -/
inductive Head where
  /-- The branch of this name, born or not. -/
  | branch (name : String)
  /-- No branch: `HEAD` is detached. -/
  | detached
  deriving DecidableEq, Repr

/-- What is checked out and every file that differs from it, sorted
(`sorted`). -/
structure Status where
  /-- What is checked out. -/
  head : Head
  /-- The files that differ. -/
  files : Array FileStatus := #[]
  deriving DecidableEq, Repr

/-- Why a request failed. -/
inductive Error where
  /-- The system could not be run: it is not there, it was not allowed, it
  ran past its time limit or wrote past its output limit. -/
  | couldNotRun (error : ProcessError)
  /-- It ran and refused, ending as `exit`, and said `message` on its
  standard error. -/
  | failed (exit : Process.Exit) (message : String)
  /-- What it printed could not be read: `detail` says why. -/
  | unparsable (detail : String)
  /-- The request was refused before anything ran (`Request.invalid?`):
  `detail` says why. -/
  | invalid (detail : String)
  deriving DecidableEq, Repr

/-- The first line of `text` that is not blank, trimmed; empty when there is
none. -/
def firstLine (text : String) : String :=
  (((text.splitOn "\n").map (·.trimAscii.toString)).find? (!·.isEmpty)).getD ""

/-- Why a request failed, as a clause for a person. -/
def Error.describe : Error → String
  | .couldNotRun error => s!"could not run: {error.describe}"
  | .failed (.code status) message =>
    match firstLine message with
    | "" => s!"exited with status {status}"
    | line => s!"exited with status {status}: {line}"
  | .failed (.signal signal) _ => s!"was ended by signal {signal}"
  | .unparsable detail => s!"printed what cannot be read: {detail}"
  | .invalid detail => s!"was not asked: {detail}"

/-- Two status replies are equal when they are the same case with equal
contents. `Except` derives no equality. -/
instance : DecidableEq (Except Error Status)
  | .ok a, .ok b =>
    if h : a = b then isTrue (congrArg Except.ok h) else isFalse fun e => h (Except.ok.inj e)
  | .error a, .error b =>
    if h : a = b then isTrue (congrArg Except.error h) else isFalse fun e => h (Except.error.inj e)
  | .ok _, .error _ => isFalse fun e => by cases e
  | .error _, .ok _ => isFalse fun e => by cases e

/-- Two replies of a write are equal when they are the same case with equal
contents. -/
instance : DecidableEq (Except Error Unit)
  | .ok a, .ok b =>
    isTrue
      (by
        cases a; cases b; rfl)
  | .error a, .error b =>
    if h : a = b then isTrue (congrArg Except.error h) else isFalse fun e => h (Except.error.inj e)
  | .ok _, .error _ => isFalse fun e => by cases e
  | .error _, .ok _ => isFalse fun e => by cases e

/-- What to watch so as to see `HEAD` or the index move: a directory to watch
whole, the files in it whose change matters, and the trees in it under which
any change matters. -/
structure Watched where
  /-- The directory to watch, with everything under it. -/
  directory : System.FilePath
  /-- The files whose change matters. -/
  paths : Array System.FilePath
  /-- The directories under which a change of any file matters. -/
  trees : Array System.FilePath
  deriving DecidableEq, Repr

/-- Whether `change`, a change a watch of `watched.directory` delivered,
matters: one at one of its paths or under one of its trees, but never at a
lock file (`*.lock`), which a system writes and renames away while it moves
`HEAD` or the index; and changes that were missed, which may have been
any. -/
def Watched.matters (watched : Watched) (change : FileWatch.Change) : Bool :=
  let path := change.path.toString
  change.kinds.missed ||
    !path.endsWith ".lock" &&
      (watched.paths.any (·.toString == path) ||
        watched.trees.any fun tree => path.startsWith (tree.toString ++ "/"))

/-- Two replies of `fileAt` are equal when they are the same case with equal
contents. -/
instance : DecidableEq (Except Error (Option String))
  | .ok a, .ok b =>
    if h : a = b then isTrue (congrArg Except.ok h) else isFalse fun e => h (Except.ok.inj e)
  | .error a, .error b =>
    if h : a = b then isTrue (congrArg Except.error h) else isFalse fun e => h (Except.error.inj e)
  | .ok _, .error _ => isFalse fun e => by cases e
  | .error _, .ok _ => isFalse fun e => by cases e

/-- Two replies of `watched` are equal when they are the same case with equal
contents. -/
instance : DecidableEq (Except Error Watched)
  | .ok a, .ok b =>
    if h : a = b then isTrue (congrArg Except.ok h) else isFalse fun e => h (Except.ok.inj e)
  | .error a, .error b =>
    if h : a = b then isTrue (congrArg Except.error h) else isFalse fun e => h (Except.error.inj e)
  | .ok _, .error _ => isFalse fun e => by cases e
  | .error _, .ok _ => isFalse fun e => by cases e

/-- The lines of `text`, each with its line feed; the last may lack one. The
empty text has none. -/
def linesOf (text : String) : Array String :=
  let parts := text.splitOn "\n"
  let ended := (parts.dropLast.map (· ++ "\n")).toArray
  match parts.getLast? with
  | some "" | none => ended
  | some last => ended.push last

/-- One run of changed lines and the lines of the index around it: the change
a hunk makes, with the context that locates it in the index ("The rules", in
the module docs). -/
structure LineHunk where
  /-- The row, from 0, in the old text, of the first line of `before`. -/
  oldLine : Nat
  /-- The row, from 0, in the new text, of the first line of `before`. -/
  newLine : Nat
  /-- The context before the change: the index's lines before it. -/
  before : Array String
  /-- The old text's lines the change replaces. -/
  removed : Array String
  /-- The new text's lines that replace them. -/
  added : Array String
  /-- The context after the change: the index's lines after it. -/
  after : Array String
  deriving DecidableEq, Repr

/-- A checkout of the repository: where its files are, and what is checked
out there. -/
structure Worktree where
  /-- Its directory, absolute, as the system spells it. -/
  path : System.FilePath
  /-- What is checked out there. -/
  head : Head
  deriving DecidableEq, Repr

/-- A file whose content differs between two revisions: its content on each
side, `none` where that side lacks it. -/
structure FileChange where
  /-- Its path, relative to the repository's root. -/
  path : String
  /-- Its content on the old side, the merge base's. -/
  old : Option String
  /-- Its content on the new side, the revision's. -/
  new : Option String
  deriving DecidableEq, Repr

/-- The change of a revision against its merge base with a named branch. -/
structure Changes where
  /-- The merge base's id, which `fileAt` reads at; empty for a change
  against no base. -/
  base : String
  /-- The id the revision resolved to. -/
  tip : String
  /-- Every file whose content differs, sorted by path. -/
  files : Array FileChange := #[]
  deriving DecidableEq, Repr

/-- Who wrote a commit, when, and what it says of itself. -/
structure Authored where
  /-- The author's name. -/
  author : String
  /-- The author's time, in seconds since the epoch. -/
  time : Nat
  /-- The subject: the first paragraph of the message, its lines joined by a
  space. -/
  subject : String
  deriving DecidableEq, Repr

/-- One commit of a log: its id, its parents and who wrote it. -/
structure LogEntry where
  /-- Its id. -/
  id : String
  /-- Its parents' ids, the first parent first. -/
  parents : Array String := #[]
  /-- Who wrote it, when, and its subject. -/
  authored : Authored
  deriving DecidableEq, Repr

/-- One line of a blamed file: the commit that last changed it, and its
text. -/
structure BlameLine where
  /-- The id of the commit that last changed the line. -/
  id : String
  /-- The line, without its line feed. -/
  text : String
  deriving DecidableEq, Repr

/-- A file's lines, each with the commit that last changed it. -/
structure Blame where
  /-- Each commit a line names, once, in the order of its first line, with
  who wrote it. -/
  commits : Array (String × Authored) := #[]
  /-- The lines, in order. -/
  lines : Array BlameLine := #[]
  deriving DecidableEq, Repr

/-- How a commit of one range stands to one of another, as `git range-diff`
says it. -/
inductive RangeRelation where
  /-- The same change (`=`). -/
  | same
  /-- The same commit, changed (`!`). -/
  | changed
  /-- In the old range alone (`<`). -/
  | removed
  /-- In the new range alone (`>`). -/
  | added
  deriving DecidableEq, Repr

/-- One line of a range-diff: the commit of each range it names, by its
1-based index in that range, and how they stand. -/
structure RangePair where
  /-- The old range's commit, if one. -/
  old : Option Nat
  /-- The new range's commit, if one. -/
  new : Option Nat
  /-- How they stand. -/
  relation : RangeRelation
  deriving DecidableEq, Repr

/-- Two ranges of commits compared: the pairs, in the order printed, and the
text printed. -/
structure RangeDiff where
  /-- The pairs, in the order printed. -/
  pairs : Array RangePair := #[]
  /-- What was printed, the diff of each changed pair's diffs among it. -/
  text : String := ""
  deriving DecidableEq, Repr

/-- What may be asked of a repository. -/
inductive Request where
  /-- What is checked out, and every file that differs from it. -/
  | status
  /-- Make the index hold each of `paths` as the working tree has it. -/
  | stage (paths : Array String)
  /-- Make the index hold each of `paths` as `HEAD` has it. -/
  | unstage (paths : Array String)
  /-- The content of `path` at `revision`, if the revision has it. -/
  | fileAt (revision path : String)
  /-- What to watch so as to see `HEAD` or the index move. -/
  | watched
  /-- Apply `hunk`, a hunk of `path` against the index, to the index. -/
  | stageHunk (path : String) (hunk : LineHunk)
  /-- Apply the reverse of `hunk`, a hunk of `path`'s index against `HEAD`,
  to the index. -/
  | unstageHunk (path : String) (hunk : LineHunk)
  /-- Make `HEAD` a new commit of the index, with `message`. -/
  | commit (message : String)
  /-- Every worktree of the repository. -/
  | worktrees
  /-- Every local branch's name. -/
  | branches
  /-- The change of `revision` against its merge base with `against`. -/
  | changes (revision against : String)
  /-- A new worktree at `path` on `branch`: a new branch made at `start`, or
  the existing branch when there is no `start`. -/
  | addWorktree (path : System.FilePath) (branch : String) (start : Option String)
  /-- The linked worktree at `path` gone, its branch kept. -/
  | removeWorktree (path : System.FilePath)
  /-- `revision` and its first parents, newest first, at most `limit`. -/
  | log (revision : String) (limit : Nat)
  /-- Each line of `path` at `revision`, with the commit that last changed
  it. -/
  | blame (revision path : String)
  /-- The commits of `base..old` against those of `base..new`. -/
  | rangeDiff (base old new : String)
  deriving DecidableEq, Repr

/-- Why `request` is refused before anything runs, if it is ("The rules", in
the module docs): a name that starts with `-`, which a system could read as
an option, or a worktree path that is not absolute. Every implementation
calls it first, so none can disagree. -/
def Request.invalid? : Request → Option String
  | .changes revision against => dashed #[revision, against]
  | .log revision _ => dashed #[revision]
  | .blame revision _ => dashed #[revision]
  | .rangeDiff base old new => dashed #[base, old, new]
  | .addWorktree path branch start => relative path <|> dashed (#[branch] ++ start.toArray)
  | .removeWorktree path => relative path
  | _ => none
where
  /-- The first of `names` that starts with `-`, said. -/
  dashed (names : Array String) : Option String :=
    (names.find? (·.startsWith "-")).map fun name => s!"{name} starts with -"
  /-- `path`, said, when it is not absolute. -/
  relative (path : System.FilePath) : Option String :=
    if path.isAbsolute then none else some s!"{path} is not absolute"

/-- Two replies of `worktrees` are equal when they are the same case with
equal contents. -/
instance : DecidableEq (Except Error (Array Worktree))
  | .ok a, .ok b =>
    if h : a = b then isTrue (congrArg Except.ok h) else isFalse fun e => h (Except.ok.inj e)
  | .error a, .error b =>
    if h : a = b then isTrue (congrArg Except.error h) else isFalse fun e => h (Except.error.inj e)
  | .ok _, .error _ => isFalse fun e => by cases e
  | .error _, .ok _ => isFalse fun e => by cases e

/-- Two replies of `branches` are equal when they are the same case with
equal contents. -/
instance : DecidableEq (Except Error (Array String))
  | .ok a, .ok b =>
    if h : a = b then isTrue (congrArg Except.ok h) else isFalse fun e => h (Except.ok.inj e)
  | .error a, .error b =>
    if h : a = b then isTrue (congrArg Except.error h) else isFalse fun e => h (Except.error.inj e)
  | .ok _, .error _ => isFalse fun e => by cases e
  | .error _, .ok _ => isFalse fun e => by cases e

/-- Two replies of `changes` are equal when they are the same case with equal
contents. -/
instance : DecidableEq (Except Error Changes)
  | .ok a, .ok b =>
    if h : a = b then isTrue (congrArg Except.ok h) else isFalse fun e => h (Except.ok.inj e)
  | .error a, .error b =>
    if h : a = b then isTrue (congrArg Except.error h) else isFalse fun e => h (Except.error.inj e)
  | .ok _, .error _ => isFalse fun e => by cases e
  | .error _, .ok _ => isFalse fun e => by cases e

/-- Two replies of `log` are equal when they are the same case with equal
contents. -/
instance : DecidableEq (Except Error (Array LogEntry))
  | .ok a, .ok b =>
    if h : a = b then isTrue (congrArg Except.ok h) else isFalse fun e => h (Except.ok.inj e)
  | .error a, .error b =>
    if h : a = b then isTrue (congrArg Except.error h) else isFalse fun e => h (Except.error.inj e)
  | .ok _, .error _ => isFalse fun e => by cases e
  | .error _, .ok _ => isFalse fun e => by cases e

/-- Two replies of `blame` are equal when they are the same case with equal
contents. -/
instance : DecidableEq (Except Error (Option Blame))
  | .ok a, .ok b =>
    if h : a = b then isTrue (congrArg Except.ok h) else isFalse fun e => h (Except.ok.inj e)
  | .error a, .error b =>
    if h : a = b then isTrue (congrArg Except.error h) else isFalse fun e => h (Except.error.inj e)
  | .ok _, .error _ => isFalse fun e => by cases e
  | .error _, .ok _ => isFalse fun e => by cases e

/-- Two replies of `rangeDiff` are equal when they are the same case with
equal contents. -/
instance : DecidableEq (Except Error RangeDiff)
  | .ok a, .ok b =>
    if h : a = b then isTrue (congrArg Except.ok h) else isFalse fun e => h (Except.ok.inj e)
  | .error a, .error b =>
    if h : a = b then isTrue (congrArg Except.error h) else isFalse fun e => h (Except.error.inj e)
  | .ok _, .error _ => isFalse fun e => by cases e
  | .error _, .ok _ => isFalse fun e => by cases e

/-- The type of the reply to each request: the status, nothing for a write,
a file's content or none, what to watch, the worktree list, the branch
names, a branch's change against its base (`Changes`), a log, a blame or
none, or a range-diff; each refused with an `Error`. -/
def Request.Reply : Request → Type
  | .status => Except Error Status
  | .stage _ => Except Error Unit
  | .unstage _ => Except Error Unit
  | .fileAt .. => Except Error (Option String)
  | .watched => Except Error Watched
  | .stageHunk .. => Except Error Unit
  | .unstageHunk .. => Except Error Unit
  | .commit _ => Except Error Unit
  | .worktrees => Except Error (Array Worktree)
  | .branches => Except Error (Array String)
  | .changes .. => Except Error Changes
  | .addWorktree .. => Except Error Unit
  | .removeWorktree _ => Except Error Unit
  | .log .. => Except Error (Array LogEntry)
  | .blame .. => Except Error (Option Blame)
  | .rangeDiff .. => Except Error RangeDiff

/-- The version-control port: `Request` and the reply to each request. -/
abbrev port : Port :=
  { Request := Request, Reply := Request.Reply }

/-- A program over the version-control port. It has no error of its own: a
request that fails is answered so, as a value. -/
abbrev VersionControlM :=
  Program port

/-- An implementation: an answerer of the port's requests inside a job. -/
abbrev Handler :=
  (request : Request) → JobM request.Reply

/-- What is checked out and every file that differs from it. -/
def status : VersionControlM (Except Error Status) :=
  Program.request (port := port) .status

/-- Makes the index hold each of `paths` as the working tree has it. -/
def stage (paths : Array String) : VersionControlM (Except Error Unit) :=
  Program.request (port := port) (.stage paths)

/-- Makes the index hold each of `paths` as `HEAD` has it. -/
def unstage (paths : Array String) : VersionControlM (Except Error Unit) :=
  Program.request (port := port) (.unstage paths)

/-- The content of `path` at `revision`: `none` when the revision does not
have it, or is not there. -/
def fileAt (revision path : String) : VersionControlM (Except Error (Option String)) :=
  Program.request (port := port) (.fileAt revision path)

/-- What to watch so as to see `HEAD` or the index move. -/
def watched : VersionControlM (Except Error Watched) :=
  Program.request (port := port) .watched

/-- Applies `hunk`, a hunk of `path` against the index, to the index. -/
def stageHunk (path : String) (hunk : LineHunk) : VersionControlM (Except Error Unit) :=
  Program.request (port := port) (.stageHunk path hunk)

/-- Applies the reverse of `hunk`, a hunk of `path`'s index against `HEAD`, to
the index. -/
def unstageHunk (path : String) (hunk : LineHunk) : VersionControlM (Except Error Unit) :=
  Program.request (port := port) (.unstageHunk path hunk)

/-- Makes `HEAD` a new commit of the index, with `message`. -/
def commit (message : String) : VersionControlM (Except Error Unit) :=
  Program.request (port := port) (.commit message)

/-- Every worktree of the repository: the main one first, then the linked
ones in path order. -/
def worktrees : VersionControlM (Except Error (Array Worktree)) :=
  Program.request (port := port) .worktrees

/-- Every local branch's name, in byte order. -/
def branches : VersionControlM (Except Error (Array String)) :=
  Program.request (port := port) .branches

/-- The change of `revision` against its merge base with `against`. -/
def changes (revision against : String) : VersionControlM (Except Error Changes) :=
  Program.request (port := port) (.changes revision against)

/-- Makes a worktree at `path` on `branch`: a new branch made at `start`, or
the existing branch when there is no `start`. -/
def addWorktree (path : System.FilePath) (branch : String) (start : Option String := none) :
    VersionControlM (Except Error Unit) :=
  Program.request (port := port) (.addWorktree path branch start)

/-- Removes the linked worktree at `path`, keeping its branch. -/
def removeWorktree (path : System.FilePath) : VersionControlM (Except Error Unit) :=
  Program.request (port := port) (.removeWorktree path)

/-- `revision` and its first parents, newest first, at most `limit`. -/
def log (revision : String) (limit : Nat) : VersionControlM (Except Error (Array LogEntry)) :=
  Program.request (port := port) (.log revision limit)

/-- Each line of `path` at `revision` with the commit that last changed it;
`none` when the revision does not have the path. -/
def blame (revision path : String) : VersionControlM (Except Error (Option Blame)) :=
  Program.request (port := port) (.blame revision path)

/-- The commits of `base..old` against those of `base..new`, paired as
`git range-diff` pairs them. -/
def rangeDiff (base old new : String) : VersionControlM (Except Error RangeDiff) :=
  Program.request (port := port) (.rangeDiff base old new)

/-! ## Hunks -/

/-- How many lines of context a hunk carries on each side: 3, git's
default. -/
def Hunk.context : Nat :=
  3

/-- Which way a hunk goes, which says which of its texts is the index: the
old one of a hunk of the file against the index, the new one of a hunk of
the index against `HEAD`. -/
inductive HunkSide where
  /-- A hunk of the file against the index, to stage. -/
  | stage
  /-- A hunk of the index against `HEAD`, to unstage. -/
  | unstage
  deriving DecidableEq, Repr

/-- What locating a hunk asks of a text, in a monad `m`. -/
structure Lines (m : Type → Type) where
  /-- Its length in bytes. -/
  size : Nat
  /-- How many rows it has: one more than its line feeds. -/
  rows : Nat
  /-- The row, from 0, of a byte offset. -/
  rowOf : Nat → m Nat
  /-- The byte offset where a row starts, for a row it has. -/
  rowStart : Nat → m Nat
  /-- Its bytes from a start up to, not including, a stop. -/
  slice : Nat → Nat → m String

/-- Where `row` starts in `lines`, or its end for a row past its last. -/
def Lines.startOf {m : Type → Type} [Monad m] (lines : Lines m) (row : Nat) : m Nat :=
  if row < lines.rows then lines.rowStart row else pure lines.size

/-- `text` as a `Lines`. -/
def Lines.ofText (text : String) : Lines Id :=
  let bytes := text.toUTF8
  let starts :=
    (List.range bytes.size).foldl
      (fun (starts : Array Nat) offset =>
        if bytes.get! offset == 10 then starts.push (offset + 1) else starts)
      #[0]
  { size := bytes.size, rows := starts.size
    rowOf := fun offset => (starts.filter (· ≤ offset)).size - 1
    rowStart := fun row => starts[row]?.getD bytes.size
    slice := fun start stop => (String.fromUTF8? (bytes.extract start stop)).getD "" }

/-- The hunk of the lines `before`, `removed`, `added` and `after`, each text
split at its line feeds, which are kept (`linesOf`). -/
def LineHunk.make (oldLine newLine : Nat) (before removed added after : String) : LineHunk :=
  { oldLine, newLine, before := linesOf before, removed := linesOf removed
    added := linesOf added, after := linesOf after }

/-- The `LineHunk` of `hunk`, a hunk of `old` against `new` going `side`, its
context taken from the index's text ("The context", in the module docs). -/
def LineHunk.locate {m : Type → Type} [Monad m] (side : HunkSide) (old new : Lines m)
    (hunk : Diff.Hunk) : m LineHunk := do
  let (index, start, stop) :=
    match side with
    | .stage => (old, hunk.oldStart, hunk.oldStop)
    | .unstage => (new, hunk.newStart, hunk.newStop)
  let startRow ← index.rowOf start
  let stopRow ← index.rowOf stop
  let first := startRow - min Hunk.context startRow
  let beforeStart ← index.startOf first
  let afterStop ←
    if stop == index.size then
      pure index.size
    else
      index.startOf (stopRow + Hunk.context)
  let before ← index.slice beforeStart start
  let after ← index.slice stop afterStop
  let count := startRow - first
  let oldRow ← old.rowOf hunk.oldStart
  let newRow ← new.rowOf hunk.newStart
  return LineHunk.make (oldRow - count) (newRow - count) before
      (← old.slice hunk.oldStart hunk.oldStop) (← new.slice hunk.newStart hunk.newStop) after

/-- The `LineHunk` of `hunk`, a hunk of the text `old` against `new` going
`side` (`LineHunk.locate`). -/
def LineHunk.ofTexts (side : HunkSide) (old new : String) (hunk : Diff.Hunk) : LineHunk :=
  LineHunk.locate side (Lines.ofText old) (Lines.ofText new) hunk

end Editor.VersionControl

namespace VcApi

open Editor

/-- A version-control backend: its name, and how to connect to the
repository at a root with a program (the workspace settings' `git`), the
handler that answers the port's requests inside a job ("The backend
point", in the module docs). A choice, by the name `gitBackendName`. -/
structure Backend where
  /-- The backend's name. -/
  name : String
  /-- The handler of the repository at the root, run with the program. -/
  connect : String → System.FilePath → VersionControl.Handler
  deriving TypeName

/-- The name of the backend version control registers, and the name the
choice at `Backend` is made by. -/
def gitBackendName : String :=
  "git"

/-- How a consumer connects, given every value registered at `Backend`
(registration order): through the latest one named `gitBackendName`, so
config's `git`, registered after a package's, is the one used, and a backend
of another name is not; `none` with no backend of that name, the case "no
repository". -/
def connect? (backends : Array Backend) :
    Option (String → System.FilePath → VersionControl.Handler) :=
  (backends.findRev? (·.name == gitBackendName)).map (·.connect)

/-- The names of the gutter's three jobs, which the core's reconciler starts
and version control registers: the core's. -/
def gutterJobs : Array String :=
  #[Gutter.headJob, Gutter.diffJob, Gutter.refsJob]

/-- The name of the mode line's segment of a review's counts, which the mode
line's default order names and version control registers. -/
def reviewSegmentName : String :=
  "review"

end VcApi
