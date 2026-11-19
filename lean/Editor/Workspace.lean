import Editor.Invocation
import Editor.Process.Environment
import Editor.Value

/-!
# Projects, workspaces and locations

Which codebase a buffer belongs to, and which checkout of it, as plain
values (`docs/design/projects.md`). Three layers:

- **A project** (`Project`) is a codebase, identified by its repository and
  not by a path (`Project.Identity`): the normalised URL of its `origin`
  remote when it has one, so two clones of one repository are one project;
  otherwise its common git directory, so the worktrees of a repository with
  no remote are one project; otherwise, for a directory that is no
  repository, its root. A name config declares for a root it declares is
  the identity instead (`declared`).
- **A workspace** (`Workspace`) is one checkout of a project: its location,
  which holds its one root, set when it is first found and never derived
  again; the branch checked out there; and its project.
- **A location** (`Location`) is where the workspace's files and commands
  are: on this machine (`local`), on a machine a command reaches
  (`reachable`, a Kubernetes pod, a container, an `ssh` host), or nowhere the
  editor can reach, known only by the remote and the branch its work comes
  back on (`branchOnly`). A location says what it can do
  (`Location.can`); only `local` can do anything.

It imports only the plain trees and the pure part of a child's environment
(for `Process.ancestry`), so it stays inside config's closure.

## The rules

- **Normalising an origin** (`normaliseRemote`): `git@host:path`,
  `ssh://[user@]host[:port]/path` and `http(s)://[user@]host/path` are each
  `host/path`, the host lowercased; a trailing `/` and `.git` are dropped.
  So the ssh and https forms of one repository, with or without `.git`, are
  one project.
- **Naming a project** (`Project.nameOf`): a name config declares; else the
  last component of the normalised origin; else the last component of the
  directory that holds the common git directory; else the root's.
- **Labelling a workspace** (`Workspace.label`): `name@branch`, or
  `name@<the root's last component>` when it is detached or has no branch,
  so two workspaces of one project are told apart. The rule is
  `Workspace.labelOf`, which a worktree the table does not know yet is
  labelled by too (`Editor/Workspace/Projects.lean`).
- **The finder's shared rules** are here too, pure, so the model and the
  real finder (`Editor/Workspace/Model.lean`, `Editor/Workspace/Finder.lean`)
  take them from one place: the config adapter (`fromConfig?`, the deepest
  config root that holds the directory), the git command lines and the
  reading of what they print (`Git`), and the order the marker adapter looks
  in (`markerPaths`, nearest directory first, then the markers in order).
- **Which adapter found a workspace** is read from its branch
  (`foundByGit`): only the git adapter gives one, so a local workspace with
  a branch is one git found. A workspace does not record its adapter.
- **Config's listers** (`DeclaredLister`, `Settings.listers`) are declared
  for a root or for a project (`ListerScope`); which command lists a
  workspace's files is chosen in `Editor/Workspace/Lister.lean`.
- **Modes on markers** (`searchedFrom`, `markerSearchPaths`, `onModes`): a
  minor mode's markers (`MarkerMode`, a compile contribution's,
  `Editor/ProjectMode.lean`) are looked for from a file's
  directory up to and including its workspace root, and never above it,
  so one worktree's modes are found within that worktree; a file with no
  workspace looks in its own directory alone. A mode is on at the nearest
  directory that holds one of its markers, which is its root
  (`OnMode`); an outermost mode (`MarkerMode.outermost`), such as
  `cargo-mode`, whose tool prints paths relative to its outermost marker's
  directory, at the farthest directory searched that holds one. The
  on-modes are ordered, once their roots are chosen, nearest root first
  and, at one root, in registration order. A marker is there by the
  finder's rule.
  The search is `Workspace.presentMarkers` (`Editor/Workspace/Finder.lean`),
  its model `World.presentMarkers`, and both are held to
  `Workspace.MarkerContract` (`Editor/Workspace/Contract.lean`).
- **The table** (`Workspace.Table`) is the editor state's
  (`EditorState.workspaces`): the workspaces, each with its store of values
  by name, keyed by its location; the projects, each with its store, keyed
  by identity; and the cache of each directory's answer, stamped with the
  config generation it was found under. A workspace found again keeps its
  root and its project and takes the new branch. Cells are `Value` trees,
  as a buffer's locals are, so a reload leaves them.
