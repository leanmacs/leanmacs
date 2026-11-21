import Editor.Api

/-!
# The interface library `shell-api`

The interface library `shell-api`, staged in the core's Lake package as its
own `lean_lib` with the layout and names it will have as the package
`packages/shell-api/` (`lean/lakefile.lean`, `lean_lib ShellApi`): the
contract between the shell (`Editor/Shell.lean`), which implements it, and
what others take of it. Ex, still in the core, binds `:!` to the shell's
commands by name and offers the history of the lines run on its prompt;
the compile mode copies the history's store and its rule. So it stays
staged until ex moves out (the features-as-packages roadmap's phase 8). It
imports only the core's API, and its test library (`ShellApiTest`) only
that, this library and the core's test kit.

## Its names

`shell-command` (`commandName`), handed the shell text and the ex line;
`shell-filter` (`filterName`), handed the range's first and last line, the
text and the line; `keyboard-quit` (`interruptName`), which the Vim scheme
binds to `C-g`; every one of them (`names`); and what a `:!` with nothing
after it says (`noCommand`).

## The history

The ex lines run, newest first, each once, at most `historyLimit`, kept per
scope (`Scope`): the project of the window's buffer's workspace, or the
unscoped store outside any (`history`, `record`, `remember`), in the store
`shell-history` (`historyStore`), whose codec the implementation registers
so it is kept across a restart. These keep the shell's names
(`Editor.Shell.…`): they use only the core's API, so the shell's callers
are unchanged.

Its test library publishes a fake (`ShellApiTest.fake`, the three commands
over the core's API, its `shell-command` recording the line) and the
contract check every implementation runs (`ShellApiTest.contractChecks`).
-/

namespace ShellApi

/-- The name of the command that runs a shell command. -/
def commandName : String :=
  "shell-command"

/-- The name of the command that filters lines through a shell command. -/
def filterName : String :=
  "shell-filter"

/-- The name of the command that cancels the run in flight: the Vim scheme
binds `C-g` to it. -/
def interruptName : String :=
  "keyboard-quit"

/-- Every command name this interface declares, in the order the shell
registers them. -/
def names : Array String :=
  #[commandName, filterName, interruptName]

/-- What the echo area says for `:!` with nothing after it. -/
def noCommand : String :=
  "!: no command"

end ShellApi

namespace Editor.Shell

/-- How many lines a scope's history keeps. -/
def historyLimit : Nat :=
  100

/-! ## The scope and its history -/

/-- Where a run belongs: a workspace and its project, or outside any. -/
inductive Scope where
  /-- The focused buffer's workspace and its project. -/
  | workspace (workspace : Workspace) (project : Project)
  /-- The buffer has no workspace, and so no project. -/
  | outside
  deriving DecidableEq, Repr

/-- The scope of the buffer `buffer` in `state`. -/
def Scope.of (state : EditorState) (buffer : BufferId) : Scope :=
  match state.workspaceOf? buffer with
  | some (found, project) => .workspace found project
  | none => .outside

/-- The location of a scope's workspace, `none` outside any. -/
def Scope.location? : Scope → Option Location
  | .workspace found _ => some found.location
  | .outside => none

/-- The job key of the scope whose workspace is at `location`, or of the one
outside any workspace ("The scope", in the module docs). -/
def keyOf : Option Location → String
  | some location => s!"shell {location.describe}"
  | none => "shell outside"

/-- The ex lines run in a scope, newest first, each once. -/
def historyStore : Store (Array String) :=
  { name := "shell-history", version := 1, initial := #[]
    encode := fun lines => .list (lines.toList.map .str)
    decode := fun
      | .list items =>
        items.toArray.mapM fun
          | .str line => some line
          | _ => none
      | _ => none }

/-- The history of the buffer `buffer`'s scope: its project's, or the
unscoped store's ("The scope", in the module docs). -/
def history (state : EditorState) (buffer : BufferId) : Array String :=
  match Scope.of state buffer with
  | .workspace _ project => state.workspaces.getOfProject historyStore project.identity
  | .outside => state.workspaces.getUnscoped historyStore

/-- `lines` with `line` first, and no other copy of it, cut at
`historyLimit`. -/
def remember (line : String) (lines : Array String) : Array String :=
  (#[line] ++ lines.filter (· != line)).extract 0 historyLimit

/-- Records `line` in the history of `scope`: its project's, or the unscoped
store's. -/
def record (scope : Scope) (line : String) : EditorM Unit := do
  let state ← editorState
  match scope with
  | .workspace _ project =>
    let lines := state.workspaces.getOfProject historyStore project.identity
    discard <| Project.set historyStore project.identity (remember line lines)
  | .outside =>
    Workspace.setUnscoped historyStore (remember line (state.workspaces.getUnscoped historyStore))

end Editor.Shell
