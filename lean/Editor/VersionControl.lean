import Editor.Job
import Editor.Program

/-!
# The version-control interface

What the editor asks of a version-control system, in its own terms: which
files of a repository have changed and how, and to stage or unstage files.
It is a port like the others (`Editor/Program.lean`): requests, a reply
type for each, a pure model of a repository
(`Editor/VersionControl/Model.lean`) and a contract every implementation is
held to (`Editor/VersionControl/Contract.lean`). Git is one implementation
(`Editor/VersionControl/Git.lean`), which runs git as jobs; jj would be
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
- **Errors are values** (`Error`): a reply is an `Except`, and nothing is
  thrown. A command says `Error.describe` of a refusal.

## Where an addition goes

Each request comes with the phase that first uses it, with its tests and
both implementations behind it; none goes in ahead of them.

| Addition | Where |
|---|---|
| Another question of the repository: the branches and the worktrees, and a diff between two revisions (phase 4). A file at a revision (`fileAt`) and what to watch (`watched`) are here (phase 2) | A constructor of `Request`, its case in `Request.Reply`, an operation here, a clause of `Model.handle`, a clause of `Git.handler`, and a property of the contract |
| Another way a file differs | A constructor of `FileState` (or of `Change` or `Conflict`), its case in the parser (`Editor/VersionControl/Porcelain.lean`), in the model's status and printer, and in the status buffer's view (`Editor/VersionControl/Status.lean`) |
| Another way a request fails | A constructor of `Error`, with its sentence in `Error.describe` |
| Another system (jj) | A handler of these requests, held to the contract; nothing here |

Pinned by the contract, which `model-test` runs against the model and
against the git implementation on the job model, and `contract-test`
against the git implementation over the real process service, in a
temporary repository.
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
  deriving DecidableEq, Repr

/-- The type of the reply to each request: the status, nothing for a write,
a file's content or none, or what to watch; each refused with an `Error`. -/
def Request.Reply : Request → Type
  | .status => Except Error Status
  | .stage _ => Except Error Unit
  | .unstage _ => Except Error Unit
  | .fileAt .. => Except Error (Option String)
  | .watched => Except Error Watched

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

end Editor.VersionControl
