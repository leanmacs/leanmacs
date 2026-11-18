import ContractTest.Support.Jobs
import ContractTest.Support.Trees
import Editor.Job
import Editor.Job.Runner
import Editor.Process
import Editor.Program
import Editor.VersionControl
import Editor.VersionControl.Git
import Editor.VersionControl.Model

/-!
# Contract tests: support: Git

Real git and the processes the checks run: a command with its own `PATH`, git
isolated from the user's configuration, the environment of the runs that write a
repository out, a configured repository, and its status. Shared by several test
modules; it holds no checks of its own.
-/

namespace ContractTest

open Editor

/-- `command` with `PATH` set to `path` in its own environment, in place of
any `PATH` it sets. -/
def withPath (path : String) (command : Process.Command) : Process.Command :=
  { command with
    environment :=
      { command.environment with
        set := (command.environment.set.filter (·.1 != "PATH")).push ("PATH", path) } }

/-- `services` whose process service starts every child with its command
changed by `change`, after the environment its directory's lookup gives it:
each request that starts a child is matched constructor by constructor, so
the replies' types line up. The test process's own environment is never
touched. -/
def onChanged (services : Job.Services) (change : Process.Command → Process.Command) :
    Job.Services :=
  let processes := services.processes
  let changed : ProcessRequest → ProcessRequest
    | .run command limit => .run (change command) limit
    | .runWithin command limit time => .runWithin (change command) limit time
    | .runInput command input limit time => .runInput (change command) input limit time
    | .start command streaming => .start (change command) streaming
    | other => other
  { services with
    processes :=
      { start := fun id request => processes.start id (changed request)
        take := fun id request =>
          match request with
          | .run command limit => processes.take id (.run (change command) limit)
          | .runWithin command limit time =>
            processes.take id (.runWithin (change command) limit time)
          | .runInput command input limit time =>
            processes.take id (.runInput (change command) input limit time)
          | .start command streaming => processes.take id (.start (change command) streaming)
          | .read process => processes.take id (.read process)
          | .write process bytes => processes.take id (.write process bytes)
          | .closeInput process => processes.take id (.closeInput process)
        cancel := processes.cancel } }

/-- `services` whose process service starts every child with `PATH` set to
`path`, after the environment its directory's lookup gives it
(`onChanged`). -/
def onFixturePath (services : Job.Services) (path : String) : Job.Services :=
  onChanged services (withPath path)

/-- The variables that keep a git run from reading the user's or the
system's config: no system config, `global` as the global one, `/dev/null`
unless it is given, and `home` as its home. -/
def isolatedGit (home : System.FilePath) (global : System.FilePath := "/dev/null") :
    Array (String × String) :=
  #[("GIT_CONFIG_NOSYSTEM", "1"), ("GIT_CONFIG_GLOBAL", global.toString), ("HOME", home.toString),
    ("XDG_CONFIG_HOME", home.toString)]

/-- `services` whose process service starts every child with the variables
of `isolatedGit home global` set, over any of theirs its command sets
(`onChanged`). -/
def onIsolatedGit (services : Job.Services) (home : System.FilePath)
    (global : System.FilePath := "/dev/null") : Job.Services :=
  onChanged services fun command =>
    let names := (isolatedGit home global).map (·.1)
    { command with
      environment :=
        { command.environment with
          set :=
            (command.environment.set.filter (!names.contains ·.1)) ++ isolatedGit home global } }

/-- The environment of the git runs that write a repository out: the
variables of `isolatedGit home`, a fixed author and committer, and
`GIT_DIR`, `GIT_WORK_TREE` and `GIT_INDEX_FILE` removed. Applied to each
child only; the test process's environment is never touched. -/
def writerEnvironment (home : System.FilePath) : Array (String × Option String) :=
  (isolatedGit home).map (fun (name, value) => (name, some value)) ++
    #[("GIT_AUTHOR_NAME", some "a"), ("GIT_AUTHOR_EMAIL", some "a@example.com"),
      ("GIT_COMMITTER_NAME", some "a"), ("GIT_COMMITTER_EMAIL", some "a@example.com"),
      ("GIT_AUTHOR_DATE", some "2026-01-01T00:00:00Z"),
      ("GIT_COMMITTER_DATE", some "2026-01-01T00:00:00Z"), ("GIT_DIR", none),
      ("GIT_WORK_TREE", none), ("GIT_INDEX_FILE", none)]

