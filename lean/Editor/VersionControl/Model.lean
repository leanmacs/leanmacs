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
- **`fileAt revision path`**: `HEAD`'s content of the path, or a named
  revision's (`revisions`, the tags a test makes), or the index's for the
  empty revision; `none` when the revision does not have it or is not
  there.
- **`watched`**: the common directory (`commonDir`), with `HEAD` and the
  index of the git directory (`gitDir`), `packed-refs`, and `refs` as a
  tree, as the git implementation answers.
- **`commit`** (for tests, not a request) makes `HEAD`'s files the index's,
  as a commit made outside the editor does.

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
  /-- Named revisions besides `HEAD` (tags), each with its files. -/
  revisions : Array (String × Array (String × String)) := #[]
  /-- The repository's git directory. -/
  gitDir : System.FilePath := "/r/.git"
  /-- Its common git directory: the git directory, but for a linked
  worktree's. -/
  commonDir : System.FilePath := "/r/.git"
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

/-- What the git implementation's status read (`Git.statusArguments`)
prints of `repository`: the `branch.oid` and `branch.head` headers, then a
record for each file in git's order. -/
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

/-- The files of `revision` (`fileAt`'s): `HEAD`'s, a named revision's, and
`none` for a revision that is not there. -/
def filesOf (repository : Repository) (revision : String) : Option (Array (String × String)) :=
  if revision == "HEAD" then some repository.committed else lookup repository.revisions revision

/-- The content of `path` at `revision` ("How it answers", in the module
docs): the index's for the empty revision. -/
def fileAt (repository : Repository) (revision path : String) : Option String :=
  if revision.isEmpty then repository.indexed? path
  else (repository.filesOf revision).bind (lookup · path)

/-- What `watched` answers of `repository`: its common directory, with
`HEAD` and the index of its git directory, `packed-refs`, and `refs` as a
tree. -/
def watchedOf (repository : Repository) : Watched :=
  { directory := repository.commonDir
    paths :=
      #[repository.gitDir / "HEAD", repository.gitDir / "index",
        repository.commonDir / "packed-refs"]
    trees := #[repository.commonDir / "refs"] }

/-- `repository` with its index committed: `HEAD`'s files are the index's
merged files, as `git commit` without `-a` makes them. -/
def commit (repository : Repository) : Repository :=
  { repository with
    committed :=
      repository.index.filterMap fun (path, entry) =>
        match entry with
        | .file content => some (path, content)
        | .conflict .. => none }

end Repository

/-- The id the job model gives the blob of `content`: made of its content
alone, so equal contents share it, as git's do. -/
def blobId (content : String) : String :=
  s!"blob{hash content}"

namespace Repository

/-- The job model in which the git implementation, running `git` in `root`,
meets `repository`: its status read prints `porcelain`; each of `writes`
exits 0; `fileAt`'s two runs answer each file of `HEAD` and of each named
revision, its id and then its bytes; its first run exits 1 for each
revision and path of `missing`; and `watched` prints the git and the common
directories. A command no script names is refused as `notFound`, as a
program that is not there is. -/
def jobModel (repository : Repository) (git : String) (root : System.FilePath)
    (writes : Array Request := #[]) (missing : Array (String × String) := #[]) : JobModel :=
  let script (arguments : Array String) (stdout : ByteArray) : Process.Script :=
    { command := Git.command git root arguments, reply := ran stdout }
  let files :=
    (("HEAD", repository.committed) :: repository.revisions.toList).toArray.flatMap
      fun (revision, files) => files.map fun (path, content) => (revision, path, content)
  {
    processes :=
      {
        scripts :=
          #[script Git.statusArguments repository.porcelain] ++
                writes.filterMap (fun write =>
                  match write with
                  | .stage paths => some (script (Git.stageArguments paths) .empty)
                  | .unstage paths => some (script (Git.unstageArguments paths) .empty)
                  | _ => none) ++
              files.flatMap (fun (revision, path, content) =>
                #[script (Git.revisionArguments revision path) s!"{blobId content}\n".toUTF8,
                  script (Git.blobArguments (blobId content)) (File.encodeText content)]) ++
            missing.map (fun (revision, path) =>
              { command := Git.command git root (Git.revisionArguments revision path)
                reply := .ok { exit := .code 1, stdout := .empty, stderr := .empty } }) ++
          #[script Git.watchedArguments
              s!"{repository.gitDir}\n{repository.commonDir}\n".toUTF8] } }

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
  | .fileAt revision path, repository => (.ok (repository.fileAt revision path), repository)
  | .watched, repository => (.ok repository.watchedOf, repository)

end Editor.VersionControl.Model