- **Registering** (`Table.register`) makes a workspace that is not found,
  for a location that is not `local`: its project is its remote's.
- **The unscoped store** (`Table.unscoped`) is the store of the buffers
  outside any workspace, which have no project either: one store, by name,
  in place of both, as long as the session.
  `:!` keeps the history and the output buffer of such buffers there
  (`Editor/Shell.lean`).

## Adding to this

A new adapter of the finder (jj, a remote location) is a step of
`Workspace.find`, a clause of `World.find` and a property of
`Workspace.FinderContract`. A new kind of location is a constructor of
`Location`, with its case in `Location.can`, `encode`, `decode?` and
`describe`. A new question about the table is a pure function here.
-/

namespace Editor

/-- What identifies a project. -/
inductive Project.Identity where
  /-- The normalised URL of its `origin` remote (`normaliseRemote`). -/
  | remote (normalised : String)
  /-- Its common git directory, for a repository with no `origin`. -/
  | commonDir (path : System.FilePath)
  /-- Its root, for a directory that is no repository. -/
  | root (path : System.FilePath)
  /-- A name config declared for a root it declared. -/
  | declared (name : String)
  deriving DecidableEq, Repr

/-- A project: a codebase, whichever checkout of it is open. -/
structure Project where
  /-- What identifies it. -/
  identity : Project.Identity
  /-- Its display name. -/
  name : String
  /-- The URL of its `origin` remote, as git printed it, if it has one. -/
  remote : Option String := none
  /-- Its common git directory, if it is a repository. -/
  commonDir : Option System.FilePath := none
  deriving DecidableEq, Repr

/-- What is checked out in a workspace. -/
inductive Workspace.Branch where
  /-- The branch of this name. -/
  | named (name : String)
  /-- No branch: `HEAD` is detached. -/
  | detached
  deriving DecidableEq, Repr

/-- Where a workspace's files and commands are. -/
inductive Location where
  /-- On this machine, at `root`. -/
  | «local» (root : System.FilePath)
  /-- On another machine a command reaches: `kind` says how (`kube`,
  `docker`, `ssh`), `target` what it reaches, and `root` is the root there. -/
  | reachable (kind target : String) (root : System.FilePath)
  /-- Somewhere the editor cannot reach, known by the git remote and the
  branch its work comes back on. -/
  | branchOnly (remote branch : String)
  deriving DecidableEq, Repr

/-- What a location lets the editor do. -/
structure Location.Capabilities where
  /-- Read its files. -/
  readFiles : Bool
  /-- Run commands there. -/
  runCommands : Bool
  /-- Watch its files. -/
  watchFiles : Bool
  deriving DecidableEq, Repr

/-- A workspace: one checkout of a project. -/
structure Workspace where
  /-- Where it is; its root is set once, when it is first found. It is the
  workspace's key in the table. -/
  location : Location
  /-- What is checked out there, if it is a repository. -/
  branch : Option Workspace.Branch := none
  /-- Its project. -/
  project : Project
  deriving DecidableEq, Repr

/-- Why a request about workspaces was refused. -/
inductive WorkspaceRefusal where
  /-- A local workspace is found, not registered. -/
  | «local»
  /-- No workspace is at this location. -/
  | noSuchWorkspace (location : Location)
  /-- No project has this identity. -/
  | noSuchProject (identity : Project.Identity)
  deriving DecidableEq, Repr

/-- Why a request about workspaces was refused, as a sentence. -/
def WorkspaceRefusal.describe : WorkspaceRefusal → String
  | .local => "a local workspace is found, not registered"
  | .noSuchWorkspace _ => "there is no such workspace"
  | .noSuchProject _ => "there is no such project"

namespace Location

/-- What a location can do: everything on this machine, nothing elsewhere,
since no adapter reaches another machine yet. -/
def can : Location → Capabilities
  | .local _ => { readFiles := true, runCommands := true, watchFiles := true }
  | .reachable .. => { readFiles := false, runCommands := false, watchFiles := false }
  | .branchOnly .. => { readFiles := false, runCommands := false, watchFiles := false }

/-- The root a location holds, where it has one. -/
def root? : Location → Option System.FilePath
  | .local root => some root
  | .reachable _ _ root => some root
  | .branchOnly .. => none

/-- A location as a plain tree: one named field, the kind's. -/
def encode : Location → Value
  | .local root => .record [("local", .str root.toString)]
  | .reachable kind target root =>
    .record [("reachable", .list [.str kind, .str target, .str root.toString])]
  | .branchOnly remote branch => .record [("branchOnly", .list [.str remote, .str branch])]

