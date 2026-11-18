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
- **`fileAt revision path`**: the content of the path at the commit the
  revision resolves to ("The graph"): `HEAD`'s, a branch's, a tag's
  (`revisions`, the tags a test makes) or a commit's, or the index's for
  the empty revision; `none` when the revision does not have it or is not
  there.
- **`watched`**: the common directory (`commonDir`), with `HEAD` and the
  index of the git directory (`gitDir`), `packed-refs`, and `refs` as a
  tree, as the git implementation answers.
- **`stageHunk path hunk`**: the index must hold `path` as a merged file
  whose lines at row `oldLine` are `before ++ removed ++ after`; those
  lines become `before ++ added ++ after`. Otherwise it is refused with
  status 1, `error: patch failed: <path>`, and nothing changes.
- **`unstageHunk path hunk`**: the same at row `newLine`, with `added` and
  `removed` swapped.
- **The position is exact** where git may apply a hunk at an offset, when
  its lines are found elsewhere: the editor's hunks are made from the index
  just read, so their position is exact, and the contract's refused hunk
  holds lines that are nowhere in the file.
- **`commit message`**: a conflict entry refuses it (128); then a `hook`
  that refuses (1, what it printed); then an index equal to `HEAD` (1,
  `nothing to commit`). Otherwise `HEAD`'s files become the index's
  (`Repository.commit`). The model keeps no message.
- **`Repository.commit`** (also for tests) makes `HEAD`'s files the index's,
  as a commit made outside the editor does. It first freezes `HEAD`'s
  commit into the graph, with its parents, when the branch is born, and
  `HEAD` becomes a new commit whose parent it is, so a branch made from
  `HEAD` before a commit stays where it was.

## The graph

- **Commits**: `HEAD`'s, whose files are `committed`, its id `headId` and
  its parents `parents`; the others in `commits`, by id, parents before
  children, none naming `HEAD`'s; and each tag of `revisions`, a
  parentless commit of its files whose id is its name.
- **A name resolves** (`resolve`) to `HEAD`'s commit for `HEAD` and the
  checked-out branch while it is born, to a branch's commit, to a tag, or
  to a commit's id; `fileAt` reads through it.
- **The merge base** (`mergeBase`) is the first of one commit's ancestors,
  breadth-first, that is also the other's. That is git's answer wherever
  the merge base is unique, as in every property's graph; a criss-cross
  history has several, and git picks one.
- **`worktrees`**: the root on `head`, then each linked worktree on its
  branch, or detached, in path order.
- **`branches`**: the checked-out branch while it is born, and the others,
  in byte order.
- **`changes revision against`**: `Request.invalid?` first; then each name
  resolved, or refused with status 1, `<name> is not a commit`; then their
  merge base, or status 1, `<revision> and <against> have no merge base`;
  then every path of either side whose content differs, sorted.
- **`addWorktree path branch start`**: `Request.invalid?` first; a path
  that is the root or a linked worktree is refused (128). With `start`, a
  branch that exists is refused (128), and a start that resolves to
  nothing (128); otherwise the branch is made there. Without it, a missing
  branch, or one checked out at the root or in a linked worktree, is
  refused (128). Then the linked worktree is added.
- **`removeWorktree path`**: `Request.invalid?` first; the root (128, `is a
  main working tree`), a path that is no linked worktree (128) and a dirty
  one (128, `contains modified or untracked files`) are refused; otherwise
  it is dropped, and its branch kept.

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

/-- A commit of the model's graph: its parents and its files. -/
structure Commit where
  /-- Its parents' ids, the first parent first. -/
  parents : Array String := #[]
  /-- Its files, each a path and its content. -/
  files : Array (String × String)
  deriving DecidableEq, Repr

/-- A linked worktree. -/
structure Linked where
  /-- Its directory, beside the root: `/<name>` for the root `/r`. -/
  path : System.FilePath
  /-- Its branch, or none when it is detached at `HEAD`'s commit. -/
  branch : Option String
  /-- Whether it holds an untracked file, so that removing it is refused. -/
  dirty : Bool := false
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
  /-- A pre-commit hook that refuses every commit, printing this: its first
  line on its standard output and the rest on its standard error. -/
  hook : Option String := none
  /-- The main worktree's directory. -/
  root : System.FilePath := "/r"
  /-- Commits besides `HEAD`'s, by id, parents before children. None names
  `HEAD`'s commit as a parent. -/
  commits : Array (String × Commit) := #[]
  /-- Branches besides the checked-out one, each a name and a commit's id. -/
  branches : Array (String × String) := #[]
  /-- The parents of `HEAD`'s commit, each the id of one of `commits`. -/
  parents : Array String := #[]
  /-- `HEAD`'s commit's id; its files are `committed`. -/
  headId : String := "head"
  /-- The linked worktrees. -/
  linked : Array Linked := #[]
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

