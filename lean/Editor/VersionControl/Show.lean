import Editor.Api
import Editor.Command.Call
import Editor.Files
import Editor.VersionControl.Git
import Editor.VersionControl.Views

/-!
# A file at a revision: `vc-show`

Opens what a file held at a revision as a read-only buffer with no file,
magit's `magit-find-file`. Written over the editor API (`Editor/Api.lean`),
the job port and the version-control interface's `fileAt`
(`Editor/VersionControl.lean`), through its git implementation. A command
may not wait and a job may, so it is the command, the job
`vc-show-read`, which asks git, and the command it finishes with
(`revisionShown`), which makes the buffer.

## The command

`vc-show` (`showName`) takes text (the ex binding's `takes := .text`):

- **`<revision> <path>`**: the revision is the text up to its first
  space, and the path everything after that one space, spaces and all,
  relative to the root of the focused buffer's workspace.
- **`<revision>`** alone: the focused buffer's file, relative to its
  workspace's root.
- **No text**: the focused buffer's file at `HEAD`.
- **Refused before any job runs**, each said as `vc-show: <why>`: a
  revision that starts with `-`, which git would read as an option; a
  buffer with no workspace, or one whose location cannot run commands; no
  path given and a buffer with no file, or a file outside its workspace's
  root.

Otherwise it starts `vc-show-read`, keyed `vc-show <root> <revision>:<path>`
(`keyOf`), so asking again for the same file replaces the first ask.

## What the read comes to (`revisionShown`)

- **`none`** says `vc-show: <path> is not in <revision>`: a revision that
  does not have the path, or is not there.
- **A failure** says `vc-show: <Error.describe>`.
- **Content** makes a buffer named `<path>@<revision>`, or the first free
  name of that (`EditorState.freeName`), holding it, read-only, with no
  file, given the workspace, and shown where the display rules say for the
  opener `vc-show` from the asking view, or the focused one when that is
  gone. The language the registry's table chooses for the path's name
  (`languageOf`) is recorded and its `code` mode set, as a file's open does,
  so the old text is drawn as the file is.

Pinned by `ModelTest.revisionBufferChecks` on the models and
`ContractTest.statusBufferChecks` over real git.
-/

namespace Editor.VersionControl

/-- The name `vc-show` is registered under, and the opener its buffer is
shown for. -/
def showName : String :=
  "vc-show"

/-- The name its read job is registered under. -/
def showJob : String :=
  "vc-show-read"

/-- What a read of a file at a revision is started with. -/
structure ShowOrder where
  /-- The repository's root, the workspace's. -/
  root : System.FilePath
  /-- The git program. -/
  git : String
  /-- The revision. -/
  revision : String
  /-- The path, relative to the root. -/
  path : String
  /-- The view that asked. -/
  view : ViewId
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with. -/
def ShowOrder.arguments (order : ShowOrder) : List Argument :=
  [.str order.root.toString, .str order.git, .str order.revision, .str order.path,
    .nat order.view.index]

/-- The order `arguments` are, if they are one (`ShowOrder.arguments`). -/
def ShowOrder.ofArguments? : List Argument → Option ShowOrder
  | [.str root, .str git, .str revision, .str path, .nat view] =>
    some { root, git, revision, path, view := ⟨view⟩ }
  | _ => none

/-- The job key of the reads of `path` at `revision` in the repository at
`root`. -/
def ShowOrder.key (order : ShowOrder) : String :=
  s!"{showName} {(Location.local order.root).describe} {order.revision}:{order.path}"

/-- The revision and the path `text` asks for ("The command", in the module
docs): the revision up to the first space and the path after it, or the
whole text as the revision and no path; `HEAD` and no path for no text. -/
def showTarget (text : String) : String × Option String :=
  if text.isEmpty then ("HEAD", none)
  else
    match text.splitOn " " with
    | [revision] => (revision, none)
    | revision :: rest => (revision, some (" ".intercalate rest))
    | [] => ("HEAD", none)

/-- `path`, which is absolute, relative to `root`, when it is under it. -/
def relativeTo (root path : System.FilePath) : Option String :=
  let lead := root.toString ++ if root.toString.endsWith "/" then "" else "/"
  if path.toString.startsWith lead then some (path.toString.drop lead.length).toString else none

/-- The command a finished read hands the loop ("What the read comes to", in
the module docs). -/
def revisionShown (order : ShowOrder) (reply : Except Error (Option String)) : EditorM Unit := do
  match reply with
  | .error error =>
    message s!"{showName}: {error.describe}"
  | .ok none =>
    message s!"{showName}: {order.path} is not in {order.revision}"
  | .ok (some content) =>
    let some id ←
      readOnlyBufferOf s!"{order.path}@{order.revision}" content (.local order.root) | return
    displayFor id order.view showName
    if let some language← languageOf (order.root / order.path) then
      discard <| id.setLanguage (some language)
      discard <| id.setMajorMode Language.codeName

/-- The read job: asks its order's repository for the file at the revision
through git, and finishes with what it comes to (`revisionShown`). It fails
only for arguments that are not an order. -/
def showWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    ShowOrder.ofArguments? arguments | throw s!"{showJob}: its arguments are not a show order"
  return revisionShown order
      (← Program.runM (Git.handler order.git order.root) (fileAt order.revision order.path))

/-- `vc-show` ("The command", in the module docs). -/
def showCommand (call : Call) : EditorM Unit := do
  let text :=
    match call.arguments with
    | .str text :: _ => text.trimAscii.toString
    | _ => ""
  let (revision, path?) := showTarget text
  if revision.startsWith "-" then
    message s!"{showName}: {revision} is not a revision"
    return
  let state ← editorState
  let buffer := call.target.window.buffer
  let some (workspace, _) :=
    state.workspaceOf? buffer | message s!"{showName}: {call.target.buffer.name} has no workspace"
  let .local root :=
    workspace.location | message s!"{showName}: {workspace.label} cannot run commands"
  unless workspace.location.can.runCommands do
    message s!"{showName}: {workspace.label} cannot run commands"
    return
  let path? :=
    path? <|> ((state.buffer? buffer).bind (·.file)).bind fun file => relativeTo root file.path
  let some path :=
    path? | message s!"{showName}: {call.target.buffer.name} has no file in {workspace.label}"
  let order : ShowOrder :=
    { root, git := (← RegistryRequest.ask .workspaceSettings).1.git, revision, path
      view := call.target.window.id }
  if let .error refusal← startJob showJob order.arguments (key := some order.key) then
    message s!"{showName}: {refusal.describe}"

end Editor.VersionControl