/-- The location a tree stands for (`encode`), if it is one. -/
def decode? : Value → Option Location
  | .record [("local", .str root)] => some (.local root)
  | .record [("reachable", .list [.str kind, .str target, .str root])] =>
    some (.reachable kind target root)
  | .record [("branchOnly", .list [.str remote, .str branch])] => some (.branchOnly remote branch)
  | _ => none

/-- A location as the arguments a job is started with: its kind, then its
parts. -/
def arguments : Location → List Argument
  | .local root => [.str "local", .str root.toString]
  | .reachable kind target root => [.str "reachable", .str kind, .str target, .str root.toString]
  | .branchOnly remote branch => [.str "branchOnly", .str remote, .str branch]

/-- The location `arguments` start with (`arguments`), and the rest. -/
def of? : List Argument → Option (Location × List Argument)
  | .str "local" :: .str root :: rest => some (.local root, rest)
  | .str "reachable" :: .str kind :: .str target :: .str root :: rest =>
    some (.reachable kind target root, rest)
  | .str "branchOnly" :: .str remote :: .str branch :: rest =>
    some (.branchOnly remote branch, rest)
  | _ => none

/-- A location for a person. -/
def describe : Location → String
  | .local root => s!"local {root}"
  | .reachable kind target root => s!"reachable through {kind} {target} at {root}"
  | .branchOnly remote branch => s!"only the branch {branch} of {remote}"

end Location

/-- What a location can do, for a person. -/
def Location.Capabilities.describe (can : Capabilities) : String :=
  let able :=
    [(can.readFiles, "read files"), (can.runCommands, "run commands"),
          (can.watchFiles, "watch files")].filterMap
      fun (yes, what) => if yes then some what else none
  if able.isEmpty then "can do nothing here" else s!"can {", ".intercalate able}"

/-- An identity, for a person. -/
def Project.Identity.describe : Project.Identity → String
  | .remote normalised => s!"remote {normalised}"
  | .commonDir path => s!"git directory {path}"
  | .root path => s!"root {path}"
  | .declared name => s!"declared {name}"

namespace Workspace

/-! ## Normalising a remote, and names -/

/-- `chars` without `drop` at their end, as often as it is there. -/
def dropTrailing (drop : Char) (chars : List Char) : List Char :=
  (chars.reverse.dropWhile (· == drop)).reverse

/-- `text` without `suffix` at its end, if it ends with it. -/
def withoutSuffix (text suffix : String) : String :=
  if text.endsWith suffix then String.ofList (text.toList.take (text.length - suffix.length))
  else text

/-- A path of a remote with no `/` at either end and no `.git` at its end. -/
def tidyPath (path : List Char) : String :=
  let trimmed := String.ofList (dropTrailing '/' (path.dropWhile (· == '/')))
  String.ofList (dropTrailing '/' (withoutSuffix trimmed ".git").toList)

/-- The host of an authority, `[user@]host[:port]`: after the last `@`, before
the first `:`, lowercased. -/
def hostOf (authority : List Char) : String :=
  let afterUser := (authority.reverse.takeWhile (· != '@')).reverse
  String.ofList ((afterUser.takeWhile (· != ':')).map Char.toLower)

/-- An `origin` URL as one string for every form of it (`normaliseRemote`, in
the module docs): `host/path`, the host lowercased, with no `.git` and no
trailing `/`. A URL of no form it knows, a local path, keeps its path with
the same tidying. -/
def normaliseRemote (url : String) : String :=
  let chars := (dropTrailing ' ' (url.toList.dropWhile Char.isWhitespace)).filter (· != '\n')
  let text := String.ofList chars
  match text.splitOn "://" with
  | _ :: rest@(_ :: _) =>
    let rest := ("://".intercalate rest).toList
    let authority := rest.takeWhile (· != '/')
    let path := rest.dropWhile (· != '/')
    s!"{hostOf authority}/{tidyPath path}"
  | _ =>
    let before := chars.takeWhile (· != ':')
    let after := chars.dropWhile (· != ':')
    match after with
    | ':' :: path =>
      if !before.isEmpty && !before.contains '/' then s!"{hostOf before}/{tidyPath path}"
      else tidyPath chars
    | _ => if text.startsWith "/" then "/" ++ tidyPath chars else tidyPath chars