/-- Runs `git` with `arguments` in `directory`, fed `input` if it is given,
with the writer's environment: what it printed, or a throw when it did not
exit 0. -/
def gitIn (home directory : System.FilePath) (arguments : Array String)
    (input : Option String := none) : IO String :=
  IO.Process.run
    { cmd := "git", args := arguments, cwd := directory, env := writerEnvironment home } input

/-- `gitIn`, with the index git reads and writes the file `index` in place of
the repository's own. -/
def gitInIndex (home directory index : System.FilePath) (arguments : Array String) : IO String :=
  IO.Process.run
    { cmd := "git", args := arguments, cwd := directory
      env :=
        ((writerEnvironment home).filter (·.1 != "GIT_INDEX_FILE")).push
          ("GIT_INDEX_FILE", some index.toString) }

/-- Writes each named revision of `repository` into the repository at
`directory` as a commit of its files alone, tagged with its name: its files'
blobs written, an index of them made in a file of its own under `home`, so
the repository's index and working tree are left as they are, its tree
written and committed with `commit-tree`, and the tag pointed at it with
`update-ref`. -/
def writeRevisions (home directory : System.FilePath)
    (repository : VersionControl.Model.Repository) : IO Unit := do
  for (name, files) in repository.revisions do
    let index := home / s!"index-{name}"
    for (path, content) in files do
      let id := (← gitIn home directory #["hash-object", "-w", "--stdin"] (some content)).trimAscii
      discard <|
          gitInIndex home directory index
            #["update-index", "--add", "--cacheinfo", s!"100644,{id},{path}"]
    let tree := (← gitInIndex home directory index #["write-tree"]).trimAscii.toString
    let commit := (← gitIn home directory #["commit-tree", tree, "-m", name]).trimAscii.toString
    discard <| gitIn home directory #["update-ref", s!"refs/tags/{name}", commit]

/-- Writes `content` as a blob into the repository at `directory`, the store's
escapes turned back into their bytes (`File.encodeText`), through a file of
its own under `home`: its id. -/
def hashBlob (home directory : System.FilePath) (content : String) : IO String := do
  let file := home / "blob"
  writeMaking file content
  return (← gitIn home directory #["hash-object", "-w", file.toString]).trimAscii.toString

/-- Writes a commit of `files` with the parents `parents`, real ids, into the
repository at `directory`, made with an index file of its own named after
`name` under `home`, `write-tree` and `commit-tree`: its id. -/
def writeCommit (home directory : System.FilePath) (name : String) (files : Array (String × String))
    (parents : Array String) : IO String := do
  let index := home / s!"index-commit-{name}"
  for (path, content) in files do
    discard <|
        gitInIndex home directory index
          #["update-index", "--add", "--cacheinfo",
            s!"100644,{← hashBlob home directory content},{path}"]
  let tree := (← gitInIndex home directory index #["write-tree"]).trimAscii.toString
  let arguments := #["commit-tree", tree, "-m", name] ++ parents.flatMap (#["-p", ·])
  return (← gitIn home directory arguments).trimAscii.toString

/-- The real id of the model's commit `id` among `written`, the model's ids
with the real ones, or none. -/
def realId (written : Array (String × String)) (id : String) : Option String :=
  VersionControl.Model.lookup written id

/-- `text` as one word of `/bin/sh`: in single quotes, each of its own made
`'\\''`. -/
def shellQuoted (text : String) : String :=
  "'" ++ "'\\''".intercalate (text.splitOn "'") ++ "'"

/-- Writes the pre-commit hook of the repository at `directory` that refuses
every commit, printing `printed`: its first line on its standard output and
the rest on its standard error (`Repository.hook`). -/
def writeHook (directory : System.FilePath) (printed : String) : IO Unit := do
  let lines := VersionControl.linesOf printed |>.map (·.trimAsciiEnd.toString)
  let say (line : String) (stream : String) := s!"printf '%s\\n' {shellQuoted line}{stream}\n"
  let script :=
    "#!/bin/sh\n" ++ String.join ((lines.toList.take 1).map (say · "")) ++
      String.join ((lines.toList.drop 1).map (say · " >&2")) ++
      "exit 1\n"
  let hook := directory / ".git" / "hooks" / "pre-commit"
  writeMaking hook script
  IO.setAccessRights hook { user := { read := true, write := true, execution := true } }

/-- Writes `repository` out as a git repository in `directory`, with git's
own commands: initialised on its branch; each of its `commits` written in
order (`writeCommit`), its parents mapped to the real ids; `HEAD`'s files
committed, over its `parents` with `commit-tree` and its branch pointed at
it when it has some, then the index read from it, and checked out detached
if it is; each of its other `branches` pointed at its commit with
`update-ref`; each index entry that differs from `HEAD` written
with `update-index` (a conflict as its stages, through `--index-info`), each
named revision committed and tagged (`writeRevisions`), the working tree
made exactly `repository.worktree`, each `linked` worktree made with `git
worktree add` beside `directory` under its path's last component, on its
branch or detached at `HEAD`, a `dirty` one given an untracked file, each
`occupied` directory made beside `directory` the same way with a file in it, and a
`hook` written as an executable `.git/hooks/pre-commit` (`writeHook`). A file is written with the store's
escapes turned back into their bytes (`File.encodeText`), so a content may
hold a byte that is not UTF-8. -/
def writeGitRepository (home directory : System.FilePath)
    (repository : VersionControl.Model.Repository) : IO Unit := do
  let branch :=
    match repository.head with
    | .branch name => name
    | .detached => "main"
  discard <| gitIn home directory #["-c", s!"init.defaultBranch={branch}", "init", "-q"]
  let mut written : Array (String × String) := #[]
  for (id, commit) in repository.commits do
    let parents := commit.parents.filterMap (realId written)
    written := written.push (id, ← writeCommit home directory id commit.files parents)
  unless repository.committed.isEmpty do
    for (path, content) in repository.committed do
      writeMaking (directory / path) content
    if repository.parents.isEmpty then
      discard <| gitIn home directory #["add", "-A"]
      discard <| gitIn home directory #["-c", "commit.gpgsign=false", "commit", "-q", "-m", "head"]
    else
      let head ←
        writeCommit home directory "head" repository.committed
            (repository.parents.filterMap (realId written))
      discard <| gitIn home directory #["update-ref", s!"refs/heads/{branch}", head]
      discard <| gitIn home directory #["read-tree", "HEAD"]
    if repository.head == .detached then
      discard <| gitIn home directory #["checkout", "-q", "--detach"]
    written :=
      written.push
        (repository.headId, (← gitIn home directory #["rev-parse", "HEAD"]).trimAscii.toString)
  for (name, id) in repository.branches do
    if let some real := realId written id then
      discard <| gitIn home directory #["update-ref", s!"refs/heads/{name}", real]
  let hash (content : String) : IO String := do
    return (←
          gitIn home directory #["hash-object", "-w", "--stdin"] (some content)).trimAscii.toString
  let paths := repository.committed.map (·.1) ++ repository.index.map (·.1)
  for path in paths.toList.eraseDups do
    let committed := VersionControl.Model.lookup repository.committed path
    match VersionControl.Model.lookup repository.index path with
    | some (.file content) =>
      if committed != some content then
        discard <|
            gitIn home directory
              #["update-index", "--add", "--cacheinfo", s!"100644,{← hash content},{path}"]
    | some (.conflict base ours theirs) =>
      if committed.isSome then
        discard <| gitIn home directory #["update-index", "--force-remove", "--", path]
      let mut lines := ""
      for (stage, content) in [(1, base), (2, ours), (3, theirs)] do
        if let some content := content then
          lines := lines ++ s!"100644 {← hash content} {stage}\t{path}\n"
      discard <| gitIn home directory #["update-index", "--index-info"] (some lines)
    | none =>
      if committed.isSome then
        discard <| gitIn home directory #["update-index", "--force-remove", "--", path]
  writeRevisions home directory repository
  for (path, _) in repository.committed do
    if (VersionControl.Model.lookup repository.worktree path).isNone then
      IO.FS.removeFile (directory / path)
  for (path, content) in repository.worktree do
    writeMaking (directory / path) content
  for linked in repository.linked do
    let target := (directory.parent.getD directory) / (linked.path.fileName.getD "linked")
    match linked.branch with
    | some name =>
      discard <| gitIn home directory #["worktree", "add", "-q", target.toString, name]
    | none =>
      discard <|
          gitIn home directory #["worktree", "add", "-q", "--detach", target.toString, "HEAD"]
    if linked.dirty then
      writeMaking (target / "untracked.txt") "untracked\n"
  for occupied in repository.occupied do
    let target := (directory.parent.getD directory) / (occupied.fileName.getD "occupied")
    writeMaking (target / "kept.txt") "kept\n"
  if let some printed := repository.hook then
    writeHook directory printed

/-- `check` handed a home and a repository directory of its own, under a
temporary directory removed afterwards (`withBase`). -/
def withRepository {α : Type} (check : System.FilePath → System.FilePath → IO α) : IO α :=
  withBase fun base => do
    IO.FS.createDirAll (base / "home")
    IO.FS.createDirAll (base / "repo")
    check (base / "home") (base / "repo")

/-- A user's global git config asking for what the git implementation's
command line pins away (`Editor/VersionControl/Git.lean`, "The command
lines"): copies found as well as renames, by `status.renames` and by
`diff.renames`, and no untracked files listed; a commit's message
stripped of lines that start with `#`; and a patch's whitespace fixed and
its context matched loosely; and remote branches guessed for a new worktree
and every new branch tracking its start, neither of which may change what
is made. It names a user, since no commit runs without
one and the writer's own does not reach the editor's runs, and turns
signing off. The editor runs git under the user's config, so the contract
runs it under this one. -/
def pinnedAwayConfig : String :=
  "[status]\n\trenames = copies\n\tshowUntrackedFiles = no\n[diff]\n\trenames = copies\n" ++
    "[worktree]\n\tguessRemote = true\n[branch]\n\tautoSetupMerge = always\n" ++
    "[user]\n\tname = a\n\temail = a@example.com\n" ++
    "[commit]\n\tgpgSign = false\n\tcleanup = strip\n" ++
    "[apply]\n\twhitespace = fix\n\tignoreWhitespace = change\n"

/-- `check` handed a home holding `pinnedAwayConfig` as the file `gitconfig`,
whose path it is also handed, and a repository directory, both its own
(`withRepository`), with `repository` written out in the directory. A
commit needs the config's user: git run without one would guess an address
from the host's name, and fails where that has no domain. -/
def withConfiguredRepository {α : Type} (repository : VersionControl.Model.Repository)
    (check : System.FilePath → System.FilePath → System.FilePath → IO α) : IO α :=
  withRepository fun home directory => do
    writeGitRepository home directory repository
    let config := home / "gitconfig"
    IO.FS.writeFile config pinnedAwayConfig
    check home config directory

/-- Whether the git implementation reads the status of the repository at
`directory` as `expected`, over `services`. -/
def gitStatusIs (services : Job.Services) (directory : System.FilePath)
    (expected : VersionControl.Status) : IO Bool := do
  let read : JobM Bool := do
    return (← Program.runM (VersionControl.Git.handler "git" directory) VersionControl.status) ==
        .ok expected
  return (← runOnTimers services read) == .finished true

end ContractTest
