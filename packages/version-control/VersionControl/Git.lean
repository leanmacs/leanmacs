import Editor.Workspace
import VcApi
import VersionControl.HistoryRead
import VersionControl.Plumbing
import VersionControl.Porcelain

/-!
# The git implementation of the version-control interface

`Git.handler git root` answers each request of the version-control port
(`Editor/VersionControl.lean`) by running `git` in the repository's root as
a job: each run is one `Process.runWithin` (`Editor/Job.lean`), or a fed
`Process.runWithInput` for a hunk, a commit, a change's blobs and the empty
tree, one for each request but `fileAt`, which is two, `changes`, which is
five, or four against no base, `addWorktree`, which is up to three, `log`,
which is two, `blame`, which is up to three, and `rangeDiff`, which is
four, so the child gets its directory's environment, and
is killed with its process group when the job is cancelled. No new binding is needed. Its model is
`VersionControl/Model.lean`, and both are held to the contract
(`VersionControl/Contract.lean`).

## The command lines

git runs under the user's config, so each flag pins what that config could
change:

- **status**: `git -c status.renames=true -c diff.renames=true status
  --porcelain=v2 -z --branch --untracked-files=all --find-renames`.
  `--find-renames` turns renames on, but leaves copies as the config says,
  and a config of `copies` would make git print copy records; the two `-c`
  pin rename detection at renames, never copies, for each key that can
  set it (`status.renames`, and `diff.renames`, which status reads when
  the first is not set). A `-c` outranks every config file. `-z` ends each
  record with a NUL and never quotes a path; `--branch` adds the headers
  that say what is checked out; `--untracked-files=all` lists untracked
  files one per file, so the status buffer has one line per file. Read by
  `parseStatus` (`VersionControl/Porcelain.lean`). The contract
  runs this under a config asking for copies and for no untracked files
  (`VersionControlTest.Linked.pinnedAwayConfig`).
- **stage**: `git add --all -- <paths>`: a path that is gone is removed
  from the index, and a conflict is resolved.
- **unstage**: `git reset -q -- <paths>`, which works on an unborn branch,
  where `git restore --staged` does not.
- **fileAt**: two plumbing runs, not `git show`. First `git rev-parse
  --verify --quiet <revision>:<path>`, which exits 1 and says nothing when
  the revision does not have the path or is not there: that is `none`.
  Otherwise it prints the object's id, and `git cat-file blob <id>` prints
  its bytes, which are decoded by the store's escape rule
  (`File.decodeBytes`); a directory's id is a tree, which `cat-file blob`
  refuses, so a directory is `failed`. `git show` is not used: its failure
  for a missing path cannot be told from a bad revision but by its
  message, and on a blob it applies a user's `textconv` filter, which
  plumbing never does. The empty revision is `:<path>`, the index.
