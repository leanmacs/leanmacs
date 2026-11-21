import Editor.Api
import Editor.Command.Call
import Editor.File.Model
import Editor.FileJobs
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Jumps
import Editor.Loop.Driver
import Editor.Package
import Editor.Test.Driver
import Editor.Test.Files
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Models

/-!
# The test kit: Opener

A file opener of the kit's own, written over the core's API, so that the
core's tests and the kit's drivers open and save a file without the files
feature (`Editor/Files.lean`), as the kit's minibuffer answers a prompt
without the minibuffer's package (`Editor/Test/Minibuffer.lean`).

- **`open-file`** (the core's `FileJobs.openFileCommand`), given paths,
  opens each in the window it was called with: a path a buffer holds is
  shown at once; any other is loaded by the job `test-load-file`, whose
  command records a jump in the window and makes a buffer over the text, named for the file, holding it,
  with the places a closed buffer of it left held again (`Jumps.attach`),
  then runs the `opened` runner, then shows it. A refused load says
  `cannot open <path>: <why>`. With no path it says so: it has no prompt.
- **`save-buffer`** saves the window's buffer (with `true`, whatever is on
  disk): a snapshot written by the job `test-save-file` over the file the
  buffer recorded, the save in flight recorded with `beginSave` and ended
  with `endSave`; a file written says `wrote <path>` and runs the `saved`
  runner.

Its jobs have names of their own, so they never take an order of the
files feature's. It makes none of the files feature's choices: no prompt,
no reload, no auto-reload, no language and no `code` mode.

The runners default to nothing. The interface library `files-api` makes
its fake of this opener with its hooks as the runners.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import").
-/

namespace Editor.Test.Opener

open Editor

/-- The name the opener's save command is registered under: the files
feature's, as text. -/
def saveName : String :=
  "save-buffer"

/-- The name of the opener's load job. -/
def loadJob : String :=
  "test-load-file"

/-- The name of the opener's save job. -/
def saveJob : String :=
  "test-save-file"

/-- What the echo area says of a file that could not be loaded. -/
def notOpened (path : System.FilePath) (error : FileError) : String :=
  s!"cannot open {path}: {error.describe}"

/-- What the echo area says of a save that was refused: the files feature's
sentence. -/
def notSaved (path : System.FilePath) (error : FileError) : String :=
  s!"cannot save {path}: {error.describe}"

/-- What the open command says when it is given no path. -/
def noPath : String :=
  s!"{FileJobs.openFileCommand}: the kit's opener asks for no path"

/-- The buffer of the file at `path`, whose load answered `loaded`: the
buffer that holds the path, if one does; otherwise a new buffer over the
loaded text, named for the file, holding it, its places held again, and
`opened` run. Shown in `view` when one is given. `none` when a step is
refused. -/
def adopt (opened : BufferId → System.FilePath → EditorM Unit) (path : System.FilePath)
    (loaded : File.Loaded) (view : Option ViewId := none) : EditorM (Option BufferId) := do
  let state ← editorState
  if let some buffer := state.findFile path then
    if let some view := view then
      let .ok () ← view.show buffer | return none
    return some buffer
  let text ← loaded.snapshot.toText
  let .ok buffer ← addBuffer (state.freeName (path.fileName.getD path.toString)) text | return none
  let .ok () ← buffer.attachFile path loaded.stamp (loaded.endings.dominant.getD .lf) | return none
  Jumps.attach buffer path
  opened buffer path
  if let some view := view then
    let .ok () ← view.show buffer | return none
  return some buffer

/-- The load job: loads the file at the path its arguments name and finishes
with the buffer made of it shown in the view they name, or the refusal
said. -/
def loadWork (opened : BufferId → System.FilePath → EditorM Unit) (arguments : List Argument) :
    Work := fun _ => do
  let [.str path, .nat view] := arguments | throw s!"{loadJob}: its arguments are not a load's"
  let reply ← File.load path (1 <<< 30)
  return do
    match reply with
    | .error error =>
      message (notOpened path error)
    | .ok loaded =>
      -- An open is a jump, recorded where the buffer is shown, as a file's
      -- open records one.
      Jumps.record ⟨view⟩
      discard <| adopt opened path loaded (some ⟨view⟩)

/-- Opens `path` in `view`: shows the buffer that holds it, or starts its
load. -/
def «open» (view : ViewId) (path : System.FilePath) : EditorM Unit := do
  if let some buffer := (← editorState).findFile path then
    Jumps.record view
    discard <| view.show buffer
  else if let .error refusal← startJob loadJob [.str path.toString, .nat view.index] then
    message s!"{FileJobs.openFileCommand}: {refusal.describe}"

/-- Visits `path` in `view` at the row `row`, column `column`: opens it, and
once a buffer holds it puts the cursor there; the opener visits only a path
a buffer holds, and opens any other. -/
def visit (view : ViewId) (path : System.FilePath) (row column : Nat) : EditorM Unit := do
  let some buffer := (← editorState).findFile path | «open» view path
  Jumps.record view
  let .ok () ← view.show buffer | return
  let some shown := (← editorState).buffer? buffer | return
  Jumps.placeCursor view (← Marks.offsetAt shown.text row column)