/-- The last component of `path`, or the whole of it when it has none. -/
def lastComponent (path : System.FilePath) : String :=
  (Process.trimmed path).fileName.getD path.toString

end Workspace

/-- A project's name (`Project.nameOf`, in the module docs): a declared name;
else the last component of the normalised origin; else of the directory that
holds the common git directory; else of the root. -/
def Project.nameOf (root : System.FilePath) (commonDir : Option System.FilePath)
    (origin : Option String) (declared : Option String) : String :=
  match declared, origin, commonDir with
  | some name, _, _ => name
  | none, some origin, _ =>
    let normalised := Workspace.normaliseRemote origin
    ((normalised.splitOn "/").filter (!·.isEmpty)).getLastD normalised
  | none, none, some commonDir =>
    match (Process.trimmed commonDir).parent with
    | some holder => Workspace.lastComponent holder
    | none => Workspace.lastComponent root
  | none, none, none => Workspace.lastComponent root

/-- The project of a workspace at `root`, by the identity rule: a declared
name, else the normalised origin, else the common git directory, else the
root; named by `nameOf`. -/
def Project.of (root : System.FilePath) (commonDir : Option System.FilePath)
    (origin : Option String) (declared : Option String) : Project :=
  let identity : Project.Identity :=
    match declared, origin, commonDir with
    | some name, _, _ => .declared name
    | none, some origin, _ => .remote (Workspace.normaliseRemote origin)
    | none, none, some commonDir => .commonDir commonDir
    | none, none, none => .root root
  { identity, name := Project.nameOf root commonDir origin declared, remote := origin, commonDir }

/-- The project of a workspace that is registered with the remote `remote`:
identified by it. -/
def Project.ofRemote (remote : String) : Project :=
  { identity := .remote (Workspace.normaliseRemote remote)
    name := Project.nameOf "/" none (some remote) none, remote := some remote }

/-- The last component of a location's root, or the branch of one known
only by its branch. -/
def Location.name : Location → String
  | .local root => Workspace.lastComponent root
  | .reachable _ _ root => Workspace.lastComponent root
  | .branchOnly _ branch => branch

namespace Workspace

/-- How a checkout of the project named `name`, at `location` with `branch`
checked out, is shown (`Workspace.label`, in the module docs):
`name@branch`, or `name@<the root's last component>`. The one rule, for a
workspace of the table and for a worktree not yet found alike. -/
def labelOf (name : String) (branch : Option Branch) (location : Location) : String :=
  match branch with
  | some (.named branch) => s!"{name}@{branch}"
  | _ => s!"{name}@{location.name}"

/-- How a workspace is shown (`labelOf`). -/
def label (workspace : Workspace) : String :=
  labelOf workspace.project.name workspace.branch workspace.location

/-- The name a buffer keeps its workspace's location under, as a
buffer-local value (`Location.encode`). -/
def bufferLocal : String :=
  "workspace"

/-! ## The finder's settings and its answer -/

/-- A workspace root config declares (`Setup.workspace`), with the name of
the project it belongs to, if config gives one. -/
structure ConfigRoot where
  /-- The root: an absolute path. -/
  root : System.FilePath
  /-- The project's name, which then identifies it. -/
  project : Option String := none
  deriving DecidableEq, Repr

/-- What a lister config declares is for: one workspace root, or every
workspace of a project. -/
inductive ListerScope where
  /-- The workspace whose root is `path`, an absolute path. -/
  | root (path : System.FilePath)
  /-- Every workspace of the project of `identity`. -/
  | project (identity : Project.Identity)
  deriving DecidableEq, Repr

/-- `scope` for a person. -/
def ListerScope.describe : ListerScope → String
  | .root path => s!"the workspace root `{path}`"
  | .project identity => s!"the project {identity.describe}"

/-- `scope` with a root's trailing `/` dropped, so two declarations of one
root are one scope. -/
def ListerScope.trimmed : ListerScope → ListerScope
  | .root path => .root (Process.trimmed path)
  | .project identity => .project identity

/-- A command config declares to list the files of a workspace root, or of
every workspace of a project, in place of git's or the fallback's
(`Editor/Workspace/Lister.lean`): run at the workspace's root, its standard
output the root-relative paths, one a record. -/
structure DeclaredLister where
  /-- Which workspaces it lists. -/
  scope : ListerScope
  /-- The program: a bare name, looked up on the `PATH`, or an absolute
  path. -/
  program : String
  /-- Its arguments. -/
  arguments : Array String := #[]
  /-- Whether its records end in a NUL rather than a line feed. -/
  nul : Bool := false
  deriving DecidableEq, Repr

