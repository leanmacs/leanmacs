import Editor.Invocation
import Editor.Process
import Editor.Process.Environment
import Editor.Workspace

/-!
# Which command lists a workspace's files

Listing a workspace's files is a choice made in Lean, with an order, as
finding a workspace is (`Workspace/Finder.lean`): `Workspace.lister`
answers which command lists them, as a value (`Lister`), and runs nothing.
What runs it is the source of `find-file-in-workspace`
(`Workspace/FindFile.lean`), in a job. This module is pure and
imports only `Editor.Workspace` and the process command's type, so it stays
inside config's closure.

## The order

The first that answers wins.

1. **Config, for the workspace's root** (`Setup.workspaceLister`): a lister
   declared for a root equal to the workspace's, a trailing `/` aside.
2. **Config, for its project** (`Setup.projectLister`): a lister declared for
   the identity of the workspace's project, which every workspace of the
   project shares. A root's lister beats its project's, as the more
   specific declaration.
3. **Git**, for a workspace git found (`Workspace.foundByGit`: on this
   machine, with a branch): `git ls-files -z --cached --others
   --exclude-standard`, the program the finder runs (`Settings.git`), in
   git's environment (`Git.environment`). Git applies its own ignore rules,
   `.gitignore` at every level, `info/exclude` and the global excludes, so
   the editor never reimplements them; untracked files that are not ignored
   are listed too.
4. **The fallback**, for any other workspace and for no workspace:
   `find . -type f -not -path '*/.git/*' -print0`. Its records start with
   `./`, which they lose (`Lister.relative`). `find` exits 1 when it meets
   a directory it cannot read or an entry that vanishes while it walks,
   and still prints every other file, so the fallback declares 1 a partial
   listing (`Lister.partialListing`, honoured by
   `Completion.Filtering.partialListing`): the files it could read are
   listed. Git's lister and config's declare none, so any exit of theirs
   but 0 fails the source.

No shell is involved: each argument is one argument, so `*/.git/*` reaches
`find` as it is written. A remote location's lister is not chosen here: a
workspace whose location cannot read files and run commands is refused
before a lister is asked for (`Workspace/FindFile.lean`).

The listers are Projectile's, as prior art: its `projectile-git-command`,
`git ls-files -zco --exclude-standard`, and its `projectile-generic-command`,
`find . -type f -print0`.

## Where an addition goes

| Addition | Where |
|---|---|
| A new kind of lister | A constructor of `Lister.Origin`, its `name`, and a step of `lister` |
| A lister for jj workspaces | A step of `lister` before git's, once the finder can tell jj found one (`foundByGit` changes with it) |
| A new way config declares one | A constructor of `ListerScope` (`Editor/Workspace.lean`) and a step of `lister` |

Pinned by `WorkspaceTest.workspaceListerChecks`, and git's and the fallback's
command lines over real git and find by `WorkspaceTest.Linked.workspaceListerChecks`.
-/

namespace Editor.Workspace

/-- Where a lister came from: which step of `lister` answered. -/
inductive Lister.Origin where
  /-- Config declared it, for the root or for the project. -/
  | config
  /-- Git's, for a workspace git found. -/
  | git
  /-- The fallback, `find`. -/
  | fallback
  deriving DecidableEq, Repr

/-- The origin as a word, for messages and for arguments. -/
def Lister.Origin.name : Lister.Origin → String
  | .config => "config"
  | .git => "git"
  | .fallback => "fallback"

/-- The origin a word names (`Origin.name`), if it names one. -/
def Lister.Origin.ofName? : String → Option Lister.Origin
  | "config" => some .config
  | "git" => some .git
  | "fallback" => some .fallback
  | _ => none

