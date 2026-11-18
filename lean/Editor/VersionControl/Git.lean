import Editor.VersionControl
import Editor.VersionControl.Porcelain
import Editor.Workspace

/-!
# The git implementation of the version-control interface

`Git.handler git root` answers each request of the version-control port
(`Editor/VersionControl.lean`) by running `git` in the repository's root as
a job: each run is one `Process.runWithin` (`Editor/Job.lean`), or a fed
`Process.runWithInput` for a hunk and a commit, one for each request but
`fileAt`, which is two, so the child gets its directory's environment, and
is killed with its process group when the job is cancelled. No new binding is needed. Its model is
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
  hook runs could leave `index.lock` behind.

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

/-- The arguments of `watched`. -/
def watchedArguments : Array String :=
  #["rev-parse", "--git-dir", "--git-common-dir"]

/-- The command that runs `git` with `arguments` in `root`. -/
def command (git : String) (root : System.FilePath) (arguments : Array String) : Process.Command :=
  { program := git, arguments, environment, directory := root }

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

end Editor.VersionControl.Git
