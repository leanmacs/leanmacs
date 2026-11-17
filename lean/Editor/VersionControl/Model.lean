import Editor.Job.Model
import Editor.VersionControl
import Editor.VersionControl.Git

/-!
# The pure model of a repository

A repository as a value: what is checked out, `HEAD`'s files, the index and
the working tree, each a path and its content. `Repository.status` answers
a status as a pure function, `Model.handle` answers each request of the
version-control port (`Editor/VersionControl.lean`), and
`Repository.porcelain` prints the status as git prints it with the git
implementation's flags, so the real parser reads the model's status
(`Editor/VersionControl/Porcelain.lean`). `Repository.jobModel` is the job
model (`JobModel`, `Editor/Job/Model.lean`) whose process scripts answer
the git implementation's command lines in a repository, so the git
implementation runs on the models too.

## How it answers

- **A path** is any path of `HEAD`, the index or the working tree, taken in
  byte order.
- **A conflict entry** of the index is `conflicted`, of the kind its three
  versions name: base, ours and theirs (`Conflict.of`).
- **Otherwise** the staged change is `HEAD` against the index, and the
  unstaged change is the index against the working tree: missing on one
  side and present on the other is added or deleted, present on both and
  different is modified. A path in neither the index nor `HEAD` has no
  staged change; a path the index lacks has no unstaged change.
- **A path in the working tree and not in the index** is untracked, and so
  is a staged deletion still on disk, which is then both.
- **Renames.** A path added in the index whose content is `HEAD`'s content
  of a path deleted in the index becomes one `renamed` entry, as git's
  exact rename detection does: the added paths in path order, each taking
  the first deleted path, in path order, not taken yet. An empty file is
  paired too, as git pairs it. The renamed entry's unstaged change is the
  new path's.
- **`stage paths`**: each path's working-tree content goes into the index,
  or the path is removed from the index when the working tree lacks it. A
  path in neither the index nor the working tree refuses the whole
  request, as git does, with status 128 and nothing staged.
- **`unstage paths`**: each path's `HEAD` content goes into the index, or
  the path is removed from the index when `HEAD` lacks it.

The contract (`Editor/VersionControl/Contract.lean`) is what says the model
and the git implementation agree.
-/

namespace Editor.VersionControl.Model

/-- An entry of the index. -/
inductive Entry where
  /-- A file, merged, holding `content`. -/
  | file (content : String)
  /-- A conflict: the merge's base, ours and theirs, each where the index
  holds it. -/
  | conflict (base ours theirs : Option String)
  deriving DecidableEq, Repr

/-- A repository, as a value. -/
structure Repository where
  /-- What is checked out: a branch is unborn while `committed` is empty. -/
  head : Head := .branch "main"
  /-- `HEAD`'s files, each a path and its content; none on an unborn
  branch. -/
  committed : Array (String × String) := #[]
  /-- The index. -/
  index : Array (String × Entry) := #[]
  /-- The working tree's files. -/
  worktree : Array (String × String) := #[]
  deriving DecidableEq, Repr

/-- The value `entries` holds for `path`. -/
def lookup {α : Type} (entries : Array (String × α)) (path : String) : Option α :=
  (entries.find? (·.1 == path)).map (·.2)

/-- `entries` with `path` holding `value`, in place of what it held. -/
def setting {α : Type} (entries : Array (String × α)) (path : String) (value : α) :
    Array (String × α) :=
  (entries.filter (·.1 != path)).push (path, value)

/-- `entries` without `path`. -/
def without {α : Type} (entries : Array (String × α)) (path : String) : Array (String × α) :=
  entries.filter (·.1 != path)

/-- The kind of conflict whose base, ours and theirs are each there or
not. -/
def conflictOf (base ours theirs : Option String) : Conflict :=
  match base.isSome, ours.isSome, theirs.isSome with
  | true, true, true => .bothModified
  | false, true, true => .bothAdded
  | true, false, false => .bothDeleted
  | false, true, false => .addedByUs
  | false, false, true => .addedByThem
  | true, false, true => .deletedByUs
  | true, true, false => .deletedByThem
  | false, false, false => .bothDeleted

