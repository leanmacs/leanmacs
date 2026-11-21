import Editor.Diff.Model
import Editor.Job.Model
import VcApi

/-!
# The fake of `vc-api`: the pure model of a repository

The interface library `vc-api`'s fake (`VcApi.lean`): a repository as a
value: what is checked out, `HEAD`'s files, the index and the working tree,
each a path and its content. `Repository.status` answers a status as a pure
function, and `Model.handle` answers each request of the version-control
port. It knows nothing of git: what git prints of a repository and the job
model that answers git's command lines are the git implementation's
(`Editor/VersionControl/Git/Model.lean`). A consumer connects to it through
`VcApiTest.backend`, a backend whose handler answers from the model, in
place of any implementation's. `Model.readHandler` answers the
port's requests inside a job from a repository as it is, for a read whose
replies the job model's scripts do not print (the review's, the log's and
the blame's reads, `Editor/VersionControl/Review.lean`,
`Editor/VersionControl/Log.lean`, `Editor/VersionControl/Blame.lean`).

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
  (`Repository.commit`). The model keeps the message's subject alone, as
  git's `%s` gives it (`subjectOf`): the first paragraph after any blank
  lines, each line's trailing white space dropped, its lines joined by a
  space.
- **`Repository.commit subject`** (also for tests, `commit` by default)
  makes `HEAD`'s files the index's, as a commit made outside the editor
  does. It first freezes `HEAD`'s commit into the graph, with its parents
  and who wrote it (`headAuthored`), when the branch is born, and `HEAD`
  becomes a new commit whose parent it is, its subject `subject`, so a
  branch made from `HEAD` before a commit stays where it was.

## The graph

- **Commits**: `HEAD`'s, whose files are `committed`, its id `headId`, its
  parents `parents` and who wrote it `headAuthored`; the others in
  `commits`, by id, parents before children, none naming `HEAD`'s, each
  with who wrote it (`Commit.authored`); and each tag of `revisions`, a
  parentless commit of its files whose id is its name.
- **Who wrote a commit** (`authoredOf`): unless it says otherwise, `a` at
  2026-01-01T00:00:00Z (`fixedAuthored`), the writer's fixed author and
  time; an empty subject is the commit's id, and a tag's is its name, which
  is what the writer's messages are (`ContractTest.writeGitRepository`).
  `HEAD`'s subject is `head`, the writer's message, until a commit makes
  another.
- **A name resolves** (`resolve`) to `HEAD`'s commit for `HEAD` and the
  checked-out branch while it is born, to a branch's commit, to a tag, or
  to a commit's id, `HEAD`'s among them; `fileAt` reads through it.
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
  then every path of either side whose content differs, sorted. The tip is
  the revision's id; an empty `against` is no base, an empty `base` and
  every file of the revision added.
- **`log revision limit`**: `Request.invalid?` first; the revision
  resolved, or refused as `changes` refuses it; then it and its first
  parents (`parentsOf`), newest first, at most `limit`, each with its
  parents and `authoredOf`.
- **`blame revision path`**: `Request.invalid?` first; the revision
  resolved, or refused; `none` when its commit lacks the path; otherwise
  each line (`linesOf`, its line feed dropped) handed down the graph
  (`blameRows`): a commit's lines outside every hunk of its parent's text
  against its own (`DiffModel.lineHunks`) pass to that parent, the first
  parent first, then each other in order, carried to their rows there, and
  on through it; what no parent has stays with the commit. That is git's
  rule when no rename or move is to be followed, as in every property's
  graph: git also follows a file renamed whole, which the model does not.
