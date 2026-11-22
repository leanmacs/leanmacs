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
feature (`packages/files/Files.lean`), as the kit's minibuffer answers a prompt
without the minibuffer's package (`Editor/Test/Minibuffer.lean`).

- **`open-file`** (the core's `FileJobs.openFileCommand`), given paths,
  opens each in the window it was called with: a path a buffer holds is
  shown at once; any other is loaded by the job `test-load-file`, whose
  command records a jump in the window and makes a buffer over the text, named for the file, holding it,
  with the places a closed buffer of it left held again (`Jumps.attach`),
  then runs the `opened` runner, then shows it, and records the language
  the registry's table chooses for the path (`languageOf`), as the files
  feature does. A refused load says `cannot open <path>: <why>`, the text
  `files-api` declares (`FilesApi.notOpened`). With no path it says so: it
  has no prompt.
- **A visit** (`visit`) is an open at a point: once the buffer is shown,
  at once when a buffer holds the path and when the load lands otherwise,
  the view's cursor goes to the row and column, or the row's first
  non-blank, and the view is focused when asked. It records a jump in the
  view unless asked not to, as the jump commands ask.
- **`save-buffer`** saves the window's buffer (with `true`, whatever is on
  disk): a snapshot written by the job `test-save-file` over the file the
  buffer recorded, the save in flight recorded with `beginSave` and ended
  with `endSave`; a file written says `wrote <path>` and runs the `saved`
  runner.

Its jobs have names of their own, so they never take an order of the
files feature's. It makes none of the files feature's choices: no prompt,
no reload, no auto-reload and no `code` mode.

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
loaded text, named for the file, holding it, its places held again,
`opened` run, and the language the registry's table chooses for the path
(`languageOf`) recorded. Shown in `view` when one is given. `none` when a
step is refused. -/
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
  -- The language the registry's table chooses for the path, as the files
  -- feature records it; no mode is set.
  if let some language← languageOf path then
    discard <| buffer.setLanguage (some language)
  return some buffer

/-- Where a visit puts the cursor once the buffer is shown: a row and a
column in characters, or the row's first non-blank; whether the view is
focused; and whether the visit records a jump. -/
structure Point where
  /-- The row, from 0. -/
  row : Nat
  /-- The column, in characters from the row's start. -/
  column : Nat
  /-- Whether the cursor goes to the row's first non-blank instead. -/
  firstNonBlank : Bool := false
  /-- Whether the view is focused. -/
  focus : Bool := false
  /-- Whether a jump is recorded in the view (`Jumps.record`). -/
  record : Bool := true

/-- The load job's arguments for `path` in `view`: an open's, or, with a
point, a visit's. -/
def loadArguments (path : System.FilePath) (view : ViewId) : Option Point → List Argument
  | none => [.str path.toString, .nat view.index]
  | some point =>
    [.str path.toString, .nat view.index, .nat point.row, .nat point.column,
      .bool point.firstNonBlank, .bool point.focus, .bool point.record]

/-- The path, the view and the point (none for an open) the load job's
arguments name; `none` for arguments that are not a load's. -/
def loadOf? : List Argument → Option (System.FilePath × ViewId × Option Point)
  | [.str path, .nat view] => some (path, ⟨view⟩, none)
  | [.str path, .nat view, .nat row, .nat column, .bool firstNonBlank, .bool focus, .bool record] =>
    some (path, ⟨view⟩, some { row, column, firstNonBlank, focus, record })
  | _ => none

/-- Puts the cursor of `view`, which shows `buffer`, at `point`, and focuses
the view when the point says so. -/
def placeAt (view : ViewId) (buffer : BufferId) (point : Point) : EditorM Unit := do
  let some shown := (← editorState).buffer? buffer | return
  let offset ← Marks.offsetAt shown.text point.row point.column
  Jumps.placeCursor view (← Jumps.offsetOn shown.text offset point.firstNonBlank)
  if point.focus then
    discard <| view.focus

/-- The load job: loads the file at the path its arguments name and finishes
with the buffer made of it shown in the view they name, the cursor at the
visit's point when they carry one, or the refusal said. -/
def loadWork (opened : BufferId → System.FilePath → EditorM Unit) (arguments : List Argument) :
    Work := fun _ => do
  let some (path, view, point) := loadOf? arguments
    | throw s!"{loadJob}: its arguments are not a load's"
  let reply ← File.load path (1 <<< 30)
  return do
    match reply with
    | .error error =>
      message (notOpened path error)
    | .ok loaded =>
      -- An open is a jump, recorded where the buffer is shown, as a file's
      -- open records one; a visit records one when it says so.
      if point.all (·.record) then
        Jumps.record view
      let some buffer ← adopt opened path loaded (some view) | return
      if let some point := point then
        placeAt view buffer point