/-- How a file went from `old` to `new`, each its content where it is
there. -/
def changeOf (old new : Option String) : Option Change :=
  match old, new with
  | none, none => none
  | none, some _ => some .added
  | some _, none => some .deleted
  | some old, some new => if old == new then none else some .modified

namespace Repository

/-- Every path of `HEAD`, the index and the working tree, once, in byte
order. -/
def paths (repository : Repository) : Array String :=
  let all :=
    repository.committed.map (·.1) ++ repository.index.map (·.1) ++ repository.worktree.map (·.1)
  (all.qsort fun a b => decide (a < b)).foldl
    (fun (kept : Array String) path => if kept.back? == some path then kept else kept.push path) #[]

/-- The content the index holds for `path`, when it holds a merged file. -/
def indexed? (repository : Repository) (path : String) : Option String :=
  match lookup repository.index path with
  | some (.file content) => some content
  | _ => none

/-- The states of `path` before renames are paired: its change or conflict,
then untracked. -/
def statesOf (repository : Repository) (path : String) : Array FileStatus :=
  let tracked : Array FileStatus :=
    match lookup repository.index path with
    | some (.conflict base ours theirs) =>
      #[{ path, state := .conflicted (conflictOf base ours theirs) }]
    | some (.file content) =>
      let staged := changeOf (lookup repository.committed path) (some content)
      let unstaged := changeOf (some content) (lookup repository.worktree path)
      if staged.isSome || unstaged.isSome then #[{ path, state := .changed staged unstaged }]
      else #[]
    | none =>
      if (lookup repository.committed path).isSome then
        #[{ path, state := .changed (some .deleted) none }]
      else #[]
  let untracked : Array FileStatus :=
    if (lookup repository.index path).isNone && (lookup repository.worktree path).isSome then
      #[{ path, state := .untracked }]
    else #[]
  tracked ++ untracked

/-- `files`, in path order, with renames paired ("Renames", in the module
docs): each pair is one `renamed` entry at the new path, and the origin's
staged deletion is dropped. -/
def paired (repository : Repository) (files : Array FileStatus) : Array FileStatus :=
  let deleted := (files.filter (·.state == .changed (some .deleted) none)).map (·.path)
  let added := (files.filter fun file => file.state matches .changed (some .added) _).map (·.path)
  let pairs :=
    added.foldl
      (fun (pairs : Array (String × String)) path =>
        match repository.indexed? path with
        | some content =>
          match
            deleted.find? fun origin =>
              !pairs.any (·.2 == origin) && lookup repository.committed origin == some content with
          | some origin => pairs.push (path, origin)
          | none => pairs
        | none => pairs)
      #[]
  files.filterMap fun file =>
    if file.state == .changed (some .deleted) none && pairs.any (·.2 == file.path) then none
    else
      match pairs.find? (·.1 == file.path), file.state with
      | some (_, origin), .changed (some .added) unstaged =>
        some { file with state := .renamed origin unstaged }
      | _, _ => some file

/-- The status of `repository` ("How it answers", in the module docs). -/
def status (repository : Repository) : Status :=
  { head := repository.head
    files := sorted (repository.paired (repository.paths.flatMap repository.statesOf)) }

/-- An object name of none of git's objects, which the printer prints in
every place git prints one. -/
def zeros : String :=
  "0000000000000000000000000000000000000000"

/-- The letter git prints for a change, `.` for none. -/
def letter : Option Change → Char
  | none => '.'
  | some .added => 'A'
  | some .modified => 'M'
  | some .deleted => 'D'

