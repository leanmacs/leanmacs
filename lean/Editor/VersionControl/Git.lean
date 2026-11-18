import Editor.VersionControl
import Editor.VersionControl.Porcelain
import Editor.Workspace

/-!
# The git implementation of the version-control interface

`Git.handler git root` answers each request of the version-control port
(`Editor/VersionControl.lean`) by running `git` in the repository's root as
a job: each run is one `Process.runWithin` (`Editor/Job.lean`), one for each
request but `fileAt`, which is two, so the
child gets its directory's environment, and is killed with its process
group when the job is cancelled. No new binding is needed. Its model is
`Editor/VersionControl/Model.lean`, and both are held to the contract
(`Editor/VersionControl/Contract.lean`).

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
  `parseStatus` (`Editor/VersionControl/Porcelain.lean`). The contract
  runs this under a config asking for copies and for no untracked files
  (`ContractTest.pinnedAwayConfig`).
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
- **The environment** (`environment`): the editor's, less `GIT_DIR`,
  `GIT_WORK_TREE` and `GIT_INDEX_FILE`, so git answers for the root and its
  own index; with `GIT_OPTIONAL_LOCKS=0`, so a status read never takes the
  index lock, as magit's do, and a read cannot make a stage fail; and with
  `GIT_LITERAL_PATHSPECS=1`, so a path holding `*` or `:` is a path, not a
  pattern.
- **The limits**: `statusOutput` (16 MiB) of each stream and `gitTime`
  (30 s), named constants of policy. A run past either is `couldNotRun`
  with `outputTooLarge` or `timedOut`, never a parse of output cut short.

## The replies

- A run the process service refuses (git is not there, the root is not
  there) is `couldNotRun`.
- A run that exits 0 is read: a status by the parser, whose refusal is
  `unparsable`; a write is a success. A `fileAt`'s first run that exits 1
  is `none`.
- Any other exit, or a signal, is `failed`, with git's standard error,
  decoded by the store's escape rule (`File.decodeBytes`).
-/

namespace Editor.VersionControl.Git

/-- The most bytes of each stream a git run may write: 16 MiB. -/
def statusOutput : Nat :=
  16 * 1024 * 1024

/-- How long a git run may take, in milliseconds. -/
def gitTime : Nat :=
  30000

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

/-- The arguments of `watched`. -/
def watchedArguments : Array String :=
  #["rev-parse", "--git-dir", "--git-common-dir"]

/-- The command that runs `git` with `arguments` in `root`. -/
def command (git : String) (root : System.FilePath) (arguments : Array String) : Process.Command :=
  { program := git, arguments, environment, directory := root }

/-- Runs `git` with `arguments` in `root`, under the limits: the run, when it
exited 0, or why not ("The replies", in the module docs). -/
def run (git : String) (root : System.FilePath) (arguments : Array String) :
    JobM (Except Error Process.Ran) := do
  match ← Process.runWithin (command git root arguments) statusOutput gitTime with
  | .error error =>
    return .error (.couldNotRun error)
  | .ok ran =>
    match ran.exit with
    | .code 0 =>
      return .ok ran
    | exit =>
      return .error (.failed exit (File.decodeBytes ran.stderr).trimAsciiEnd.toString)

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
    .ok
      { directory := commonDir, paths := #[gitDir / "HEAD", gitDir / "index", commonDir / "packed-refs"]
        trees := #[commonDir / "refs"] }
  | _ => .error (.unparsable s!"rev-parse printed {lines.length} lines, not two")

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

end Editor.VersionControl.Git