/-- Opens `path` in `view`, and with a point visits it: shows the buffer
that holds it, with the cursor at the point, at once, or starts its load,
which places it once the buffer is shown. A jump is recorded unless the
point says not to. -/
def openAt (view : ViewId) (path : System.FilePath) (point : Option Point) : EditorM Unit := do
  if let some buffer := (← editorState).findFile path then
    if point.all (·.record) then
      Jumps.record view
    let .ok () ← view.show buffer | return
    if let some point := point then
      placeAt view buffer point
  else if let .error refusal← startJob loadJob (loadArguments path view point) then
    message s!"{FileJobs.openFileCommand}: {refusal.describe}"

/-- Opens `path` in `view`: shows the buffer that holds it, or starts its
load. -/
def «open» (view : ViewId) (path : System.FilePath) : EditorM Unit :=
  openAt view path none

/-- Visits `path` in `view` at `point`: the buffer is shown with the cursor
at the point, at once when a buffer holds the path and once its load lands
otherwise, the view focused and a jump recorded when the point says so. -/
def visit (view : ViewId) (path : System.FilePath) (point : Point) : EditorM Unit :=
  openAt view path (some point)

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

/-- A save's follow-up job as arguments: `false` for none, otherwise `true`,
its name, the count of its arguments and they, and its key or `false`. -/
def afterArguments : Option JobStart → List Argument
  | none => [.bool false]
  | some start =>
    [.bool true, .str start.name, .nat start.arguments.length] ++ start.arguments ++
      [match start.key with
        | some key => .str key
        | none => .bool false]

/-- The follow-up job `arguments` begin with (`afterArguments`), and what
follows it; `none` for arguments that are not one. -/
def afterOf? : List Argument → Option (Option JobStart × List Argument)
  | .bool false :: rest => some (none, rest)
  | .bool true :: .str name :: .nat count :: rest =>
    match rest.drop count with
    | .str key :: after =>
      some (some { name, arguments := rest.take count, key := some key }, after)
    | .bool false :: after => some (some { name, arguments := rest.take count }, after)
    | _ => none
  | _ => none

/-- What a save's reply comes to: the save ended, `wrote <path>` or the
refusal said, and for a file written `saved` run and the follow-up job
`after` started. -/
def savedReply (saved : BufferId → EditorM Unit) (buffer : BufferId) (snapshot : SnapshotId)
    (path : System.FilePath) (after : Option JobStart) (reply : Except FileError File.Stamp) :
    EditorM Unit := do
  discard <| buffer.endSave snapshot reply.toOption
  match reply with
  | .ok _ =>
    message s!"wrote {path}"
    saved buffer
    if let some start := after then
      if let .error refusal← startJob start.name start.arguments start.key then
        message s!"{start.name}: {refusal.describe}"
  | .error error =>
    message (notSaved path error)

/-- The save job: writes the snapshot its arguments name over the path,
expecting the stamp they carry, or whatever is there, and finishes with
what the reply comes to (`savedReply`). -/
def saveWork (saved : BufferId → EditorM Unit) (arguments : List Argument) : Work := fun _ => do
  let .nat buffer :: .nat snapshot :: .str path :: rest :=
    arguments | throw s!"{saveJob}: its arguments are not a save's"
  let some (after, rest) := afterOf? rest | throw s!"{saveJob}: its arguments are not a save's"
  let expect : File.Expect :=
    match rest with
    | [.int seconds, .nat nanoseconds, .nat size] => .unchanged { seconds, nanoseconds, size }
    | _ => .whatever
  let reply ← File.save (.snapshot ⟨snapshot⟩) path expect
  return savedReply saved ⟨buffer⟩ ⟨snapshot⟩ path after reply

/-- Saves the buffer `id` to its file, expecting the stamp it recorded, or,
with `force`, whatever is there, and once the file is written starts
`after`. Nothing for a buffer with no file or with a save in flight. -/
def save (id : BufferId) (force : Bool := false) (after : Option JobStart := none) : EditorM Unit :=
  do
  let some buffer := (← editorState).buffer? id | return
  let some file := buffer.file | message s!"{saveName}: {buffer.name} has no file"
  if file.saving.isSome then
    return
  let state := (← buffer.history.sync).state
  let snapshot ← buffer.text.snapshot
  let expect : List Argument :=
    if force then []
    else [.int file.stamp.seconds, .nat file.stamp.nanoseconds, .nat file.stamp.size]
  let arguments :=
    [.nat id.index, .nat snapshot.index, .str file.path.toString] ++ afterArguments after ++ expect
  match ← startJob saveJob arguments with
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