- **watched**: `git rev-parse --git-dir --git-common-dir`, two lines, each
  resolved against the root when relative, so both are spelled as the root
  is. The answer is the common directory, with `HEAD` and `index` of the
  git directory (a linked worktree's own, under the common one),
  `packed-refs` of the common directory, and its `refs` as a tree.
  Output that is not two lines is `unparsable`.
- **stageHunk**: `git -c apply.whitespace=nowarn -c
  apply.ignoreWhitespace=false apply --cached -`, fed the hunk's patch
  (`patch`). The two `-c` pin what a user's config could change:
  `apply.whitespace=fix` would rewrite trailing spaces and a carriage
  return on added lines, and `apply.ignoreWhitespace=change` would match
  context loosely. Never `--unidiff-zero`, `--recount`, `-C<n>` or
  `--3way`: every context line must match the index exactly, or git
  refuses and the index is untouched, the main guard against a wrong
  patch. `--cached` never touches the working tree.
- **unstageHunk**: the same with `--reverse`, fed the patch of the hunk of
  the index against `HEAD`, so git matches its `+` side, the context and
  the index's lines, against the index.
- **commit**: `git commit --file=- --cleanup=whitespace`, fed the message:
  never an argument, so no length limit and no leading `-` read as an
  option, and no temporary file. `--cleanup=whitespace` is git's own
  default for a message from a file; pinning it stops a user's
  `commit.cleanup=strip` from dropping a line that starts with `#`.
- **worktrees**: `git worktree list --porcelain -z` (git 2.36 and later),
  which never quotes a path, read by `parseWorktrees`
  (`VersionControl/Plumbing.lean`): a bare main repository is
  dropped, the linked worktrees sorted by path after the first.
- **branches**: `git for-each-ref --format=%(refname) refs/heads/`, each
  full name with `refs/heads/` stripped (`parseBranches`), never
  `%(refname:short)`, which git shortens differently when a tag shares a
  branch's name.
- **changes**: `git rev-parse --verify --quiet <name>^{commit}` for each
  name, so the merge base and the diff are of one pair of commits even if
  a branch moves meanwhile; an exit of 1 is `<name> is not a commit`, with
  status 1, as the model refuses it. Then `git merge-base <R> <A>`, whose
  exit of 1 with nothing said is `<revision> and <against> have no merge
  base`; `git diff-tree -r -z --no-renames <M> <R>`, plumbing, so no
  textconv, external diff or colour, with `--no-renames` pinning it against
  `diff.renames=copies` (`parseRawDiff`, which drops a change of mode
  alone); and one `git cat-file --batch` fed each distinct blob id a line,
  without `--textconv` or `--filters`, so it prints raw blobs, read by
  their sizes (`parseBatch`). Its output must name every id asked for, as
  a blob, or the change is `unparsable`. A submodule's side is never read:
  it is `Subproject commit <id>`. Each content is decoded by the store's
  escape rule.
- **changes against no base** (an empty `against`): the revision resolved,
  then `git hash-object -t tree --stdin` fed nothing, which prints the
  empty tree's id in the repository's own hash, then the raw diff of the
  revision against it and the batch as above; there is no merge base, and
  the reply's base is empty. The reply's tip is always the revision's
  resolved id.
- **log**: the revision resolved as `changes` resolves a name, so a
  refusal reads the same, then `git rev-list --first-parent
  --max-count=<limit> --no-commit-header --encoding=UTF-8
  --format=%H%x00%P%x00%an%x00%at%x00%s <id> --`, read by `parseLog`
  (`VersionControl/HistoryRead.lean`). `rev-list` is plumbing, so no
  `log.*` config (`log.showSignature`, `log.mailmap`, `log.decorate`)
  applies; `--no-commit-header` (git 2.33) leaves only the format, and
  `--encoding=UTF-8` pins `i18n.logOutputEncoding`.
- **blame**: the revision resolved, then `git rev-parse --verify --quiet
  <id>:<path>`, whose exit of 1 is `none`, then `git blame --porcelain
  --ignore-revs-file= <id> -- <path>`, read by `parseBlame`. The empty
  `--ignore-revs-file=` clears a user's `blame.ignoreRevsFile`, which
  would hand an ignored commit's lines to its parents.
- **rangeDiff**: each of its three names resolved, then `git range-diff
  --no-color --no-notes --creation-factor=60 <base> <old> <new>` on the
  ids, git's three-argument form, `<base>..<old>` against `<base>..<new>`,
  read by `parseRangeDiff`. `--no-color` and `--no-notes` pin its text, and
  `--creation-factor=60` pins git's default.
- **addWorktree**: `git rev-parse --verify --quiet refs/heads/<branch>`
  first. With a start, its exit of 0 is refused (128, `a branch named
  '<branch>' already exists`); without one, its exit of 1 is refused (128)
  as an invalid reference: `git worktree add <path> <name>` would
  otherwise detach at a tag or a commit of that name, or make a branch
  from a remote one. Then `git worktree add --quiet -b <branch> <path>
  <start>`, or `git worktree add --quiet <path> <branch>`. git makes a new
  branch before it checks the path, so when `-b` exits non-zero, `git
  branch -D <branch>` deletes what it made, and the reply is git's
  refusal: the branch was not there before, and `-D` refuses a branch a
  worktree has checked out, such as one whose `post-checkout` hook
  failed. This holds whatever spelling of the path git refuses (a trailing
  separator, a `..`, a link) and a non-empty directory, without the
  implementation resolving paths itself. A run that could not finish
  (timed out or cancelled) deletes nothing.
- **removeWorktree**: `git -c status.showUntrackedFiles=normal worktree
  remove <path>`. Under a user's `status.showUntrackedFiles=no`, git would
  not see an untracked file, and would delete it with the worktree.
- **Before any run**, `Request.invalid?` refuses a name that starts with
  `-` and a relative worktree path, so no name is read as an option.
- **The patch** (`patch path hunk reverse`) is pure: a `diff --git` header
  and `---`/`+++` lines naming the path C-quoted (`quoted`), always, so a
  space, a quote or a byte past ASCII reads back as itself; one `@@ -o,oc
  +n,nc @@` line, a side's start its row plus one, or the row itself when
  its count is 0 (`-0,0` for an empty index file), as git prints it; then
  the context before, the removed lines, the added lines and the context
  after, each line that lacks a line feed followed by `\ No newline at end
  of file`. For staging `n` is `o`, since nothing before the hunk changes;
  for unstaging `n` is the index's row. Its text is turned back into bytes
  by the store's rule (`File.encodeText`), so an escape is its byte again.
- **The environment** (`environment`): the editor's, less `GIT_DIR`,
  `GIT_WORK_TREE` and `GIT_INDEX_FILE`, so git answers for the root and its
  own index; with `GIT_OPTIONAL_LOCKS=0`, so a status read never takes the
  index lock, as magit's do, and a read cannot make a stage fail; and with
  `GIT_LITERAL_PATHSPECS=1`, so a path holding `*` or `:` is a path, not a
  pattern.
  A commit runs under `commitEnvironment`, the same less
  `GIT_LITERAL_PATHSPECS`: git hands its environment to hooks, and a hook
  running `git diff -- '*.rs'` must see a pattern. A commit passes no
  pathspec, so nothing is lost.
- **The limits**: `statusOutput` (16 MiB) of each stream and `gitTime`
  (30 s), named constants of policy. A run past either is `couldNotRun`
  with `outputTooLarge` or `timedOut`, never a parse of output cut short.
  A commit has `commitTime` (10 minutes) in place of `gitTime`, because a
  pre-commit hook may run linters or tests, and a commit killed while its
  hook runs could leave `index.lock` behind. Making and removing a
  worktree run under `commitEnvironment` and `worktreeTime` (10 minutes):
  checking out a large tree takes time, and git runs the `post-checkout`
  hook, which must see pathspecs as patterns. A change's streams are held
  to `statusOutput` too, so its contents together are; past it the change
  could not run, never a partial one.

## The replies

- A run the process service refuses (git is not there, the root is not
  there) is `couldNotRun`.
- A run that exits 0 is read: a status by the parser, whose refusal is
  `unparsable`; a write is a success. A `fileAt`'s first run that exits 1
  is `none`.
- Any other exit, or a signal, is `failed`, with git's standard error,
  decoded by the store's escape rule (`File.decodeBytes`). A refused commit
  is `failed` with its standard error and then its standard output: git
  says `nothing to commit` on its standard output, and sends a hook's
  standard output to its standard error.
-/

namespace Editor.VersionControl.Git

/-- The most bytes of each stream a git run may write: 16 MiB. -/
def statusOutput : Nat :=
  16 * 1024 * 1024

/-- How long a git run may take, in milliseconds. -/
def gitTime : Nat :=
  30000

/-- How long a commit may take, in milliseconds: 10 minutes, for a hook that
runs linters or tests. -/
def commitTime : Nat :=
  600000

/-- How long making or removing a worktree may take, in milliseconds: 10
minutes, for checking out a large tree and its `post-checkout` hook. -/
def worktreeTime : Nat :=
  600000

/-- The environment of every git run: the editor's, with `GIT_DIR`,
`GIT_WORK_TREE` and `GIT_INDEX_FILE` removed, so git answers for the
directory it runs in and its own index, with `GIT_OPTIONAL_LOCKS=0`, so a
read never takes the index lock, and with `GIT_LITERAL_PATHSPECS=1`, so a
path is never read as a pattern. -/
def environment : Process.Environment :=
  { unset := Workspace.Git.environment.unset.push "GIT_INDEX_FILE"
    set := #[("GIT_OPTIONAL_LOCKS", "0"), ("GIT_LITERAL_PATHSPECS", "1")] }

/-- The arguments of a status read, rename detection pinned at renames
("The command lines", in the module docs). -/
def statusArguments : Array String :=
  #["-c", "status.renames=true", "-c", "diff.renames=true", "status", "--porcelain=v2", "-z",
    "--branch", "--untracked-files=all", "--find-renames"]

/-- The environment of a commit: `environment` less `GIT_LITERAL_PATHSPECS`,
which git would hand its hooks ("The command lines", in the module docs). -/
def commitEnvironment : Process.Environment :=
  { environment with set := environment.set.filter (·.1 != "GIT_LITERAL_PATHSPECS") }

/-- The arguments of a hunk's apply to the index, fed its patch: reversed for
an unstage. -/
def applyArguments (reverse : Bool) : Array String :=
  #["-c", "apply.whitespace=nowarn", "-c", "apply.ignoreWhitespace=false", "apply", "--cached"] ++
    (if reverse then #["--reverse"] else #[]) ++
    #["-"]

/-- The arguments of a commit, fed its message. -/
def commitArguments : Array String :=
  #["commit", "--file=-", "--cleanup=whitespace"]

/-- The three octal digits of `byte`. -/
def octal (byte : UInt8) : String :=
  let digit (value : Nat) : Char := Char.ofNat (48 + value % 8)
  String.ofList [digit (byte.toNat / 64), digit (byte.toNat / 8), digit byte.toNat]

/-- `path` C-quoted, as git reads a quoted path in a patch: in double quotes,
with `\"` and `\\` escaped, and each control byte and each byte past ASCII
as a backslash and three octal digits. -/
def quoted (path : String) : String :=
  let body :=
    path.toUTF8.foldl
      (fun (out : String) byte =>
        if byte == 34 then out ++ "\\\""
        else
          if byte == 92 then out ++ "\\\\"
          else
            if byte < 32 || byte ≥ 127 then out ++ "\\" ++ octal byte
            else out.push (Char.ofNat byte.toNat))
      ""
  "\"" ++ body ++ "\""

/-- The patch of `hunk` of `path`, reversed for an unstage ("The patch", in
the module docs). -/
def patch (path : String) (hunk : LineHunk) (reverse : Bool) : String :=
  let oldCount := hunk.before.size + hunk.removed.size + hunk.after.size
  let newCount := hunk.before.size + hunk.added.size + hunk.after.size
  let startOf (row count : Nat) : Nat := if count == 0 then row else row + 1
  let oldStart := startOf hunk.oldLine oldCount
  let newStart := startOf (if reverse then hunk.newLine else hunk.oldLine) newCount
  let line (mark : String) (text : String) : String :=
    mark ++ text ++ if text.endsWith "\n" then "" else "\n\\ No newline at end of file\n"
  let (a, b) := (quoted s!"a/{path}", quoted s!"b/{path}")
  s!"diff --git {a} {b}\n--- {a}\n+++ {b}\n@@ -{oldStart},{oldCount} +{newStart},{newCount} @@\n" ++
    String.join (hunk.before.map (line " ")).toList ++
    String.join (hunk.removed.map (line "-")).toList ++
    String.join (hunk.added.map (line "+")).toList ++
    String.join (hunk.after.map (line " ")).toList

/-- The arguments that stage `paths`. -/
def stageArguments (paths : Array String) : Array String :=
  #["add", "--all", "--"] ++ paths

/-- The arguments that unstage `paths`. -/
def unstageArguments (paths : Array String) : Array String :=
  #["reset", "-q", "--"] ++ paths

/-- The arguments of the first run of a `fileAt`: the id of `path` at
`revision`, or an exit of 1 when it has none. -/
def revisionArguments (revision path : String) : Array String :=
  #["rev-parse", "--verify", "--quiet", s!"{revision}:{path}"]

/-- The arguments of the second run of a `fileAt`: the bytes of the blob
`id`. -/
def blobArguments (id : String) : Array String :=
  #["cat-file", "blob", id]

/-- The arguments of the worktree list read. -/
def worktreeListArguments : Array String :=
  #["worktree", "list", "--porcelain", "-z"]

/-- The arguments of the branch list read. -/
def branchArguments : Array String :=
  #["for-each-ref", "--format=%(refname)", "refs/heads/"]

/-- The arguments that resolve `name` to a commit's id, or exit 1 when it
names none. -/
def resolveArguments (name : String) : Array String :=
  #["rev-parse", "--verify", "--quiet", s!"{name}^\{commit}"]

/-- The arguments of a merge base's read: the merge base of the commits `a`
and `b`. -/
def mergeBaseArguments (a b : String) : Array String :=
  #["merge-base", a, b]

/-- The arguments of a raw diff of the commit `new` against `old`, renames
off. -/
def diffTreeArguments (old new : String) : Array String :=
  #["diff-tree", "-r", "-z", "--no-renames", old, new]

/-- The arguments of a batch read of blobs, fed their ids, one a line. -/
def batchArguments : Array String :=
  #["cat-file", "--batch"]

/-- The format of a log's records: the id, the parents, the author's name,
the author time and the subject, separated by NULs. -/
def logFormat : String :=
  "--format=%H%x00%P%x00%an%x00%at%x00%s"

/-- The arguments of a log of the commit `id`, along first parents, at most
`limit` commits. -/
def logArguments (id : String) (limit : Nat) : Array String :=
  #["rev-list", "--first-parent", s!"--max-count={limit}", "--no-commit-header", "--encoding=UTF-8",
    logFormat, id, "--"]

/-- The arguments of a blame of `path` at the commit `id`, a user's
`blame.ignoreRevsFile` cleared. -/
def blameArguments (id path : String) : Array String :=
  #["blame", "--porcelain", "--ignore-revs-file=", id, "--", path]

/-- The arguments of a range-diff of `base..old` against `base..new`, each a
commit's id. -/
def rangeDiffArguments (base old new : String) : Array String :=
  #["range-diff", "--no-color", "--no-notes", "--creation-factor=60", base, old, new]

/-- The arguments that print the id of the empty tree, fed nothing. -/
def emptyTreeArguments : Array String :=
  #["hash-object", "-t", "tree", "--stdin"]

/-- The arguments that check that a local branch named `branch` exists. -/
def branchExistsArguments (branch : String) : Array String :=
  #["rev-parse", "--verify", "--quiet", s!"refs/heads/{branch}"]

/-- The arguments that delete the local branch `branch`, which git refuses
while a worktree has it checked out. -/
def deleteBranchArguments (branch : String) : Array String :=
  #["branch", "-D", branch]

/-- The arguments that make a worktree at `path` on `branch`: a new branch
at `start`, or the existing branch. -/
def addWorktreeArguments (path : System.FilePath) (branch : String) : Option String → Array String
  | some start => #["worktree", "add", "--quiet", "-b", branch, path.toString, start]
  | none => #["worktree", "add", "--quiet", path.toString, branch]

/-- The arguments that remove the linked worktree at `path`, untracked files
pinned visible: under a user's `status.showUntrackedFiles=no`, git would
not see an untracked file and would delete it with the worktree. -/
def removeWorktreeArguments (path : System.FilePath) : Array String :=
  #["-c", "status.showUntrackedFiles=normal", "worktree", "remove", path.toString]

/-- The arguments of `watched`. -/
def watchedArguments : Array String :=
  #["rev-parse", "--git-dir", "--git-common-dir"]

/-- The command that runs `git` with `arguments` in `root`. -/
def command (git : String) (root : System.FilePath) (arguments : Array String) : Process.Command :=
  { program := git, arguments, environment, directory := root }

/-- The command that makes or removes a worktree from `root` with
`arguments`, under `commitEnvironment`, since git runs the `post-checkout`
hook. -/
def worktreeCommand (git : String) (root : System.FilePath) (arguments : Array String) :
    Process.Command :=
  { program := git, arguments, environment := commitEnvironment, directory := root }

/-- The command that commits in `root`, under `commitEnvironment`. -/
def commitCommand (git : String) (root : System.FilePath) : Process.Command :=
  { program := git, arguments := commitArguments, environment := commitEnvironment
    directory := root }

/-- `bytes` decoded by the store's escape rule, with trailing white space
dropped. -/
def said (bytes : ByteArray) : String :=
  (File.decodeBytes bytes).trimAsciiEnd.toString

/-- What a run came to: the run, when it exited 0, or why not, a refusal
saying what `message` takes of the run ("The replies", in the module
docs). -/
def outcome (reply : Except ProcessError Process.Ran)
    (message : Process.Ran → String := fun ran => said ran.stderr) : Except Error Process.Ran :=
  match reply with
  | .error error => .error (.couldNotRun error)
  | .ok ran =>
    match ran.exit with
    | .code 0 => .ok ran
    | exit => .error (.failed exit (message ran))

/-- Runs `git` with `arguments` in `root`, under the limits: the run, when it
exited 0, or why not ("The replies", in the module docs). -/
def run (git : String) (root : System.FilePath) (arguments : Array String) :
    JobM (Except Error Process.Ran) := do
  return outcome (← Process.runWithin (command git root arguments) statusOutput gitTime)

/-- A refused commit's message: its standard error, then its standard output,
each when it said something. -/
def bothSaid (ran : Process.Ran) : String :=
  "\n".intercalate ([said ran.stderr, said ran.stdout].filter (!·.isEmpty))

/-- What a write's run came to: a success, or why not. -/
def written (ran : Except Error Process.Ran) : Except Error Unit :=
  ran.map fun _ => ()

/-- What `git rev-parse --git-dir --git-common-dir` printed in `root`, read
("The command lines", in the module docs). -/
def watchedOf (root : System.FilePath) (stdout : ByteArray) : Except Error Watched :=
  let lines := ((File.decodeBytes stdout).splitOn "\n").filter (!·.isEmpty)
  match lines with
  | [gitDir, commonDir] =>
    let resolved (path : String) : System.FilePath :=
      if (path : System.FilePath).isAbsolute then path else root / path
    let (gitDir, commonDir) := (resolved gitDir, resolved commonDir)
    .ok {
        directory := commonDir,
        paths := #[gitDir / "HEAD", gitDir / "index", commonDir / "packed-refs"]
        trees := #[commonDir / "refs"] }
  | _ => .error (.unparsable s!"rev-parse printed {lines.length} lines, not two")

/-- The commit id `name` names, through `rev-parse`, or the refusal of a name
that names none ("`changes`", in the module docs). -/
def resolveIn (git : String) (root : System.FilePath) (name : String) :
    JobM (Except Error String) := do
  match ← run git root (resolveArguments name) with
  | .error (.failed (.code 1) _) =>
    return .error (.failed (.code 1) s!"{name} is not a commit")
  | .error error =>
    return .error error
  | .ok ran =>
    let id := (File.decodeBytes ran.stdout).trimAscii.toString
    return if id.isEmpty then .error (.unparsable "rev-parse printed no object id") else .ok id

/-- The ids of the blobs `changes` reads, each once, in order: every side of
a change that is there and is not a submodule's commit. -/
def blobIds (changes : Array Plumbing.RawChange) : Array String :=
  (changes.flatMap fun change =>
        #[(change.oldMode, change.oldId), (change.newMode, change.newId)]).foldl
    (fun (ids : Array String) (mode, id) =>
      if mode == Plumbing.absentMode || mode == Plumbing.gitlinkMode || ids.contains id then ids
      else ids.push id)
    #[]

/-- The content of a side of a change, its mode `mode` and its id `id`, from
the blobs read: `none` where the side lacks the path, and a submodule's
commit as git prints it. -/
def sideContent (blobs : Array (String × ByteArray)) (mode id : String) :
    Except Error (Option String) :=
  if mode == Plumbing.absentMode then .ok none
  else
    if mode == Plumbing.gitlinkMode then .ok (some s!"Subproject commit {id}\n")
    else
      match blobs.find? (·.1 == id) with
      | some (_, bytes) => .ok (some (File.decodeBytes bytes))
      | none => .error (.unparsable s!"cat-file did not print {id}")

/-- The contents of `changes`' blobs, read with one `cat-file --batch`: none
is run when there are none. -/
def readBlobs (git : String) (root : System.FilePath) (changes : Array Plumbing.RawChange) :
    JobM (Except Error (Array (String × ByteArray))) := do
  let ids := blobIds changes
  if ids.isEmpty then
    return .ok #[]
  let fed := String.join (ids.toList.map (· ++ "\n")) |>.toUTF8
  match
    outcome (← Process.runWithInput (command git root batchArguments) fed statusOutput gitTime) with
  | .error error =>
    return .error error
  | .ok ran =>
    return (Plumbing.parseBatch ran.stdout).mapError .unparsable

/-- The id of the empty tree in the repository at `root`, in its own hash
("`changes`", in the module docs). -/
def emptyTreeIn (git : String) (root : System.FilePath) : JobM (Except Error String) := do
  match
    outcome
      (←
        Process.runWithInput (command git root emptyTreeArguments) .empty statusOutput gitTime) with
  | .error error =>
    return .error error
  | .ok ran =>
    let id := (File.decodeBytes ran.stdout).trimAscii.toString
    return if id.isEmpty then .error (.unparsable "hash-object printed no object id") else .ok id

/-- The change of `revision` against its merge base with `against`, or
against no base when `against` is empty ("`changes`", in the module
docs). -/
def changesIn (git : String) (root : System.FilePath) (revision against : String) :
    JobM (Except Error Changes) := do
  let new ←
    match ← resolveIn git root revision with
    | .ok id =>
      pure id
    | .error error =>
      return .error error
  let (base, from_) ←
    if against.isEmpty then
      match ← emptyTreeIn git root with
      | .ok empty =>
        pure ("", empty)
      | .error error =>
        return .error error
    else
      let old ←
        match ← resolveIn git root against with
        | .ok id =>
          pure id
        | .error error =>
          return .error error
      match ← run git root (mergeBaseArguments new old) with
      | .error (.failed (.code 1) "") =>
        return .error (.failed (.code 1) s!"{revision} and {against} have no merge base")
      | .error error =>
        return .error error
      | .ok ran =>
        let base := (File.decodeBytes ran.stdout).trimAscii.toString
        if base.isEmpty then
          return .error (.unparsable "merge-base printed no object id")
        pure (base, base)
  let raw ←
    match ← run git root (diffTreeArguments from_ new) with
    | .error error =>
      return .error error
    | .ok ran =>
      match Plumbing.parseRawDiff ran.stdout with
      | .ok raw =>
        pure raw
      | .error why =>
        return .error (.unparsable why)
  let blobs ←
    match ← readBlobs git root raw with
    | .ok blobs =>
      pure blobs
    | .error error =>
      return .error error
  let files ←
    match
      raw.mapM fun change => do
        return ({
              path := change.path, old := ← sideContent blobs change.oldMode change.oldId
              new := ← sideContent blobs change.newMode change.newId } :
            FileChange) with
    | .ok files =>
      pure files
    | .error error =>
      return .error error
  return .ok { base, tip := new, files := files.qsort fun a b => decide (a.path < b.path) }

/-- What a run that printed `ran` reads as by `parse`, or `unparsable`. -/
def parsed {α : Type} (parse : ByteArray → Except String α) (ran : Except Error Process.Ran) :
    Except Error α :=
  ran.bind fun ran => (parse ran.stdout).mapError .unparsable

/-- The log of `revision` ("`log`", in the module docs). -/
def logIn (git : String) (root : System.FilePath) (revision : String) (limit : Nat) :
    JobM (Except Error (Array LogEntry)) := do
  match ← resolveIn git root revision with
  | .error error =>
    return .error error
  | .ok id =>
    return parsed HistoryRead.parseLog (← run git root (logArguments id limit))

/-- The blame of `path` at `revision` ("`blame`", in the module docs). -/
def blameIn (git : String) (root : System.FilePath) (revision path : String) :
    JobM (Except Error (Option Blame)) := do
  let id ←
    match ← resolveIn git root revision with
    | .ok id =>
      pure id
    | .error error =>
      return .error error
  match ← run git root (revisionArguments id path) with
  | .error (.failed (.code 1) _) =>
    return .ok none
  | .error error =>
    return .error error
  | .ok _ =>
    return (parsed HistoryRead.parseBlame (← run git root (blameArguments id path))).map some

/-- The range-diff of `base..old` against `base..new` ("`rangeDiff`", in the
module docs). -/
def rangeDiffIn (git : String) (root : System.FilePath) (base old new : String) :
    JobM (Except Error RangeDiff) := do
  let mut ids := #[]
  for name in [base, old, new] do
    match ← resolveIn git root name with
    | .ok id =>
      ids := ids.push id
    | .error error =>
      return .error error
  let (base, old, new) := (ids[0]!, ids[1]!, ids[2]!)
  return parsed HistoryRead.parseRangeDiff (← run git root (rangeDiffArguments base old new))

/-- Makes a worktree ("`addWorktree`", in the module docs): first checks
whether `branch` is a local branch, refusing a new branch that is one, or
an existing branch that is not, before `git worktree add` runs; and when
git refuses to make a new branch's worktree, deletes the branch git made
before it refused. -/
def addWorktreeIn (git : String) (root : System.FilePath) (path : System.FilePath) (branch : String)
    (start : Option String) : JobM (Except Error Unit) := do
  let isBranch ←
    match ← run git root (branchExistsArguments branch) with
    | .error (.failed (.code 1) _) =>
      pure false
    | .error error =>
      return .error error
    | .ok _ =>
      pure true
  match start, isBranch with
  | some _, true =>
    return .error (.failed (.code 128) s!"fatal: a branch named '{branch}' already exists")
  | none, false =>
    return .error (.failed (.code 128) s!"fatal: invalid reference: {branch}")
  | _, _ =>
    pure ()
  let made :=
    outcome
      (←
        Process.runWithin (worktreeCommand git root (addWorktreeArguments path branch start))
            statusOutput worktreeTime)
  if start.isSome && made matches .error (.failed ..) then
    discard <| run git root (deleteBranchArguments branch)
  return written made

/-- The git implementation, running `git` in `root` ("The command lines",
"The replies", in the module docs). -/
def handler (git : String) (root : System.FilePath) : Handler
  | .status => do
    match ← run git root statusArguments with
    | .error error =>
      return .error error
    | .ok ran =>
      match Porcelain.parseStatus ran.stdout with
      | .ok read =>
        return .ok read
      | .error why =>
        return .error (.unparsable why)
  | .stage paths => do
    return written (← run git root (stageArguments paths))
  | .unstage paths => do
    return written (← run git root (unstageArguments paths))
  | .fileAt revision path => do
    match ← run git root (revisionArguments revision path) with
    | .error (.failed (.code 1) _) =>
      return .ok none
    | .error error =>
      return .error error
    | .ok found =>
      let id := (File.decodeBytes found.stdout).trimAscii.toString
      if id.isEmpty then
        return .error (.unparsable "rev-parse printed no object id")
      match ← run git root (blobArguments id) with
      | .error error =>
        return .error error
      | .ok blob =>
        return .ok (some (File.decodeBytes blob.stdout))
  | .watched => do
    match ← run git root watchedArguments with
    | .error error =>
      return .error error
    | .ok ran =>
      return watchedOf root ran.stdout
  | .stageHunk path hunk => do
    let fed := File.encodeText (patch path hunk false)
    return written
        (outcome
          (←
            Process.runWithInput (command git root (applyArguments false)) fed statusOutput
                gitTime))
  | .unstageHunk path hunk => do
    let fed := File.encodeText (patch path hunk true)
    return written
        (outcome
          (←
            Process.runWithInput (command git root (applyArguments true)) fed statusOutput gitTime))
  | .commit message => do
    return written
        (outcome
          (←
            Process.runWithInput (commitCommand git root) (File.encodeText message) statusOutput
                commitTime)
          bothSaid)
  | .worktrees => do
    match ← run git root worktreeListArguments with
    | .error error =>
      return .error error
    | .ok ran =>
      return (Plumbing.parseWorktrees ran.stdout).mapError .unparsable
  | .branches => do
    match ← run git root branchArguments with
    | .error error =>
      return .error error
    | .ok ran =>
      return (Plumbing.parseBranches ran.stdout).mapError .unparsable
  | request@(.changes revision against) => do
    match request.invalid? with
    | some detail =>
      return .error (.invalid detail)
    | none =>
      changesIn git root revision against
  | request@(.addWorktree path branch start) => do
    match request.invalid? with
    | some detail =>
      return .error (.invalid detail)
    | none =>
      addWorktreeIn git root path branch start
  | request@(.removeWorktree path) => do
    match request.invalid? with
    | some detail =>
      return .error (.invalid detail)
    | none =>
      return written
          (outcome
            (←
              Process.runWithin (worktreeCommand git root (removeWorktreeArguments path))
                  statusOutput worktreeTime))
  | request@(.log revision limit) => do
    match request.invalid? with
    | some detail =>
      return .error (.invalid detail)
    | none =>
      logIn git root revision limit
  | request@(.blame revision path) => do
    match request.invalid? with
    | some detail =>
      return .error (.invalid detail)
    | none =>
      blameIn git root revision path
  | request@(.rangeDiff base old new) => do
    match request.invalid? with
    | some detail =>
      return .error (.invalid detail)
    | none =>
      rangeDiffIn git root base old new

end Editor.VersionControl.Git
