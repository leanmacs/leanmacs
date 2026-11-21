import Editor.Api
import Editor.Command.Call
import Editor.Workspace.Finder
import Editor.Workspace.Modes

/-!
# A buffer's workspace, and `workspace-current`

How a buffer that holds a file comes to know its workspace, and the command
that says it. Written over the editor API (`Editor/Api.lean`, "Workspaces")
and the finder (`Editor/Workspace/Finder.lean`). A command may not wait and
a job may, so finding a workspace is three programs, as opening a file is
(`Editor/Files.lean`): a command that starts a job, the job, which runs the
finder, and the job's command, which records what it found.

`Editor/Files.lean` imports this module: its open calls `attach`. So this
module must not import `Editor.Files`. The command and the job as compiled
code registers them are in `Editor/Workspace/Compiled.lean`.

## Attach

- **When a file opens** (`attach`, called by `Files.takeIn` once the buffer
  holds the file), the workspace settings are asked of the loop
  (`RegistryRequest.workspaceSettings`): config's roots and the config
  generation. A cached answer for the file's directory under that
  generation (`Workspace.Table.cached?`) is the buffer's at once, and
  starts no job: a second file of a directory asks git nothing.
- **Otherwise the job `find-workspace` is started** (`findJob`) with a find
  order (`FindOrder`): the buffer, the directory, config's roots, the git
  program and the generation, as plain arguments.
- **A start that is refused is silent**, and the buffer has no workspace: a
  host that registers no find job finds none.
- **The job** (`findWork`) runs the finder (`Workspace.find`).
- **Its command** (`found`) records the answer (`recordWorkspace`), which
  caches the directory, and, while the buffer still holds a file in that
  directory, sets the buffer's local value to the workspace's location
  (`Workspace.bufferLocal`). It is made of state requests alone, so it
  cannot be interrupted.
- **A reload that installs is a new generation**, so the next file opened
  asks again: the cache is dropped as `Environments.install` drops the
  environments'. A buffer that is reloaded from its file keeps its
  workspace.
- **A buffer with no file** takes the workspace of the buffer it was made
  from (`BufferId.inheritWorkspace`), or none.

## Modes on markers

Once a file's workspace is known, its buffer is given the minor modes the
registered compile contributions' markers turn on (`markModes`,
`Editor/Workspace/Modes.lean`), looked for from the file's directory up to
the workspace's root, or in the directory alone when it has none: at once
from a cached answer, and from `found` once the finder has answered,
whether it found a workspace or not. With no contribution registered
nothing more is started.

## `workspace-current`

`current` says the workspace of a buffer, as a value (`Current`): its
label, its location, its branch and what its location can do; then its
project's name and identity; then the project's other open workspaces by
label (`Description`). A workspace is open when the table has it: found or
registered this session. A buffer with no workspace says so, with the
directory its file is in, which commands use instead (`noWorkspace`), or
that it has no file (`noFile`). `Current.text` says it for a person, and is
what the command shows.

Pinned by `ModelTest.workspaceChecks`, on the loop's driver over the
editor's models, the job model and the models of the processes and files:
what is said, on the value, and that the echo is its text.
-/

namespace Editor.Workspace

/-- The name the job that finds a directory's workspace is registered
under. -/
def findJob : String :=
  "find-workspace"

/-- What the find job is started with: the buffer, the directory of its
file, config's roots, the git program and the config generation. -/
structure FindOrder where
  /-- The buffer whose file opened. -/
  buffer : BufferId
  /-- The directory of its file. -/
  directory : System.FilePath
  /-- Config's workspace roots. -/
  roots : Array ConfigRoot := #[]
  /-- The git program. -/
  git : String := "git"
  /-- The config generation the answer is found under. -/
  generation : Nat
  deriving DecidableEq, Repr

/-- The settings the order's finder is handed. -/
def FindOrder.settings (order : FindOrder) : Settings :=
  { roots := order.roots, git := order.git }

/-- A config root as arguments: its path, then its project's name, or
`false` for none. -/
def rootArguments (root : ConfigRoot) : List Argument :=
  .str root.root.toString ::
    match root.project with
    | some project => [.str project]
    | none => [.bool false]