/-- The checked-out branch's name, if `HEAD` is on one. -/
def checkedOut (repository : Repository) : Option String :=
  match repository.head with
  | .branch name => some name
  | .detached => none

/-- The commit id `name` names ("The graph", in the module docs): `HEAD` and
the checked-out branch name `HEAD`'s commit while the branch is born, a
branch its commit, a tag itself, and a commit's id itself; `none` for a
name that is none of these. -/
def resolve (repository : Repository) (name : String) : Option String :=
  if name == "HEAD" || repository.checkedOut == some name then
    if repository.committed.isEmpty then none else some repository.headId
  else
    match lookup repository.branches name with
    | some id => some id
    | none =>
      if (lookup repository.revisions name).isSome then some name
      else if (lookup repository.commits name).isSome then some name else none

/-- The files of the commit `id`: `HEAD`'s, a commit's, or a tag's. -/
def filesAt (repository : Repository) (id : String) : Option (Array (String × String)) :=
  if id == repository.headId && !repository.committed.isEmpty then some repository.committed
  else
    match lookup repository.commits id with
    | some commit => some commit.files
    | none => lookup repository.revisions id

/-- The parents of the commit `id`; a tag's commit has none. -/
def parentsOf (repository : Repository) (id : String) : Array String :=
  if id == repository.headId then repository.parents
  else ((lookup repository.commits id).map (·.parents)).getD #[]