/-- The files whose presence makes a directory a workspace, in the order
they are looked for. -/
def defaultMarkers : Array String :=
  #[".git", "mise.toml", "Cargo.toml", "lakefile.lean", ".project"]

/-- A minor mode that markers turn on ("Modes on markers", in the module
docs): its name, the names of its marker files, in order, and whether its
root is its outermost marker. -/
structure MarkerMode where
  /-- The minor mode's name. -/
  mode : String
  /-- The names of its marker files. -/
  markers : Array String
  /-- Whether its root is the farthest directory searched that holds one of
  its markers, not the nearest. -/
  outermost : Bool := false
  deriving DecidableEq, Repr

/-- A minor mode a buffer's markers turned on, with its root: the
directory of the nearest of its markers. -/
structure OnMode where
  /-- The minor mode's name. -/
  mode : String
  /-- The directory its nearest marker is in. -/
  root : System.FilePath
  deriving DecidableEq, Repr

/-- An on-mode as a plain tree: its name, then its root. -/
def OnMode.encode (on : OnMode) : Value :=
  .list [.str on.mode, .str on.root.toString]

/-- The on-mode a tree stands for (`OnMode.encode`), if it is one. -/
def OnMode.decode? : Value → Option OnMode
  | .list [.str mode, .str root] => some { mode, root }
  | _ => none

/-- The name a buffer keeps its on-modes under, nearest first, as a
buffer-local value: a list of `OnMode.encode` trees. -/
def modesLocal : String :=
  "marker-modes"

/-- What the finder is handed: config's roots, the git it runs, and the
marker files it looks for; and, for what opens a file, the minor modes that
markers turn on, and, for what lists a workspace's files, config's listers,
neither of which the finder reads. -/
structure Settings where
  /-- The roots config declares. -/
  roots : Array ConfigRoot := #[]
  /-- The git program: a bare name, looked up on the `PATH`, or an absolute
  path. -/
  git : String := "git"
  /-- The marker files, in order. -/
  markers : Array String := defaultMarkers
  /-- The minor modes markers turn on, in registration order: what the loop
  says of the registered compile contributions. -/
  markerModes : Array MarkerMode := #[]
  /-- The listers config declares, in the order it declared them
  (`Editor/Workspace/Lister.lean`). -/
  listers : Array DeclaredLister := #[]
  deriving DecidableEq, Repr

/-- What the finder answers for a directory: the workspace's root, its
branch, if it has one, and its project. -/
structure Found where
  /-- The root. -/
  root : System.FilePath
  /-- What is checked out, for a repository. -/
  branch : Option Branch := none
  /-- The project. -/
  project : Project
  deriving DecidableEq, Repr

/-- Whether `ancestor` is `directory` or holds it. -/
def holds (ancestor directory : System.FilePath) : Bool :=
  (Process.ancestry directory).contains (Process.trimmed ancestor)

/-- The config adapter: the deepest config root that holds `directory`, as
an answer whose project is the declared name's, or the root's. -/
def fromConfig? (settings : Settings) (directory : System.FilePath) : Option Found :=
  let holding := settings.roots.filter fun root => holds root.root directory
  let deepest :=
    holding.foldl
      (fun (best : Option ConfigRoot) root =>
        match best with
        | some kept =>
          if
              (Process.trimmed root.root).toString.length >
                (Process.trimmed kept.root).toString.length then
            some root
          else some kept
        | none => some root)
      none
  deepest.map fun root =>
    let at_ := Process.trimmed root.root
    { root := at_, project := Project.of at_ none none root.project }

/-- Where the marker adapter looks, in order: for `directory` and each of
its ancestors, nearest first, each marker in order, as the directory that
would be the root and the path of the marker. -/
def markerPaths (settings : Settings) (directory : System.FilePath) :
    Array (System.FilePath × System.FilePath) :=
  (Process.ancestry directory).flatMap fun at_ =>
    settings.markers.map fun marker => (at_, Process.inDirectory at_ marker)

/-- The answer of a marker in `root`: a workspace with no branch that is its
own project. -/
def Found.ofMarker (root : System.FilePath) : Found :=
  { root, project := Project.of root none none none }