- **`rangeDiff base old new`**: `Request.invalid?` first; each name
  resolved, or refused; each range (`rangeOf`) the ancestors of its tip
  that are not `base`'s, merges dropped, oldest first; each commit's patch
  (`patchOf`) its change against its first parent, each changed path's
  hunks (`LineHunk.ofTexts` over `DiffModel.hunks`) with their rows
  dropped. A new commit is paired `=` with the first old one not yet
  paired of equal subject, author and patch, then `!` with the first of
  equal subject; the rest are `<` and `>`. git pairs `!` by the cost of
  the diff of the two patches, under `--creation-factor`, so the two agree
  where an amended commit keeps its subject and most of its patch, and two
  commits of different subjects change different files, as in every
  property's graph. The pairs are listed in git's order (range-diff.c's
  `output`): an unpaired old commit once the old ones before it are shown,
  then the unpaired new ones, then each pair, in the new range's order. The
  text is each pair's header line as git prints it, with the model's ids.
- **`addWorktree path branch start`**: `Request.invalid?` first; a path
  that is, once `normal`, the root, a linked worktree or an `occupied`
  directory is refused (128), `'<path>' already exists`. With `start`, a
  branch that exists is refused (128), and a start that resolves to
  nothing (128); otherwise the branch is made there. Without it, a missing
  branch, or one checked out at the root or in a linked worktree, is
  refused (128). Then the linked worktree is added.
- **`removeWorktree path`**: `Request.invalid?` first; the root (128, `is a
  main working tree`), a path that is no linked worktree (128) and a dirty
  one (128, `contains modified or untracked files`) are refused; otherwise
  it is dropped, and its branch kept.

The contract (`VcApiTest/Contract.lean`) is what says the model and an
implementation agree.
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

/-- Who wrote a commit of the model unless it says otherwise: `a`, at
2026-01-01T00:00:00Z, the writer's fixed author and time; an empty subject
is the commit's id, which the writer's message is. -/
def fixedAuthored : Authored :=
  { author := "a", time := 1767225600, subject := "" }

/-- A commit of the model's graph: its parents, its files and who wrote
it. -/
structure Commit where
  /-- Its parents' ids, the first parent first. -/
  parents : Array String := #[]
  /-- Its files, each a path and its content. -/
  files : Array (String × String)
  /-- Who wrote it, when, and its subject; an empty subject is its id. -/
  authored : Authored := fixedAuthored
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
  /-- Who wrote `HEAD`'s commit, when, and its subject: `head`, the
  writer's message, unless a commit made another. -/
  headAuthored : Authored := { fixedAuthored with subject := "head" }
  /-- The linked worktrees. -/
  linked : Array Linked := #[]
  /-- Directories beside the root that hold a file and are no worktree,
  each `/<name>` for the root `/r`: git makes no worktree in one. -/
  occupied : Array System.FilePath := #[]
  deriving DecidableEq, Repr

/-- `path` with its spelling made one: no empty or `.` component, and each
`..` taking the component before it away, as git resolves a worktree's path
when the model's directories hold no link. -/
def normal (path : System.FilePath) : System.FilePath :=
  let parts :=
    (path.toString.splitOn "/").foldl
      (fun (kept : Array String) part =>
        if part.isEmpty || part == "." then kept
        else if part == ".." then kept.pop else kept.push part)
      #[]
  let joined := "/".intercalate parts.toList
  if path.isAbsolute then ⟨"/" ++ joined⟩ else ⟨joined⟩

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

/-- The checked-out branch's name, if `HEAD` is on one. -/
def checkedOut (repository : Repository) : Option String :=
  match repository.head with
  | .branch name => some name
  | .detached => none

/-- The commit id `name` names ("The graph", in the module docs): `HEAD` and
the checked-out branch name `HEAD`'s commit while the branch is born, a
branch its commit, a tag itself, and a commit's id itself, `HEAD`'s among
them; `none` for a name that is none of these. -/
def resolve (repository : Repository) (name : String) : Option String :=
  if name == "HEAD" || repository.checkedOut == some name then
    if repository.committed.isEmpty then none else some repository.headId
  else
    match lookup repository.branches name with
    | some id => some id
    | none =>
      if (lookup repository.revisions name).isSome then some name
      else
        if (lookup repository.commits name).isSome then some name
        else if name == repository.headId && !repository.committed.isEmpty then some name else none

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