/-- The `XY` git prints for a conflict. -/
def conflictCode : Conflict → String
  | .bothModified => "UU"
  | .bothAdded => "AA"
  | .bothDeleted => "DD"
  | .addedByUs => "AU"
  | .addedByThem => "UA"
  | .deletedByUs => "DU"
  | .deletedByThem => "UD"

/-- The record git prints for `file`, its NUL included, with placeholder
modes and object names. -/
def record (file : FileStatus) : String :=
  match file.state with
  | .changed staged unstaged =>
    s!"1 {letter staged}{letter unstaged} N... 100644 100644 100644 {zeros} {zeros} {file.path}\x00"
  | .renamed origin unstaged =>
    s!"2 R{letter unstaged} N... 100644 100644 100644 {zeros} {zeros} R100 {file.path}\x00{origin}\x00"
  | .conflicted how =>
    s!"u {conflictCode how} N... 100644 100644 100644 100644 {zeros} {zeros} {zeros} {file.path}\x00"
  | .untracked => s!"? {file.path}\x00"

/-- Where git lists a file: changes and renames, then conflicts, then
untracked files. -/
def listing : FileState → Nat
  | .changed .. | .renamed .. => 0
  | .conflicted _ => 1
  | .untracked => 2

/-- What `git status --porcelain=v2 -z --branch --untracked-files=all
--find-renames` prints of `repository`: the `branch.oid` and `branch.head`
headers, then a record for each file in git's order. -/
def porcelain (repository : Repository) : ByteArray :=
  let status := repository.status
  let oid := if repository.committed.isEmpty then "(initial)" else zeros
  let head :=
    match status.head with
    | .branch name => name
    | .detached => "(detached)"
  let listed :=
    (List.range 3).toArray.flatMap fun place => status.files.filter (listing ·.state == place)
  (s!"# branch.oid {oid}\x00# branch.head {head}\x00" ++
      String.join (listed.map record).toList).toUTF8

/-- `repository` with `path` staged: the working tree's content in the
index, or the path removed from it when the working tree lacks it. -/
def stageOne (repository : Repository) (path : String) : Repository :=
  match lookup repository.worktree path with
  | some content => { repository with index := setting repository.index path (.file content) }
  | none => { repository with index := without repository.index path }

/-- `repository` with `path` unstaged: `HEAD`'s content in the index, or the
path removed from it when `HEAD` lacks it. -/
def unstageOne (repository : Repository) (path : String) : Repository :=
  match lookup repository.committed path with
  | some content => { repository with index := setting repository.index path (.file content) }
  | none => { repository with index := without repository.index path }

/-- A run of `git` that exits 0 having written `stdout`. -/
def ran (stdout : ByteArray) : Except ProcessError Process.Ran :=
  .ok { exit := .code 0, stdout, stderr := .empty }

/-- The job model in which the git implementation, running `git` in `root`,
meets `repository`: its status read prints `porcelain`, and each of
`writes` exits 0. A command no script names is refused as `notFound`, as a
program that is not there is. -/
def jobModel (repository : Repository) (git : String) (root : System.FilePath)
    (writes : Array Request := #[]) : JobModel :=
  {
    processes :=
      {
        scripts :=
          #[{ command := Git.command git root .status, reply := ran repository.porcelain }] ++
            writes.map fun write =>
              { command := Git.command git root write, reply := ran .empty } } }

end Repository

/-- The model's answer to `request` in `repository`, and the repository
after it ("How it answers", in the module docs). -/
def handle : (request : Request) → Repository → request.Reply × Repository
  | .status, repository => (.ok repository.status, repository)
  | .stage paths, repository =>
    match
      paths.find? fun path =>
        (lookup repository.index path).isNone && (lookup repository.worktree path).isNone with
    | some path =>
      (.error (.failed (.code 128) s!"fatal: pathspec '{path}' did not match any files\n"),
        repository)
    | none => (.ok (), paths.foldl Repository.stageOne repository)
  | .unstage paths, repository => (.ok (), paths.foldl Repository.unstageOne repository)

end Editor.VersionControl.Model