/-! ## Modes on markers -/

/-- The directories a minor mode's markers are looked for in, nearest first
("Modes on markers", in the module docs): `directory` and its ancestors up
to and including `bound`, when `bound` holds `directory`; otherwise
`directory` alone. -/
def searchedFrom (directory bound : System.FilePath) : Array System.FilePath :=
  let directory := Process.trimmed directory
  let bound := Process.trimmed bound
  if holds bound directory then
    let ancestry := Process.ancestry directory
    match ancestry.findIdx? (· == bound) with
    | some index => ancestry.extract 0 (index + 1)
    | none => #[directory]
  else #[directory]

/-- Where the markers `markers` are looked for, in order: for each directory
of `searchedFrom`, nearest first, each marker in order, as the directory,
the marker's path and the marker's name. -/
def markerSearchPaths (markers : Array String) (directory bound : System.FilePath) :
    Array (System.FilePath × System.FilePath × String) :=
  (searchedFrom directory bound).flatMap fun at_ =>
    markers.map fun marker => (at_, Process.inDirectory at_ marker, marker)

/-- The minor modes of `modes` that the markers `present` turn on, each with
its root, nearest root first and, at one root, in the order of `modes`
("Modes on markers", in the module docs). `present` holds each marker found,
with the directory it is in; a mode is on at the nearest directory of
`searchedFrom` that holds one of its markers, or, an outermost one, at the
farthest. A mode named twice is on by the first of its entries whose markers
are found. -/
def onModes (modes : Array MarkerMode) (directory bound : System.FilePath)
    (present : Array (System.FilePath × String)) : Array OnMode :=
  let searched := searchedFrom directory bound
  let roots :=
    modes.foldl
      (fun (roots : Array OnMode) mode =>
        if roots.any (·.mode == mode.mode) then roots
        else
          let holding :=
            searched.filter fun at_ => mode.markers.any fun marker => present.contains (at_, marker)
          match if mode.outermost then holding.back? else holding[0]? with
          | some root => roots.push { mode := mode.mode, root }
          | none => roots)
      #[]
  searched.flatMap fun at_ => roots.filter (·.root == at_)

/-- Every marker of `modes`, once, in the order it was first named. -/
def markersOf (modes : Array MarkerMode) : Array String :=
  modes.foldl
    (fun (markers : Array String) mode =>
      mode.markers.foldl
        (fun (markers : Array String) marker =>
          if markers.contains marker then markers else markers.push marker)
        markers)
    #[]

/-! ## The git adapter's command lines -/

/-- The most bytes of each stream a git run may write: 64 KiB. -/
def gitOutput : Nat :=
  64 * 1024

/-- How long a git run may take, in milliseconds. -/
def gitTime : Nat :=
  5000

/-- What git printed for a directory: the top level, the common git
directory and what is checked out. -/
structure Git.Answer where
  /-- The top level of the checkout. -/
  toplevel : System.FilePath
  /-- The common git directory. -/
  commonDir : System.FilePath
  /-- What is checked out. -/
  branch : Branch
  deriving DecidableEq, Repr

/-- The environment of a git run: the editor's, with `GIT_DIR` and
`GIT_WORK_TREE` removed, so git answers for the directory it runs in. -/
def Git.environment : Process.Environment :=
  { unset := #["GIT_DIR", "GIT_WORK_TREE"] }

/-- The arguments that ask git for the top level, the common directory and
the branch, in that order. `--path-format=absolute` makes it print the
common directory as an absolute path in a main checkout too. -/
def Git.revParseArguments : Array String :=
  #["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir", "--abbrev-ref",
    "HEAD"]

/-- The command that asks `git` about `directory`. -/
def Git.revParseCommand (git : String) (directory : System.FilePath) : Process.Command :=
  { program := git, arguments := Git.revParseArguments, environment := Git.environment, directory }

/-- The arguments that ask git for the URL of the `origin` remote. -/
def Git.originArguments : Array String :=
  #["remote", "get-url", "origin"]

/-- The command that asks `git` for the `origin` of the repository of
`directory`. -/
def Git.originCommand (git : String) (directory : System.FilePath) : Process.Command :=
  { program := git, arguments := Git.originArguments, environment := Git.environment, directory }