/-- The commit `id` and its ancestors, breadth-first, the commit first, each
once. -/
def ancestors (repository : Repository) (id : String) : Array String :=
  let fuel := repository.commits.size + 2
  (List.range fuel).foldl
      (fun ((seen, frontier) : Array String × Array String) _ =>
        let next :=
          frontier.foldl
            (fun (next : Array String) at_ =>
              (repository.parentsOf at_).foldl
                (fun next parent =>
                  if seen.contains parent || next.contains parent then next else next.push parent)
                next)
            #[]
        (seen ++ next, next))
      (#[id], #[id]) |>.1

/-- The merge base of the commits `a` and `b`: the first of `a`'s ancestors,
breadth-first, that is also `b`'s. Where the merge base is unique, as in
every property's graph, that is git's. -/
def mergeBase (repository : Repository) (a b : String) : Option String :=
  let ofB := repository.ancestors b
  (repository.ancestors a).find? ofB.contains

/-- The files of `revision` (`fileAt`'s), through `resolve`; `none` for a
revision that is not there. -/
def filesOf (repository : Repository) (revision : String) : Option (Array (String × String)) :=
  (repository.resolve revision).bind repository.filesAt

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
  let frozen :=
    if repository.committed.isEmpty then repository
    else
      let headId := s!"{repository.headId}-{repository.commits.size}"
      { repository with
        commits :=
          repository.commits.push
            (repository.headId, { parents := repository.parents, files := repository.committed })
        parents := #[repository.headId], headId }
  { frozen with
    committed :=
      repository.index.filterMap fun (path, entry) =>
        match entry with
        | .file content => some (path, content)
        | .conflict .. => none }

/-- `content` with its lines `old` at row `row` replaced by `new`, when they
are there. -/
def replaceLines (content : String) (row : Nat) (old new : Array String) : Option String :=
  let lines := linesOf content
  if row + old.size ≤ lines.size && lines.extract row (row + old.size) == old then
    some (String.join (lines.extract 0 row ++ new ++ lines.extract (row + old.size)).toList)
  else none

/-- `repository` with the lines `old` at row `row` of the index's `path`
replaced by `new`, or the refusal git gives a patch that does not apply. -/
def applyLines (repository : Repository) (path : String) (row : Nat) (old new : Array String) :
    Except Error Repository :=
  match (repository.indexed? path).bind (replaceLines · row old new) with
  | some content => .ok { repository with index := setting repository.index path (.file content) }
  | none => .error (.failed (.code 1) s!"error: patch failed: {path}")

/-- The merged files of the index, sorted by path. -/
def indexFiles (repository : Repository) : Array (String × String) :=
  (repository.index.filterMap fun (path, entry) =>
        match entry with
        | .file content => some (path, content)
        | .conflict .. => none).qsort
    fun a b => decide (a.1 < b.1)

/-- What a commit of `repository` comes to ("How it answers", in the module
docs): the repository after it, or why it is refused. -/
def committing (repository : Repository) : Except Error Repository :=
  if repository.index.any (·.2 matches .conflict ..) then
    .error
      (.failed (.code 128) "error: Committing is not possible because you have unmerged files.")
  else
    match repository.hook with
    | some printed => .error (.failed (.code 1) printed.trimAsciiEnd.toString)
    | none =>
      if repository.indexFiles == repository.committed.qsort (fun a b => decide (a.1 < b.1)) then
        .error (.failed (.code 1) "nothing to commit")
      else .ok repository.commit

/-- The worktrees of `repository` (`worktrees`): the main one, then each
linked one in path order. -/
def worktreesOf (repository : Repository) : Array Worktree :=
  #[{ path := repository.root, head := repository.head }] ++
    (repository.linked.map fun linked =>
          ({  path := linked.path
              head :=
                match linked.branch with
                | some branch => .branch branch
                | none => .detached } :
            Worktree)).qsort
      fun a b => decide (a.path.toString < b.path.toString)

/-- The local branches of `repository` (`branches`): the checked-out one
while it is born, and every other, in byte order. -/
def branchNames (repository : Repository) : Array String :=
  let current :=
    match repository.checkedOut with
    | some name => if repository.committed.isEmpty then #[] else #[name]
    | none => #[]
  (current ++ repository.branches.map (·.1)).qsort fun a b => decide (a < b)

/-- Whether a branch named `name` exists: the checked-out one while it is
born, or another. -/
def hasBranch (repository : Repository) (name : String) : Bool :=
  repository.branchNames.contains name

/-- The change of `revision` against its merge base with `against`
("`changes`", in the module docs), or why it is refused. -/
def changesOf (repository : Repository) (revision against : String) : Except Error Changes := do
  let resolved (name : String) : Except Error String :=
    match repository.resolve name with
    | some id => .ok id
    | none => .error (.failed (.code 1) s!"{name} is not a commit")
  let new ← resolved revision
  let old ← resolved against
  let some base :=
    repository.mergeBase new
      old | throw (.failed (.code 1) s!"{revision} and {against} have no merge base")
  let oldFiles := (repository.filesAt base).getD #[]
  let newFiles := (repository.filesAt new).getD #[]
  let paths :=
    ((oldFiles.map (·.1) ++ newFiles.map (·.1)).qsort fun a b => decide (a < b)).foldl
      (fun (kept : Array String) path => if kept.back? == some path then kept else kept.push path)
      #[]
  return {
      base
      files :=
        paths.filterMap fun path =>
          let (old, new) := (lookup oldFiles path, lookup newFiles path)
          if old == new then none else some { path, old, new } }

/-- Where the branch `branch` is checked out, if it is: the root or a linked
worktree's directory. -/
def checkedOutAt (repository : Repository) (branch : String) : Option System.FilePath :=
  if repository.checkedOut == some branch then some repository.root
  else (repository.linked.find? (·.branch == some branch)).map (·.path)

/-- `repository` with a worktree added at `path` ("`addWorktree`", in the
module docs), or why it is refused, as git refuses it. -/
def addingWorktree (repository : Repository) (path : System.FilePath) (branch : String)
    (start : Option String) : Except Error Repository := do
  if path == repository.root || repository.linked.any (·.path == path) then
    throw (.failed (.code 128) s!"fatal: '{path}' already exists")
  match start with
  | some start =>
    if repository.hasBranch branch then
      throw (.failed (.code 128) s!"fatal: a branch named '{branch}' already exists")
    let some id :=
      repository.resolve start | throw (.failed (.code 128) s!"fatal: invalid reference: {start}")
    return { repository with
        branches := repository.branches.push (branch, id)
        linked := repository.linked.push { path, branch := some branch } }
  | none =>
    if !repository.hasBranch branch then
      throw (.failed (.code 128) s!"fatal: invalid reference: {branch}")
    if let some at_ := repository.checkedOutAt branch then
      throw (.failed (.code 128) s!"fatal: '{branch}' is already used by worktree at '{at_}'")
    return { repository with linked := repository.linked.push { path, branch := some branch } }

/-- `repository` with the linked worktree at `path` removed
("`removeWorktree`", in the module docs), or why it is refused, as git
refuses it. -/
def removingWorktree (repository : Repository) (path : System.FilePath) : Except Error Repository :=
  do
  if path == repository.root then
    throw (.failed (.code 128) s!"fatal: '{path}' is a main working tree")
  let some linked :=
    repository.linked.find?
      (·.path == path) | throw (.failed (.code 128) s!"fatal: '{path}' is not a working tree")
  if linked.dirty then
    throw
        (.failed (.code 128)
          s!"fatal: '{path}' contains modified or untracked files, use --force to delete it")
  return { repository with linked := repository.linked.filter (·.path != path) }

/-- What the git implementation's worktree list read
(`Git.worktreeListArguments`) prints of `repository`, as git prints it with
`-z`: a record for each worktree, its path, `HEAD` and its branch or
`detached`. -/
def worktreePorcelain (repository : Repository) : ByteArray :=
  String.join
      (repository.worktreesOf.toList.map fun worktree =>
        let head :=
          match worktree.head with
          | .branch name => s!"branch refs/heads/{name}"
          | .detached => "detached"
        s!"worktree {worktree.path}\x00HEAD {zeros}\x00{head}\x00\x00") |>.toUTF8

end Repository

/-- The id the job model gives the blob of `content`: made of its content
alone, so equal contents share it, as git's do. -/
def blobId (content : String) : String :=
  s!"blob{hash content}"

namespace Repository

/-- The job model in which the git implementation, running `git` in `root`,
meets `repository`: its status read prints `porcelain`; each of `writes`
exits 0; `fileAt`'s two runs answer each file of `HEAD`, of the index (the
empty revision) and of each named revision, its id and then its bytes; its first run exits 1 for each
revision and path of `missing`; and `watched` prints the git and the common
directories; and its worktree list read prints `worktreePorcelain`. A hunk's apply of `writes` exits 0 whatever it is fed, and so
does its commit, but in a repository with a `hook`, where it exits 1 with
the hook's output on its standard error. A command no script names is refused as `notFound`, as a
program that is not there is. -/
def jobModel (repository : Repository) (git : String) (root : System.FilePath)
    (writes : Array Request := #[]) (missing : Array (String × String) := #[]) : JobModel :=
  let script (arguments : Array String) (stdout : ByteArray) : Process.Script :=
    { command := Git.command git root arguments, reply := ran stdout }
  let files :=
    (("HEAD", repository.committed) ::
          ("", repository.indexFiles) :: repository.revisions.toList).toArray.flatMap
      fun (revision, files) => files.map fun (path, content) => (revision, path, content)
  {
    processes :=
      {
        scripts :=
          #[script Git.statusArguments repository.porcelain,
              script Git.worktreeListArguments repository.worktreePorcelain] ++
            writes.filterMap
              (fun write =>
                match write with
                | .stage paths => some (script (Git.stageArguments paths) .empty)
                | .unstage paths => some (script (Git.unstageArguments paths) .empty)
                | .stageHunk .. => some (script (Git.applyArguments false) .empty)
                | .unstageHunk .. => some (script (Git.applyArguments true) .empty)
                | .commit _ =>
                  some
                    { command := Git.commitCommand git root
                      reply :=
                        match repository.hook with
                        | some printed =>
                          .ok {
                              exit := .code 1, stdout := .empty
                              stderr := File.encodeText printed }
                        | none => ran .empty }
                | _ => none) ++
            files.flatMap
              (fun (revision, path, content) =>
                #[script (Git.revisionArguments revision path) s!"{blobId content}\n".toUTF8,
                  script (Git.blobArguments (blobId content)) (File.encodeText content)]) ++
            missing.map
              (fun (revision, path) =>
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
  | .stageHunk path hunk, repository =>
    match
      repository.applyLines path hunk.oldLine (hunk.before ++ hunk.removed ++ hunk.after)
        (hunk.before ++ hunk.added ++ hunk.after) with
    | .ok after => (.ok (), after)
    | .error error => (.error error, repository)
  | .unstageHunk path hunk, repository =>
    match
      repository.applyLines path hunk.newLine (hunk.before ++ hunk.added ++ hunk.after)
        (hunk.before ++ hunk.removed ++ hunk.after) with
    | .ok after => (.ok (), after)
    | .error error => (.error error, repository)
  | .commit _, repository =>
    match repository.committing with
    | .ok after => (.ok (), after)
    | .error error => (.error error, repository)
  | .worktrees, repository => (.ok repository.worktreesOf, repository)
  | .branches, repository => (.ok repository.branchNames, repository)
  | request@(.changes revision against), repository =>
    match request.invalid? with
    | some detail => (.error (.invalid detail), repository)
    | none => (repository.changesOf revision against, repository)
  | request@(.addWorktree path branch start), repository =>
    match request.invalid? with
    | some detail => (.error (.invalid detail), repository)
    | none =>
      match repository.addingWorktree path branch start with
      | .ok after => (.ok (), after)
      | .error error => (.error error, repository)
  | request@(.removeWorktree path), repository =>
    match request.invalid? with
    | some detail => (.error (.invalid detail), repository)
    | none =>
      match repository.removingWorktree path with
      | .ok after => (.ok (), after)
      | .error error => (.error error, repository)

end Editor.VersionControl.Model