/-- A command that lists a workspace's files, run at its root: its standard
output is the files' paths, relative to the root, one a record. -/
structure Lister where
  /-- Which step of `lister` answered. -/
  origin : Lister.Origin
  /-- The program: a bare name, looked up on the `PATH`, or an absolute
  path. -/
  program : String
  /-- Its arguments, each one argument: no shell sees them. -/
  arguments : Array String
  /-- Whether its records end in a NUL rather than a line feed. -/
  nul : Bool
  /-- A prefix each record loses when it has it: `./` for `find`. -/
  strip : String := ""
  /-- The exit statuses, other than 0, after which its records still
  answer: a listing it made only in part. `[1]` for `find`. -/
  partialListing : List Nat := []
  deriving DecidableEq, Repr

namespace Lister

/-- Git's lister: `git ls-files -z --cached --others --exclude-standard`,
run as `git`. -/
def git (git : String) : Lister :=
  { origin := .git, program := git
    arguments := #["ls-files", "-z", "--cached", "--others", "--exclude-standard"], nul := true }

/-- The fallback: `find . -type f -not -path '*/.git/*' -print0`, whose
records lose their `./`, and whose exit 1, past a directory it cannot read,
still answers the files it listed. -/
def fallback : Lister :=
  { origin := .fallback, program := "find"
    arguments := #[".", "-type", "f", "-not", "-path", "*/.git/*", "-print0"], nul := true
    strip := "./", partialListing := [1] }

/-- The lister of what config declared. -/
def ofDeclared (declared : DeclaredLister) : Lister :=
  { origin := .config, program := declared.program, arguments := declared.arguments
    nul := declared.nul }

/-- The command `lister` runs at `root`: git's in git's environment, as the
finder's runs are (`Git.environment`), every other in the editor's. -/
def command (lister : Lister) (root : System.FilePath) : Process.Command :=
  { program := lister.program, arguments := lister.arguments
    environment := if lister.origin == .git then Git.environment else {}, directory := root }

/-- `record` as a path relative to the root: without `lister`'s prefix when
it starts with it. -/
def relative (lister : Lister) (record : String) : String :=
  if !lister.strip.isEmpty && record.startsWith lister.strip then
    String.ofList (record.toList.drop lister.strip.length)
  else record

/-- `lister` as plain arguments: its origin's name, its program, whether it
is NUL-separated, its prefix, how many partial-listing statuses it has, then
each of them, how many arguments it has, then each of them. -/
def toArguments (lister : Lister) : List Argument :=
  [.str lister.origin.name, .str lister.program, .bool lister.nul, .str lister.strip,
      .nat lister.partialListing.length] ++
    lister.partialListing.map .nat ++
    [.nat lister.arguments.size] ++
    lister.arguments.toList.map .str

/-- The strings `arguments` are, if they are all strings. -/
def stringsOf? (arguments : List Argument) : Option (Array String) :=
  arguments.toArray.mapM fun
    | .str text => some text
    | _ => none

/-- The lister `arguments` are (`Lister.toArguments`), if they are one. -/
def ofArguments? : List Argument → Option Lister
  | .str origin :: .str program :: .bool nul :: .str strip :: .nat statuses :: rest => do
    let origin ← Origin.ofName? origin
    let partialListing ←
      (rest.take statuses).mapM fun
          | .nat status => some status
          | _ => none
    if partialListing.length != statuses then
      none
    let .nat count :: rest := rest.drop statuses | none
    let arguments ← stringsOf? rest
    if arguments.size != count then
      none
    return { origin, program, arguments, nul, strip, partialListing }
  | _ => none

end Lister

/-- Which command lists the files of `workspace`, or of the directory
searched when there is none ("The order", in the module docs): config's
lister for its root, else config's for its project, else git's for a
workspace git found, else the fallback. -/
def lister (settings : Settings) (workspace : Option Workspace) : Lister :=
  match workspace with
  | none => .fallback
  | some workspace =>
    let forRoot :=
      workspace.location.root?.bind fun root =>
        settings.listers.find? fun declared =>
          declared.scope.trimmed == .root (Process.trimmed root)
    let forProject := settings.listers.find? (·.scope == .project workspace.project.identity)
    match forRoot <|> forProject with
    | some declared => .ofDeclared declared
    | none => if foundByGit workspace then .git settings.git else .fallback

end Editor.Workspace