/-- The lines of `bytes`, if they are UTF-8, without a carriage return at
their ends and without the empty line after a last line feed. -/
def Git.lines (bytes : ByteArray) : Option (List String) := do
  let text ← String.fromUTF8? bytes
  let lines := (text.splitOn "\n").map fun line => String.ofList (dropTrailing '\r' line.toList)
  return match lines.reverse with
    | "" :: rest => rest.reverse
    | _ => lines

/-- What `rev-parse` printed in `directory`, read: three lines, an absolute
top level, a common directory resolved against `directory` when it is not
absolute, and `HEAD` for a detached checkout or the branch's name. `none`
for anything else. -/
def Git.parseRevParse (directory : System.FilePath) (bytes : ByteArray) : Option Answer := do
  let [toplevel, commonDir, branch] ← Git.lines bytes | none
  if toplevel.isEmpty || commonDir.isEmpty || branch.isEmpty then
    none
  let toplevel : System.FilePath := toplevel
  unless toplevel.isAbsolute do
    none
  let commonDir : System.FilePath := commonDir
  let commonDir := if commonDir.isAbsolute then commonDir else directory / commonDir
  return { toplevel := Process.trimmed toplevel, commonDir := Process.trimmed commonDir,
           branch := if branch == "HEAD" then .detached else .named branch }

/-- What `remote get-url origin` printed, read: its first line, if it is not
empty. -/
def Git.parseOrigin (bytes : ByteArray) : Option String := do
  let first :: _ ← Git.lines bytes | none
  if first.isEmpty then
    none
  else
    some first

/-- The answer of the git adapter: the top level is the root, the common
directory and the origin identify the project. -/
def Found.ofGit (answer : Git.Answer) (origin : Option String) : Found :=
  { root := answer.toplevel, branch := some answer.branch
    project := Project.of answer.toplevel (some answer.commonDir) origin none }

/-- Whether git found `workspace`: it is on this machine and has a branch,
named or detached. Only the git adapter gives a branch (`Found.ofGit`); the
config adapter (`fromConfig?`) and the marker adapter (`Found.ofMarker`)
give none, and a registered workspace is not local. An adapter that gives a
branch without git, jj's, must change this rule with it. -/
def foundByGit (workspace : Workspace) : Bool :=
  match workspace.location, workspace.branch with
  | .local _, some _ => true
  | _, _ => false

/-! ## The table -/

/-- The workspaces, the projects and the directory cache the editor state
keeps (`EditorState.workspaces`). -/
structure Table where
  /-- Each workspace, with its store: values by name. Keyed by location. -/
  workspaces : Array (Workspace × Array (String × Value)) := #[]
  /-- Each project, with its store: values by name. Keyed by identity. -/
  projects : Array (Project × Array (String × Value)) := #[]
  /-- Each directory asked about, the location of its workspace or none, and
  the config generation it was found under. -/
  cache : Array (System.FilePath × Option Location × Nat) := #[]
  /-- The store of the buffers outside any workspace: values by name, kept
  for the session as a workspace's are. A buffer with no workspace has no
  project either, so this one store stands in for both. -/
  unscoped : Array (String × Value) := #[]
  deriving BEq, Repr

/-- Where a command started in a buffer's name runs (`BufferId.workingDirectory`). -/
inductive WorkingDirectory where
  /-- The root of the buffer's workspace, on this machine. -/
  | workspace (root : System.FilePath)
  /-- The buffer's workspace is not on this machine. -/
  | elsewhere (location : Location)
  /-- The buffer has no workspace: the directory of its file. -/
  | fileDirectory (directory : System.FilePath)
  /-- The buffer has no workspace and no file. -/
  | none
  deriving DecidableEq, Repr

/-- `cells` with `value` under `name`, in place of the value it had. -/
def setCell (cells : Array (String × Value)) (name : String) (value : Value) :
    Array (String × Value) :=
  if cells.any (·.1 == name) then
    cells.map fun kept => if kept.1 == name then (name, value) else kept
  else cells.push (name, value)

namespace Table

/-- The workspace at `location`, if there is one. -/
def workspace? (table : Table) (location : Location) : Option Workspace :=
  (table.workspaces.find? (·.1.location == location)).map (·.1)

/-- The project of `identity`, if there is one. -/
def project? (table : Table) (identity : Project.Identity) : Option Project :=
  (table.projects.find? (·.1.identity == identity)).map (·.1)