/-- The open command as it is called: each string argument a path, opened in
the window it was called with. -/
def openCommand (call : Call) : EditorM Unit := do
  let paths :=
    call.arguments.filterMap fun
      | .str path => some (System.FilePath.mk path)
      | _ => none
  if paths.isEmpty then
    message noPath
  for path in paths do
    «open» call.target.window.id path

/-- What a save's reply comes to: the save ended, `wrote <path>` or the
refusal said, and `saved` run for a file written. -/
def savedReply (saved : BufferId → EditorM Unit) (buffer : BufferId) (snapshot : SnapshotId)
    (path : System.FilePath) (reply : Except FileError File.Stamp) : EditorM Unit := do
  discard <| buffer.endSave snapshot reply.toOption
  match reply with
  | .ok _ =>
    message s!"wrote {path}"
    saved buffer
  | .error error =>
    message (notSaved path error)

/-- The save job: writes the snapshot its arguments name over the path,
expecting the stamp they carry, or whatever is there. -/
def saveWork (saved : BufferId → EditorM Unit) (arguments : List Argument) : Work := fun _ => do
  let .nat buffer :: .nat snapshot :: .str path :: rest :=
    arguments | throw s!"{saveJob}: its arguments are not a save's"
  let expect : File.Expect :=
    match rest with
    | [.int seconds, .nat nanoseconds, .nat size] => .unchanged { seconds, nanoseconds, size }
    | _ => .whatever
  let reply ← File.save (.snapshot ⟨snapshot⟩) path expect
  return savedReply saved ⟨buffer⟩ ⟨snapshot⟩ path reply

/-- Saves the buffer `id` to its file, expecting the stamp it recorded, or,
with `force`, whatever is there. Nothing for a buffer with no file or with
a save in flight. -/
def save (id : BufferId) (force : Bool := false) : EditorM Unit := do
  let some buffer := (← editorState).buffer? id | return
  let some file := buffer.file | message s!"{saveName}: {buffer.name} has no file"
  if file.saving.isSome then
    return
  let state := (← buffer.history.sync).state
  let snapshot ← buffer.text.snapshot
  let expect : List Argument :=
    if force then []
    else [.int file.stamp.seconds, .nat file.stamp.nanoseconds, .nat file.stamp.size]
  match
    ←
      startJob saveJob
          ([.nat id.index, .nat snapshot.index, .str file.path.toString] ++ expect) with
  | .error refusal =>
    snapshot.release
    message s!"{saveName}: {refusal.describe}"
  | .ok () =>
    discard <| id.beginSave snapshot state

/-- The save command as it is called: the window's buffer, forced when its
first argument is `true`. -/
def saveCommand (call : Call) : EditorM Unit :=
  save call.target.window.buffer (call.arguments.head? == some (.bool true))

/-- The opener as a package named `opener`: `open-file` and `save-buffer`,
and their jobs, with `opened` run once a buffer takes in a file and `saved`
once a save has written one. -/
def package (opened : BufferId → System.FilePath → EditorM Unit := fun _ _ => pure ())
    (saved : BufferId → EditorM Unit := fun _ => pure ()) : Package :=
  { name := "opener"
    setup := do
      commandWith FileJobs.openFileCommand openCommand
      commandWith saveName saveCommand
      workJob loadJob (loadWork opened)
      workJob saveJob (saveWork saved) }

/-- The opener's commands, under their names, as a driver dispatches them. -/
def commands : List (String × Dispatched) :=
  [(FileJobs.openFileCommand, fun call => do
      openCommand call
      return none),
    (saveName, fun call => do
      saveCommand call
      return none)]

/-- The opener's jobs, by name, as a driver starts them, with `opened` run
once a buffer takes in a file and `saved` once a save has written one. -/
def jobsWith (opened : BufferId → System.FilePath → EditorM Unit)
    (saved : BufferId → EditorM Unit := fun _ => pure ()) (name : String) :
    Option (List Argument → Work) :=
  if name == loadJob then some (loadWork opened)
  else if name == saveJob then some (saveWork saved) else none

/-- The opener's jobs, by name, with no runner. -/
def jobs (name : String) : Option (List Argument → Work) :=
  jobsWith (fun _ _ => pure ()) (fun _ => pure ()) name

/-- A driver over the initial state whose commands and jobs are the
opener's, over `files`: `C-o n` opens `note.txt`, `C-o o` runs the open
command with no path, and `C-o w` saves. -/
def driverOver (files : FileModel) : Option TestDriver :=
  let keys : Loop.Keys TestScheme.scheme :=
    dispatchKeys
      [("C-o n", opens (inFiles "note.txt")), ("C-o o", invoke FileJobs.openFileCommand),
        ("C-o w", invoke saveName)]
      commands
  (Loop.Driver.over keys jobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := { files } }

/-- `driverOver` the files of the file command checks (`commandFiles`). -/
def driver : Option TestDriver :=
  driverOver commandFiles

/-- `driver` with `note.txt` open in view 0: the open command, and its load
finished. The load is job 1. -/
def noteOpened : Option TestDriver :=
  driver.map fun driver => ((fedTo driver (presses "C-o n")).1.finish 1).1

end Editor.Test.Opener
