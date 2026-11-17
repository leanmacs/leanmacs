import Editor.VersionControl
import Editor.VersionControl.Porcelain
import Editor.Workspace

/-!
# The git implementation of the version-control interface

`Git.handler git root` answers each request of the version-control port
(`Editor/VersionControl.lean`) by running `git` in the repository's root as
a job: each request is one `Process.runWithin` (`Editor/Job.lean`), so the
child gets its directory's environment, and is killed with its process
group when the job is cancelled. No new binding is needed. Its model is
`Editor/VersionControl/Model.lean`, and both are held to the contract
(`Editor/VersionControl/Contract.lean`).

## The command lines

Each flag pins what a user's config could change:

- **status**: `git status --porcelain=v2 -z --branch
  --untracked-files=all --find-renames`. `-z` ends each record with a NUL
  and never quotes a path; `--branch` adds the headers that say what is
  checked out; `--untracked-files=all` lists untracked files one per file,
  so the status buffer has one line per file; `--find-renames` turns
  renames on whatever `status.renames` says. Read by `parseStatus`
  (`Editor/VersionControl/Porcelain.lean`).
- **stage**: `git add --all -- <paths>`: a path that is gone is removed
  from the index, and a conflict is resolved.
- **unstage**: `git reset -q -- <paths>`, which works on an unborn branch,
  where `git restore --staged` does not.
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
  `unparsable`; a write is a success.
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

/-- The arguments of a status read. -/
def statusArguments : Array String :=
  #["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--find-renames"]

/-- The arguments that stage `paths`. -/
def stageArguments (paths : Array String) : Array String :=
  #["add", "--all", "--"] ++ paths

/-- The arguments that unstage `paths`. -/
def unstageArguments (paths : Array String) : Array String :=
  #["reset", "-q", "--"] ++ paths

/-- The arguments of `request`. -/
def arguments : Request → Array String
  | .status => statusArguments
  | .stage paths => stageArguments paths
  | .unstage paths => unstageArguments paths

/-- The command that runs `git` with the arguments of `request` in `root`. -/
def command (git : String) (root : System.FilePath) (request : Request) : Process.Command :=
  { program := git, arguments := arguments request, environment, directory := root }

/-- Runs `git` with the arguments of `request` in `root`, under the limits:
the run, when it exited 0, or why not ("The replies", in the module docs). -/
def run (git : String) (root : System.FilePath) (request : Request) :
    JobM (Except Error Process.Ran) := do
  match ← Process.runWithin (command git root request) statusOutput gitTime with
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

/-- The git implementation, running `git` in `root` ("The command lines",
"The replies", in the module docs). -/
def handler (git : String) (root : System.FilePath) : Handler
  | .status => do
    match ← run git root .status with
    | .error error =>
      return .error error
    | .ok ran =>
      match Porcelain.parseStatus ran.stdout with
      | .ok read =>
        return .ok read
      | .error why =>
        return .error (.unparsable why)
  | .stage paths => do
    return written (← run git root (.stage paths))
  | .unstage paths => do
    return written (← run git root (.unstage paths))

end Editor.VersionControl.Git