/-- The value the workspace at `location` keeps under `name`. -/
def workspaceValue? (table : Table) (location : Location) (name : String) : Option Value := do
  let (_, cells) ← table.workspaces.find? (·.1.location == location)
  (← cells.find? (·.1 == name)).2

/-- The value the project of `identity` keeps under `name`. -/
def projectValue? (table : Table) (identity : Project.Identity) (name : String) : Option Value := do
  let (_, cells) ← table.projects.find? (·.1.identity == identity)
  (← cells.find? (·.1 == name)).2

/-- The value the unscoped store keeps under `name`. -/
def unscopedValue? (table : Table) (name : String) : Option Value :=
  (table.unscoped.find? (·.1 == name)).map (·.2)

/-- `table` with the unscoped store keeping `value` under `name`. Never
refused: the store is always there. -/
def setUnscopedValue (table : Table) (name : String) (value : Value) : Table :=
  { table with unscoped := setCell table.unscoped name value }

/-- `table` with `workspace` in it: a workspace already at its location
keeps its root, its project and its store, and takes `workspace`'s branch;
a new one joins the project of its identity, which is added with an empty
store if there is none. -/
def put (table : Table) (workspace : Workspace) : Table :=
  match table.workspace? workspace.location with
  | some _ =>
    { table with
      workspaces :=
        table.workspaces.map fun (kept, cells) =>
          if kept.location == workspace.location then
            ({ kept with branch := workspace.branch }, cells)
          else (kept, cells) }
  | none =>
    let project := (table.project? workspace.project.identity).getD workspace.project
    let projects :=
      if (table.project? project.identity).isSome then table.projects
      else table.projects.push (project, #[])
    { table with
      projects, workspaces := table.workspaces.push ({ workspace with project }, #[]) }

/-- `table` once the finder answered `found` for `directory` under the config
generation `generation`: the workspace added or its branch updated, and the
directory's answer cached. -/
def record (table : Table) (directory : System.FilePath) (generation : Nat) (found : Option Found) :
    Table :=
  let directory := Process.trimmed directory
  let (table, location) :=
    match found with
    | none => (table, none)
    | some found =>
      let location := Location.local found.root
      (table.put { location, branch := found.branch, project := found.project }, some location)
  { table with
    cache := (table.cache.filter (·.1 != directory)).push (directory, location, generation) }

/-- The cached answer for `directory` under the generation `generation`: the
location of its workspace or none; `none` when it was not asked under that
generation. -/
def cached? (table : Table) (directory : System.FilePath) (generation : Nat) :
    Option (Option Location) :=
  let directory := Process.trimmed directory
  (table.cache.find? fun (at_, _, found) => at_ == directory && found == generation).map (·.2.1)

/-- `table` with a workspace registered at `location`, a location that is
not on this machine, whose project is `remote`'s, with `branch` checked out
if it is given. Refused with `local` for a local location: those are found. -/
def register (table : Table) (location : Location) (remote : String) (branch : Option String) :
    Except WorkspaceRefusal Table :=
  match location with
  | .local _ => .error .local
  | _ =>
    .ok (table.put { location, branch := branch.map .named, project := Project.ofRemote remote })

/-- `table` with the workspace at `location` keeping `value` under `name`.
Refused with `noSuchWorkspace` when there is none. -/
def setWorkspaceValue (table : Table) (location : Location) (name : String) (value : Value) :
    Except WorkspaceRefusal Table :=
  if (table.workspace? location).isNone then .error (.noSuchWorkspace location)
  else
    .ok
      { table with
        workspaces :=
          table.workspaces.map fun (kept, cells) =>
            if kept.location == location then (kept, setCell cells name value) else (kept, cells) }

/-- `table` with the project of `identity` keeping `value` under `name`.
Refused with `noSuchProject` when there is none. -/
def setProjectValue (table : Table) (identity : Project.Identity) (name : String) (value : Value) :
    Except WorkspaceRefusal Table :=
  if (table.project? identity).isNone then .error (.noSuchProject identity)
  else
    .ok
      { table with
        projects :=
          table.projects.map fun (kept, cells) =>
            if kept.identity == identity then (kept, setCell cells name value) else (kept, cells) }

/-- The other workspaces of `workspace`'s project, in the order they were
added. -/
def others (table : Table) (workspace : Workspace) : Array Workspace :=
  (table.workspaces.map (·.1)).filter fun other =>
    other.project.identity == workspace.project.identity && other.location != workspace.location

end Table

end Workspace

end Editor
