import Editor.Command.Call
import Editor.State
import Editor.Workspace

/-!
# What a search covers

The one rule every search of a workspace's files decides what it searches
by, pure, from the editor state and the call: the finder of a workspace's
files (`Editor/Workspace/FindFile.lean`, which adds the lister) and project
search (`Editor/ProjectSearch/Run.lean`). It is a core module, so a search
reaches the rule through the core and imports no other feature for it.

Its declarations are in `Editor.Workspace` (`Workspace.SearchRoot`,
`Workspace.searchRoot`), beside the data they read (`Editor/Workspace.lean`).
They are a module of their own because they take the editor state and a
command's call, and `Editor/Workspace.lean` sits below both
(`Editor/State.lean` imports it): in that module they would make an import
cycle.

## The rule (`searchRoot`)

- **A location as the command's argument** (`Location.arguments`, the
  first arguments): the workspace the table has there, refused with
  `Workspace.noSuchWorkspace` when it has none. A text after the location
  (`Workspace.typedOf`) is the text typed when the search opens.
- **Otherwise the workspace of the buffer of the window it was called
  with.**
- **A workspace whose location cannot both read files and run commands**
  (`Location.can`) is refused with `Workspace.cannotList`, which names it.
- **Otherwise its root** is searched, its label (`Workspace.label`,
  `name@branch`) names it, and the workspace is handed on, so a finder
  chooses its lister for it.
- **A buffer with no workspace** is searched in the directory a command
  run for it would use (`EditorState.commandDirectoryOf`,
  `Editor/State.lean`): its file's directory, or the editor's working
  directory for a buffer with no file. The directory is its label, and no
  workspace is handed on.
- **Other arguments**, such as a count and a register a Vim key hands a
  command, are ignored.

Each refusal names the command it is handed, the one that searched.

Pinned by `ModelTest.searchRootChecks`, and through the finder by
`ModelTest.findFileChecks`.
-/

namespace Editor.Workspace

/-- What a search covers: the root it runs at, the label naming it, the text
typed when it opens, and the workspace, when it searches one. -/
structure SearchRoot where
  /-- The root: an absolute path on this machine. -/
  root : System.FilePath
  /-- What names it: the workspace's label, or the directory searched. -/
  label : String
  /-- The text typed when the search opens: the one after a location given
  as the command's argument, or none. -/
  typed : String := ""
  /-- The workspace searched; none for a buffer with no workspace. -/
  workspace : Option Workspace := none
  deriving DecidableEq, Repr

/-- What is searched in `workspace` ("The rule", in the module docs): its
root, its label and the workspace; refused with `cannotList`, naming
`command`, when its location cannot read files and run commands. -/
def SearchRoot.ofWorkspace (workspace : Workspace) (command : String) : Except String SearchRoot :=
  let can := workspace.location.can
  match workspace.location.root? with
  | some root =>
    if can.readFiles && can.runCommands then
      .ok { root, label := workspace.label, workspace := some workspace }
    else .error (cannotList workspace command)
  | none => .error (cannotList workspace command)

/-- What `call` searches in `state` ("The rule", in the module docs), or what
`command` says instead. -/
def searchRoot (state : EditorState) (call : Call) (command : String) : Except String SearchRoot :=
  match Location.of? call.arguments with
  | some (location, rest) =>
    match state.workspaces.workspace? location with
    | some workspace =>
      (SearchRoot.ofWorkspace workspace command).map fun root => { root with typed := typedOf rest }
    | none => .error (noSuchWorkspace location command)
  | none =>
    let buffer := call.target.window.buffer
    match state.workspaceOf? buffer with
    | some (workspace, _) => SearchRoot.ofWorkspace workspace command
    | none =>
      let directory := state.commandDirectoryOf buffer
      .ok { root := directory, label := directory.toString }

end Editor.Workspace