/-- `repository` with its index committed as a commit whose subject is
`subject`: `HEAD`'s files are the index's merged files, as `git commit`
without `-a` makes them, and the commit `HEAD` was is frozen into the graph
with who wrote it. -/
def commit (repository : Repository) (subject : String := "commit") : Repository :=
  let frozen :=
    if repository.committed.isEmpty then repository
    else
      let headId := s!"{repository.headId}-{repository.commits.size}"
      { repository with
        commits :=
          repository.commits.push
            (repository.headId,
              { parents := repository.parents, files := repository.committed
                authored := repository.headAuthored })
        parents := #[repository.headId], headId }
  { frozen with
    headAuthored := { repository.headAuthored with subject }
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

/-- The subject of a commit whose message is `message`, as git's `%s` gives
it: the first paragraph after any blank lines, each line's trailing white
space dropped, its lines joined by a space. -/
def subjectOf (message : String) : String :=
  let lines := ((message.splitOn "\n").map (·.trimAsciiEnd.toString)).dropWhile (·.isEmpty)
  " ".intercalate (lines.takeWhile (!·.isEmpty))

/-- What a commit of `repository` with `message` comes to ("How it answers",
in the module docs): the repository after it, its new commit's subject
`message`'s (`subjectOf`), or why it is refused. -/
def committing (repository : Repository) (message : String) : Except Error Repository :=
  if repository.index.any (·.2 matches .conflict ..) then
    .error
      (.failed (.code 128) "error: Committing is not possible because you have unmerged files.")
  else
    match repository.hook with
    | some printed => .error (.failed (.code 1) printed.trimAsciiEnd.toString)
    | none =>
      if repository.indexFiles == repository.committed.qsort (fun a b => decide (a.1 < b.1)) then
        .error (.failed (.code 1) "nothing to commit")
      else .ok (repository.commit (subjectOf message))

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

/-- The commit id `name` names, or the refusal of a name that names none:
status 1, `<name> is not a commit`. -/
def resolved (repository : Repository) (name : String) : Except Error String :=
  match repository.resolve name with
  | some id => .ok id
  | none => .error (.failed (.code 1) s!"{name} is not a commit")

/-- Who wrote the commit `id` ("The graph", in the module docs): `HEAD`'s
`headAuthored`, a commit's `authored`, and for a tag the fixed author with
its name as its subject; an empty subject is the commit's id. -/
def authoredOf (repository : Repository) (id : String) : Authored :=
  let named (authored : Authored) : Authored :=
    if authored.subject.isEmpty then { authored with subject := id } else authored
  if id == repository.headId && !repository.committed.isEmpty then named repository.headAuthored
  else
    match lookup repository.commits id with
    | some commit => named commit.authored
    | none => { fixedAuthored with subject := id }

/-- How many commits a walk of the graph may take: each commit and tag
once, and `HEAD`'s. -/
def fuel (repository : Repository) : Nat :=
  repository.commits.size + repository.revisions.size + 2

/-- The log of `revision` ("`log`", in the module docs): it and its first
parents, newest first, at most `limit`, or why it is refused. -/
def logOf (repository : Repository) (revision : String) (limit : Nat) :
    Except Error (Array LogEntry) := do
  let id ← repository.resolved revision
  let (entries, _) :=
    (List.range (min limit repository.fuel)).foldl
      (fun ((entries, next) : Array LogEntry × Option String) _ =>
        match next with
        | none => (entries, none)
        | some id =>
          let parents := repository.parentsOf id
          (entries.push { id, parents, authored := repository.authoredOf id }, parents[0]?))
      (#[], some id)
  return entries

/-- The content of `path` in the commit `id`, if it has the path. -/
def contentAt (repository : Repository) (id path : String) : Option String :=
  (repository.filesAt id).bind (lookup · path)

/-- The line hunks of `old` against `new`, as rows of their lines, none
empty on both sides. -/
def rowHunks (old new : String) : Array DiffModel.Hunk :=
  (DiffModel.lineHunks (DiffModel.lines old.toUTF8) (DiffModel.lines new.toUTF8) 100000).filter
    fun hunk => hunk.oldStart != hunk.oldStop || hunk.newStart != hunk.newStop

/-- The rows of `rows` (each a line of the blamed file and its row in
`new`) that a parent whose text is `old` has unchanged, each carried to its
row in `old`, and the rows it does not have. -/
def carried (old new : String) (rows : Array (Nat × Nat)) : Array (Nat × Nat) × Array (Nat × Nat) :=
  let hunks := rowHunks old new
  rows.foldl
    (fun ((moved, kept) : Array (Nat × Nat) × Array (Nat × Nat)) (line, row) =>
      if hunks.any fun hunk => hunk.newStart ≤ row && row < hunk.newStop then
        (moved, kept.push (line, row))
      else
        let before := hunks.filter (·.newStop ≤ row)
        let shift := before.foldl (fun shift hunk => shift + (hunk.oldStop - hunk.oldStart : Nat)) 0
        let back := before.foldl (fun back hunk => back + (hunk.newStop - hunk.newStart : Nat)) 0
        (moved.push (line, row - back + shift), kept))
    (#[], #[])

/-- The commit that last changed each line of `rows` (each a line of the
blamed file and its row in the commit `id`'s `content` of `path`): each
passed to the first parent, then each other, whose file has it unchanged,
and on through that parent; the commit's own otherwise. -/
def blameRows (repository : Repository) (path : String) :
    Nat → String → String → Array (Nat × Nat) → Array (Nat × String)
  | 0, id, _, rows => rows.map fun (line, _) => (line, id)
  | fuel + 1, id, content, rows =>
    let (passed, left) :=
      (repository.parentsOf id).foldl
        (fun ((passed, left) : Array (String × String × Array (Nat × Nat)) × Array (Nat × Nat))
            parent =>
          match repository.contentAt parent path with
          | none => (passed, left)
          | some old =>
            let (moved, kept) := carried old content left
            (passed.push (parent, old, moved), kept))
        (#[], rows)
    left.map (fun (line, _) => (line, id)) ++
      passed.flatMap fun (parent, old, moved) =>
        if moved.isEmpty then #[] else repository.blameRows path fuel parent old moved

/-- The blame of `path` at `revision` ("`blame`", in the module docs): `none`
when the revision lacks the path, or why it is refused. -/
def blameOf (repository : Repository) (revision path : String) : Except Error (Option Blame) := do
  let id ← repository.resolved revision
  let some content := repository.contentAt id path | return none
  let texts := linesOf content
  let rows := (Array.range texts.size).map fun row => (row, row)
  let owners := repository.blameRows path repository.fuel id content rows
  let lines :=
    (Array.range texts.size).map fun row =>
      { id := ((owners.find? (·.1 == row)).map (·.2)).getD id
        text := (texts[row]?.getD "").dropSuffix "\n" |>.toString : BlameLine }
  let commits :=
    lines.foldl
      (fun (commits : Array (String × Authored)) line =>
        if commits.any (·.1 == line.id) then commits
        else commits.push (line.id, repository.authoredOf line.id))
      #[]
  return some { commits, lines }

/-- The commits of `base..tip`, merges left out, oldest first. -/
def rangeOf (repository : Repository) (base tip : String) : Array String :=
  let excluded := repository.ancestors base
  ((repository.ancestors tip).filter fun id =>
      !excluded.contains id && (repository.parentsOf id).size ≤ 1).reverse

/-- The change the commit `id` makes against its first parent, as range-diff
compares it: each path whose content differs, with its hunks, their rows
dropped. -/
def patchOf (repository : Repository) (id : String) : Array (String × Array LineHunk) :=
  let newFiles := (repository.filesAt id).getD #[]
  let oldFiles := (((repository.parentsOf id)[0]?).bind repository.filesAt).getD #[]
  let paths :=
    ((oldFiles.map (·.1) ++ newFiles.map (·.1)).qsort fun a b => decide (a < b)).foldl
      (fun (kept : Array String) path => if kept.back? == some path then kept else kept.push path)
      #[]
  paths.filterMap fun path =>
    let (old, new) := (lookup oldFiles path, lookup newFiles path)
    if old == new then none
    else
      let (old, new) := (old.getD "", new.getD "")
      some
        (path,
          (DiffModel.hunks old new 100000).map fun hunk =>
            { LineHunk.ofTexts .stage old new hunk with
              oldLine := 0, newLine := 0 })

/-- The header line git prints of a range-diff pair: each side's index, padded
to `width`, and the commit's id, or dashes, the mark, and the subject. -/
def rangeLine (width : Nat) (old new : Option (Nat × String)) (mark subject : String) : String :=
  let side : Option (Nat × String) → String
    | some (index, id) =>
      let number := toString index
      s!"{String.ofList (List.replicate (width - number.length) ' ')}{number}:  {(id.take 7).toString}"
    | none => s!"{String.ofList (List.replicate (width - 1) ' ')}-:  -------"
  s!"{side old} {mark} {side new} {subject}\n"

/-- The range-diff of `base..old` against `base..new` ("`rangeDiff`", in the
module docs), or why it is refused. -/
def rangeDiffOf (repository : Repository) (base old new : String) : Except Error RangeDiff := do
  let base ← repository.resolved base
  let old ← repository.resolved old
  let new ← repository.resolved new
  let olds := repository.rangeOf base old
  let news := repository.rangeOf base new
  let same (a b : String) : Bool :=
    (repository.authoredOf a).subject == (repository.authoredOf b).subject &&
      (repository.authoredOf a).author == (repository.authoredOf b).author &&
      repository.patchOf a == repository.patchOf b
  let similar (a b : String) : Bool :=
    (repository.authoredOf a).subject == (repository.authoredOf b).subject
  let pairing (matches_ : Array (Option (Nat × RangeRelation))) (relation : RangeRelation)
    (holds : String → String → Bool) : Array (Option (Nat × RangeRelation)) :=
    (Array.range news.size).foldl
      (fun matches_ j =>
        if (matches_[j]?.join).isSome then matches_
        else
          match
            (Array.range olds.size).find? fun i =>
              !matches_.any (·.any (·.1 == i)) && holds (olds[i]?.getD "") (news[j]?.getD "") with
          | some i => matches_.set! j (some (i, relation))
          | none => matches_)
      matches_
  let matches_ := pairing (pairing (Array.replicate news.size none) .same same) .changed similar
  let matched (i : Nat) : Bool := matches_.any (·.any (·.1 == i))
  let width := (toString (max olds.size news.size)).length
  let subjectOf (id : String) := (repository.authoredOf id).subject
  let at_ (ids : Array String) (index : Nat) : Option (Nat × String) :=
    ids[index]?.map (index + 1, ·)
  let (pairs, text) :=
    Id.run do
      let mut i := 0
      let mut j := 0
      let mut shown : Array Bool := Array.replicate olds.size false
      let mut pairs : Array RangePair := #[]
      let mut text := ""
      for _ in [0:olds.size + news.size + 1] do
        while i < olds.size && (shown[i]?.getD false) do
          i := i + 1
        if i ≥ olds.size && j ≥ news.size then
          break
        if i < olds.size && !matched i then
          pairs := pairs.push { old := some (i + 1), new := none, relation := .removed }
          text := text ++ rangeLine width (at_ olds i) none "<" (subjectOf (olds[i]?.getD ""))
          i := i + 1
          continue
        while j < news.size && (matches_[j]?.join).isNone do
          pairs := pairs.push { old := none, new := some (j + 1), relation := .added }
          text := text ++ rangeLine width none (at_ news j) ">" (subjectOf (news[j]?.getD ""))
          j := j + 1
        if let some (a, relation) := matches_[j]?.join then
          pairs := pairs.push { old := some (a + 1), new := some (j + 1), relation }
          let mark := if relation == .same then "=" else "!"
          text :=
            text ++ rangeLine width (at_ olds a) (at_ news j) mark (subjectOf (news[j]?.getD ""))
          shown := shown.set! a true
          j := j + 1
      return (pairs, text)
  return { pairs, text }

/-- The change of `revision` against its merge base with `against`
("`changes`", in the module docs), or why it is refused. -/
def changesOf (repository : Repository) (revision against : String) : Except Error Changes := do
  let resolved := repository.resolved
  let new ← resolved revision
  let base ←
    if against.isEmpty then
      pure ""
    else
      let old ← resolved against
      let some base :=
        repository.mergeBase new
          old | throw (.failed (.code 1) s!"{revision} and {against} have no merge base")
      pure base
  let oldFiles := if base.isEmpty then #[] else (repository.filesAt base).getD #[]
  let newFiles := (repository.filesAt new).getD #[]
  let paths :=
    ((oldFiles.map (·.1) ++ newFiles.map (·.1)).qsort fun a b => decide (a < b)).foldl
      (fun (kept : Array String) path => if kept.back? == some path then kept else kept.push path)
      #[]
  return {
      base, tip := new
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
module docs), or why it is refused, as git refuses it. The path `spelled`
is taken as git takes it, made `normal`: a trailing separator or a `..`
names the directory it would on disk. -/
def addingWorktree (repository : Repository) (spelled : System.FilePath) (branch : String)
    (start : Option String) : Except Error Repository := do
  let path := normal spelled
  if
      path == repository.root || repository.linked.any (·.path == path) ||
        repository.occupied.contains path then
    throw (.failed (.code 128) s!"fatal: '{spelled}' already exists")
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
  | .commit message, repository =>
    match repository.committing message with
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
  | request@(.log revision limit), repository =>
    match request.invalid? with
    | some detail => (.error (.invalid detail), repository)
    | none => (repository.logOf revision limit, repository)
  | request@(.blame revision path), repository =>
    match request.invalid? with
    | some detail => (.error (.invalid detail), repository)
    | none => (repository.blameOf revision path, repository)
  | request@(.rangeDiff base old new), repository =>
    match request.invalid? with
    | some detail => (.error (.invalid detail), repository)
    | none => (repository.rangeDiffOf base old new, repository)

/-- The model as an implementation of the port inside a job: each request
answered as `handle` answers it in `repository`, the repository it gives
back dropped. So a read that only asks runs over the model on the job
model, as the review's read does in the model checks
(`Editor/VersionControl/Review.lean`). -/
def readHandler (repository : Repository) : Handler := fun request =>
  pure (handle request repository).1

end Editor.VersionControl.Model

namespace VcApiTest

open Editor

/-- A backend over the model of `repository`: its handler answers every
request from the repository as it is (`Model.readHandler`), whatever
program and root it is connected with, named `git` as the backend a
consumer chooses (`VcApi.connect?`). A consumer's tests register it in
place of an implementation's. -/
def backend (repository : VersionControl.Model.Repository) : VcApi.Backend :=
  { name := VcApi.gitBackendName,
    connect := fun _ _ => VersionControl.Model.readHandler repository }

/-- The values registered at each extension point when `backends` alone
are registered at `VcApi.Backend`: what a test hands a job registered over
the point (`JobRegistration.workWith`) in place of a host's registry. -/
def backendValues (backends : Array VcApi.Backend) (key : Lean.Name) : Array Dynamic :=
  if key == TypeName.typeName VcApi.Backend then backends.map (.mk ·) else #[]

end VcApiTest
