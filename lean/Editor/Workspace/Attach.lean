import Editor.Api
import Editor.Command.Call
import Editor.Workspace.Finder

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
  (`StateRequest.workspaceSettings`): config's roots and the config
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

## `workspace-current`

`describe` says the workspace of a buffer: its label, its location, its
branch and what its location can do; then its project's name and identity;
then the project's other open workspaces by label. A workspace is open when
the table has it: found or registered this session. A buffer with no
workspace says so, with the directory its file is in, which commands use
instead (`noWorkspace`), or that it has no file (`noFile`).

Pinned by `ModelTest.workspaceChecks`, on the loop's driver over the
editor's models, the job model and the models of the processes and files.
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

/-- Gives the buffer `id` the workspace at `location`, as its local value. -/
def setBufferWorkspace (id : BufferId) (location : Location) : EditorM Unit :=
  discard <| id.setValue bufferLocal location.encode

/-- What a buffer that holds the file at `path` is given when the file opens
("Attach", in the module docs): the cached workspace of its directory under
the config generation now, with no job; otherwise the find job is started,
and a start that is refused is silent. -/
def attach (id : BufferId) (path : System.FilePath) : EditorM Unit := do
  let some directory := path.parent | return
  let directory := Process.trimmed directory
  let (settings, generation) ← EditorState.ask .workspaceSettings
  match (← editorState).workspaces.cached? directory generation with
  | some (some location) =>
    setBufferWorkspace id location
  | some none =>
    pure ()
  | none =>
    -- Refused only when no find job is registered: then no buffer has a
    -- workspace, and nothing is said.
    discard <|
        startJob findJob
          (FindOrder.arguments
            { buffer := id, directory, roots := settings.roots, git := settings.git, generation })

/-- The command a finished find job hands the loop ("Attach", in the module
docs): the answer recorded, and, while the buffer still holds a file in the
order's directory, the buffer given the workspace. State requests alone. -/
def found (order : FindOrder) (answer : Option Found) : EditorM Unit := do
  discard <| EditorState.ask (.recordWorkspace order.directory order.generation answer)
  let some answer := answer | return
  let some buffer := (← editorState).buffer? order.buffer | return
  let some file := buffer.file | return
  if (file.path.parent.map Process.trimmed) != some order.directory then
    return
  setBufferWorkspace order.buffer (.local answer.root)

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

/-- What `workspace-current` says of the buffer `id` in `state`
("`workspace-current`", in the module docs). -/
def describe (state : EditorState) (id : BufferId) : String :=
  match state.workspaceOf? id with
  | some (workspace, project) =>
    let others := (state.workspaces.others workspace).map label
    let othersText := if others.isEmpty then "none" else ", ".intercalate others.toList
    s!"{workspace.label}: {workspace.location.describe}, {branchText workspace.branch}, {workspace.location.can.describe}; project {project.name}, {project.identity.describe}; other workspaces: {othersText}"
  | none =>
    match ((state.buffer? id).bind (·.file)).bind (·.path.parent) with
    | some directory => noWorkspace (Process.trimmed directory)
    | none => noFile

/-- `workspace-current`: says the workspace of the buffer of the window it
was called with in the echo area (`describe`). Its arguments are ignored. -/
def currentCommand (call : Call) : EditorM Unit := do
  message (describe (← editorState) call.target.window.buffer)

end Editor.Workspace