/-- The roots `arguments` are, if they are (`rootArguments`). -/
def rootsOf? : List Argument → Option (Array ConfigRoot)
  | [] => some #[]
  | .str root :: .str project :: rest =>
    (rootsOf? rest).map (#[{ root, project := some project }] ++ ·)
  | .str root :: .bool false :: rest => (rootsOf? rest).map (#[{ root }] ++ ·)
  | _ => none

/-- The order as the arguments a job is started with: the buffer's number,
the directory, the git program and the generation, then each root. -/
def FindOrder.arguments (order : FindOrder) : List Argument :=
  [.nat order.buffer.index, .str order.directory.toString, .str order.git, .nat order.generation] ++
    order.roots.toList.flatMap rootArguments

/-- The order `arguments` are, if they are one (`FindOrder.arguments`). -/
def FindOrder.ofArguments? : List Argument → Option FindOrder
  | .nat buffer :: .str directory :: .str git :: .nat generation :: roots =>
    (rootsOf? roots).map fun roots => { buffer := ⟨buffer⟩, directory, roots, git, generation }
  | _ => none

/-- What a buffer that holds the file at `path` is given when the file opens
("Attach", in the module docs): the cached workspace of its directory under
the config generation now, with no job, and its modes on markers looked for
("Modes on markers"); otherwise the find job is started, and a start that is
refused is silent. -/
def attach (id : BufferId) (path : System.FilePath) : EditorM Unit := do
  let some directory := path.parent | return
  let directory := Process.trimmed directory
  let (settings, generation) ← RegistryRequest.ask .workspaceSettings
  match (← editorState).workspaces.cached? directory generation with
  | some (some location) =>
    setBufferWorkspace id location
    markModes id directory (location.root?.getD directory) settings.markerModes
  | some none =>
    markModes id directory directory settings.markerModes
  | none =>
    -- Refused only when no find job is registered: then no buffer has a
    -- workspace, and nothing is said.
    discard <|
        startJob findJob
          (FindOrder.arguments
            { buffer := id, directory, roots := settings.roots, git := settings.git, generation })

/-- The command a finished find job hands the loop ("Attach", in the module
docs): the answer recorded, and, while the buffer still holds a file in the
order's directory, the buffer given the workspace, if one was found, and
its modes on markers looked for up to its root, or in the directory alone
("Modes on markers"). State requests alone. -/
def found (order : FindOrder) (answer : Option Found) : EditorM Unit := do
  discard <| EditorState.ask (.recordWorkspace order.directory order.generation answer)
  let some buffer := (← editorState).buffer? order.buffer | return
  let some file := buffer.file | return
  if (file.path.parent.map Process.trimmed) != some order.directory then
    return
  if let some answer := answer then
    setBufferWorkspace order.buffer (.local answer.root)
  let (settings, _) ← RegistryRequest.ask .workspaceSettings
  markModes order.buffer order.directory ((answer.map (·.root)).getD order.directory)
      settings.markerModes

/-- The find job: runs the finder for its order's directory with its order's
settings, and finishes with what the answer becomes (`found`). It fails
only for arguments that are not an order. -/
def findWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    FindOrder.ofArguments? arguments | throw s!"{findJob}: its arguments are not a find order"
  return found order (← find order.settings order.directory)

/-- The name `workspace-current` is registered under. -/
def currentName : String :=
  "workspace-current"

/-- What `workspace-current` says of a buffer with no workspace whose file
is in `directory`: commands use the directory instead. -/
def noWorkspace (directory : System.FilePath) : String :=
  s!"no workspace: {directory} is used"

/-- What `workspace-current` says of a buffer with no workspace and no
file. -/
def noFile : String :=
  "no workspace: the buffer has no file"

/-- The branch of a workspace, for a person. -/
def branchText : Option Branch → String
  | some (.named branch) => s!"on {branch}"
  | some .detached => "detached"
  | none => "no branch"

/-- What `workspace-current` says of a buffer's workspace, as a value. -/
structure Description where
  /-- The workspace's label, `name@branch` (`Workspace.label`). -/
  label : String
  /-- Where it is. -/
  location : Location
  /-- What is checked out there. -/
  branch : Option Branch
  /-- What its location lets the editor do. -/
  can : Location.Capabilities
  /-- Its project's name. -/
  projectName : String
  /-- Its project's identity. -/
  identity : Project.Identity
  /-- The labels of its project's other open workspaces. -/
  others : Array String
  deriving DecidableEq, Repr

/-- What `workspace-current` says of a buffer, as a value: its workspace,
or that it has none, with the directory its file is in or that it has no
file. -/
inductive Current where
  /-- The buffer has a workspace. -/
  | workspace (description : Description)
  /-- The buffer has no workspace, and its file is in `directory`. -/
  | noWorkspace (directory : System.FilePath)
  /-- The buffer has no workspace and no file. -/
  | noFile
  deriving DecidableEq, Repr

/-- What `workspace-current` says of the buffer `id` in `state`, as a value
("`workspace-current`", in the module docs). -/
def current (state : EditorState) (id : BufferId) : Current :=
  match state.workspaceOf? id with
  | some (workspace, project) =>
    .workspace
      { label := workspace.label, location := workspace.location, branch := workspace.branch
        can := workspace.location.can, projectName := project.name, identity := project.identity
        others := (state.workspaces.others workspace).map label }
  | none =>
    match ((state.buffer? id).bind (·.file)).bind (·.path.parent) with
    | some directory => .noWorkspace (Process.trimmed directory)
    | none => .noFile

/-- What `workspace-current` says, for a person. -/
def Current.text : Current → String
  | .workspace said =>
    let others := if said.others.isEmpty then "none" else ", ".intercalate said.others.toList
    s!"{said.label}: {said.location.describe}, {branchText said.branch}, {said.can.describe}; project {said.projectName}, {said.identity.describe}; other workspaces: {others}"
  | .noWorkspace directory => Workspace.noWorkspace directory
  | .noFile => Workspace.noFile

/-- `workspace-current`: says the workspace of the buffer of the window it
was called with in the echo area (`current`, as text). Its arguments are
ignored. -/
def currentCommand (call : Call) : EditorM Unit := do
  message (current (← editorState) call.target.window.buffer).text

end Editor.Workspace
