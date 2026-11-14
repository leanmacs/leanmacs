import Editor.Api
import Editor.Command.Call
import Editor.Job

/-!
# Files: opening a file into a buffer, and saving a buffer

The commands that open a file and save a buffer, written over the editor
API (`Editor/Api.lean`) and the job port's file requests (`Editor/Job.lean`,
`Editor/File.lean`). A command may not wait and a job may, so each is three
programs: a command that starts a job, the job, which loads or saves the
file, and the job's command, which the loop runs like any command once the
job has ended (`Editor/Loop.lean`, "Jobs from commands"). The editor thread
never waits for a file.

`Editor.lean` imports this module, so config calls `Files.open` and
`Files.save`. The commands and the jobs as compiled code registers them
are in `Editor/Files/Compiled.lean`.

## Open

- **The command** (`Files.open view path`). When a buffer holds the path
  (`EditorState.findFile`: equality of the path string), it shows that
  buffer in the view and starts no job. Otherwise it starts the job
  `load-file` (`loadJob`) with a load order (`LoadOrder`): the path, and
  the view the command was called in, the asking view. It does not judge
  the path: the file port refuses one that is not absolute, and that
  refusal takes the route every refusal takes.
- **The job** (`loadWork`) loads the file (`File.load`), unless it is
  longer than a limit, and finishes with the order and the reply. A
  refusal is a value in the reply: the job throws only for arguments that
  are not an order.
- **The job's command** (`opened`) makes the buffer when the result is
  delivered. On a refusal it says so in the echo area (`notOpened`) and
  changes nothing else, so the window still shows what it showed. On
  success it makes a text of the snapshot the job loaded
  (`JobSnapshotId.toText`), adds a buffer over it, has the buffer hold the
  file (`BufferId.attachFile`: the path, the stamp the load answered, and
  the file's dominant line ending, or a line feed for a file with no line
  break), and shows the buffer (`ViewId.show`), with one cursor at its
  start. The buffer's history is a new tree, saved at its root, so the
  buffer is not modified.
- **The path is matched twice**: when the command runs, and again when the
  result is delivered. Two opens of one path can be in flight, and the
  first delivery makes the buffer: the second then shows that buffer and
  takes nothing in, so there is one buffer for the path.
- **The name** is the path's base name. When a buffer already has that
  name it is the base name followed by `<2>`, `<3>` and so on, the first
  that is free (`EditorState.freeName`), so a second file of one base name
  can be opened.
- **The window** is the asking view while it still has a window, and the
  focused view otherwise. When the command runs they are the same view;
  they differ only if the asking view was closed while the file loaded.
- **Nothing is made before the result.** An empty buffer made when the
  command runs and filled later would change the window before the file is
  known to exist, and a refusal would have to undo it. So events that
  arrive while the load is in flight are handled in the buffer the window
  still shows, before the load's result.
- **The limit** (`limit`) is 1 GiB. The file port has no default: the
  limit is the editor's policy, and this is it, a round number with no
  measurement behind it. A longer file is refused (`tooLarge`), which
  reaches the echo area. The job takes its limit as a parameter, so a test
  shows the refusal with a small one.
- **A start that is refused is said.** Where no job is registered under
  the load job's name, the command says so in the echo area (`notOpening`)
  and starts nothing.
- **What the state refuses is said too** (`notShown`): a buffer that could
  not be added, or shown in the asking view. The buffer and its text, if
  they were made, stay.

## Save

- **The command** (`Files.save id`) reads the buffer; tells a copy of its
  undo tree the revision its text is at and keeps that tree's state;
  takes a snapshot of the text; starts the job `save-file` (`saveJob`)
  with a save order (`SaveOrder`): the buffer, the snapshot, the file's
  path, and what the save expects to find there, the stamp the buffer
  holds; and records the save as in flight (`BufferId.beginSave`), with
  the snapshot and the kept state.
- **The job** (`saveWork`) saves the snapshot as the file (`File.save`)
  and finishes with the order and the reply. A refusal is a value in the
  reply: the job throws only for arguments that are not an order.
- **The job's command** (`saved`) makes one state request and then says
  what became of the file. The request ends the save in flight
  (`BufferId.endSave`): on success it records the stamp of the file the
  save wrote and marks the kept state as saved; on a refusal it changes
  neither. The echo area then reads `wrote <path>` (`wrote`), or the
  refusal (`notSaved`): a file that changed on disk since it was loaded is
  left as it is, and the buffer stays modified, with the stamp it had.
- **Why the editor state keeps the save in flight**
  (`Editor/State.lean`, "A buffer's file").
  - The job's command then asks the text store nothing. A command that
    makes state requests alone cannot be interrupted or refused
    (`Editor/Command/Dispatch.lean`, "A state request is not guarded"). So
    the interrupt key arriving as a save's result is delivered cannot
    leave a file written and a buffer that does not know it.
  - The snapshot is released by the loop, once the job's command has run
    to its end (`Editor/Loop.lean`, "What a finished command gave up"),
    not by the command. A command that released it itself and then set
    the stamp and the mark could be interrupted at the release, after the
    file was written, and the next save would be refused as changed on
    disk.
- **A save that reports late marks the state it wrote.** If the user edits
  while the save runs, the kept state is marked, the text is in a later
  one, and the buffer stays modified.
- **Nothing is translated.** The snapshot holds every byte of the file as
  it was loaded, so a buffer opened and saved with no edit leaves the
  file's bytes as they were, whatever its line endings.

## Every refusal takes one route

A refusal of the file port is a value (`FileError`), and reaches the echo
area through one function a command: `notOpened path error` is
`cannot open <path>: ` and the refusal's own sentence
(`FileError.describe`), and `notSaved path error` is `cannot save <path>: `
and that sentence. So "cannot read" and "cannot write", which are one
refusal of the port (`denied`), read differently. What a refusal says is
`Editor/File.lean`'s to change: a test compares the echo area with these
functions applied to the refusal it expects, never with the sentence.

## An order crosses as arguments

A job is started by its name with plain arguments (`startJob`), because a
request holds plain data. So what a file job is started with is a
structure, an order, with its encoding as a `List Argument` (`arguments`)
and the way back (`ofArguments?`), which undoes it.

Pinned by `ModelTest.fileCommandChecks`, on the loop's driver over the
editor's models and the model of files.
-/

namespace Editor.Files

/-- The longest file the open command loads, in bytes: 1 GiB. -/
def limit : Nat :=
  1 <<< 30

/-- The name the open command is registered under. -/
def openName : String :=
  "open-file"

/-- The name the job that loads a file is registered under. -/
def loadJob : String :=
  "load-file"

/-- What the load job is started with: the file to load, and the view to
show it in. -/
structure LoadOrder where
  /-- The file's path. -/
  path : System.FilePath
  /-- The view the open command was called in. -/
  view : ViewId
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with: the path, then the
view's number. -/
def LoadOrder.arguments (order : LoadOrder) : List Argument :=
  [.str order.path.toString, .nat order.view.index]

/-- The order `arguments` are, if they are one (`LoadOrder.arguments`). -/
def LoadOrder.ofArguments? : List Argument → Option LoadOrder
  | [.str path, .nat view] => some { path, view := ⟨view⟩ }
  | _ => none

/-- What the echo area says when the file at `path` could not be opened:
the refusal's own sentence, after the path. -/
def notOpened (path : System.FilePath) (error : FileError) : String :=
  s!"cannot open {path}: {error.describe}"

/-- What the echo area says when the job that loads `path` was not
started. -/
def notOpening (path : System.FilePath) (refusal : JobRefusal) : String :=
  s!"cannot open {path}: {refusal.describe}"

/-- What the echo area says when the file at `path` was loaded and the
editor state refused its buffer or refused to show it. -/
def notShown (path : System.FilePath) : String :=
  s!"loaded {path}, and could not show it"

/-- What the echo area says when the open command is called with no path. -/
def noPath : String :=
  s!"{openName}: no path to open"

/-- The command a finished load job hands the loop: what the reply to the
load of `order.path` becomes ("Open", in the module docs). -/
def opened (order : LoadOrder) (reply : Except FileError File.Loaded) : EditorM Unit := do
  match reply with
  | .error error =>
    message (notOpened order.path error)
  | .ok loaded =>
    let path := order.path
    let state ← editorState
    let view := if (state.window? order.view).isSome then order.view else state.frame.focused
    -- Another open of the path may have been delivered while this one's
    -- file loaded: the path is matched again, and nothing is taken in.
    if let some buffer := state.findFile path then
      let .ok () ← view.show buffer | message (notShown path)
      return
    let text ← loaded.snapshot.toText
    let name := state.freeName (path.fileName.getD path.toString)
    let .ok buffer ← addBuffer name text | message (notShown path)
    let .ok () ←
      buffer.attachFile path loaded.stamp
          (loaded.endings.dominant.getD .lf) | message (notShown path)
    let .ok () ← view.show buffer | message (notShown path)

/-- The load job: loads the file its order names, unless it is longer than
`limit` bytes, and finishes with what the reply becomes (`opened`). A
refusal is a value in the reply; it fails only for arguments that are not
an order. -/
def loadWork (limit : Nat := Files.limit) (arguments : List Argument) : Work := fun _ => do
  let some order :=
    LoadOrder.ofArguments? arguments | throw s!"{loadJob}: its arguments are not a load order"
  return opened order (← File.load order.path limit)

/-- Opens the file at `path` in `view`. When a buffer holds the path
(`EditorState.findFile`), it shows that buffer and starts nothing.
Otherwise it starts the job that loads the file, whose result makes the
buffer and shows it ("Open", in the module docs). Where no load job is
registered it says so in the echo area. -/
def «open» (view : ViewId) (path : System.FilePath) : EditorM Unit := do
  if let some buffer := (← editorState).findFile path then
    let .ok () ← view.show buffer | message (notShown path)
    return
  if let .error refusal← startJob loadJob (LoadOrder.arguments { path, view }) then
    message (notOpening path refusal)

/-- The open command as it is called: opens the path that is its first
argument, a string, in the window it was called with. With anything else
first, or nothing, it says so in the echo area. -/
def openCommand (call : Call) : EditorM Unit :=
  match call.arguments with
  | .str path :: _ => Files.open call.target.window.id path
  | _ => message noPath

/-- The name the save command is registered under. -/
def saveName : String :=
  "save-buffer"

/-- The name the job that saves a file is registered under. -/
def saveJob : String :=
  "save-file"

/-- What the save job is started with: the buffer that is saved, the
snapshot of its text to write, the file's path, and what the save expects
to find there. -/
structure SaveOrder where
  /-- The buffer that is saved. -/
  buffer : BufferId
  /-- The snapshot the save command took of the buffer's text. -/
  snapshot : SnapshotId
  /-- The file's path. -/
  path : System.FilePath
  /-- What the save expects to find at the path. -/
  expect : File.Expect
  deriving DecidableEq, Repr

/-- What a save expects, as arguments: a word, and after `unchanged` the
stamp's seconds, nanoseconds and size. -/
def expectArguments : File.Expect → List Argument
  | .unchanged stamp =>
    [.str "unchanged", .int stamp.seconds, .nat stamp.nanoseconds, .nat stamp.size]
  | .absent => [.str "absent"]
  | .whatever => [.str "whatever"]

/-- What a save expects, read back from its arguments (`expectArguments`). -/
def expectOfArguments? : List Argument → Option File.Expect
  | [.str "unchanged", .int seconds, .nat nanoseconds, .nat size] =>
    some (.unchanged { seconds, nanoseconds, size })
  | [.str "absent"] => some .absent
  | [.str "whatever"] => some .whatever
  | _ => none

/-- The order as the arguments a job is started with: the buffer's number,
the snapshot's, the path, and then what the save expects
(`expectArguments`). -/
def SaveOrder.arguments (order : SaveOrder) : List Argument :=
  [.nat order.buffer.index, .nat order.snapshot.index, .str order.path.toString] ++
    expectArguments order.expect

/-- The order `arguments` are, if they are one (`SaveOrder.arguments`). -/
def SaveOrder.ofArguments? : List Argument → Option SaveOrder
  | .nat buffer :: .nat snapshot :: .str path :: expect =>
    (expectOfArguments? expect).map fun expect =>
      { buffer := ⟨buffer⟩, snapshot := ⟨snapshot⟩, path, expect }
  | _ => none

/-- What the echo area says when the buffer's file at `path` could not be
saved: the refusal's own sentence, after the path. -/
def notSaved (path : System.FilePath) (error : FileError) : String :=
  s!"cannot save {path}: {error.describe}"

/-- What the echo area says when the file at `path` was written. -/
def wrote (path : System.FilePath) : String :=
  s!"wrote {path}"

/-- The command a finished save job hands the loop: what the reply to the
save of `order.buffer` becomes ("Save", in the module docs). It ends the
save in flight with one state request (`BufferId.endSave`), which records
the new stamp and marks the state the save wrote as saved, or neither for a
save that was refused, and then says what became of the file. It makes no
request of the text store, so it cannot be interrupted or refused. -/
def saved (order : SaveOrder) (reply : Except FileError File.Stamp) : EditorM Unit := do
  -- Refused only when the buffer was removed while its save ran: what
  -- became of the file is said all the same.
  discard <| order.buffer.endSave order.snapshot reply.toOption
  match reply with
  | .ok _ =>
    message (wrote order.path)
  | .error error =>
    message (notSaved order.path error)

/-- The save job: saves the snapshot its order names as the file at the
order's path, if what is there is what the order expects, and finishes with
what the reply becomes (`saved`). A refusal is a value in the reply; it
fails only for arguments that are not an order. -/
def saveWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    SaveOrder.ofArguments? arguments | throw s!"{saveJob}: its arguments are not a save order"
  return saved order (← File.save (.snapshot order.snapshot) order.path order.expect)

/-- Saves the buffer `id` to its file: takes a snapshot of its text, starts
the job that writes it, expecting the stamp the buffer holds, and records
the save as in flight ("Save", in the module docs). -/
def save (id : BufferId) : EditorM Unit := do
  let some buffer := (← editorState).buffer? id | return
  let some file := buffer.file | return
  -- The state the snapshot is of: the tree told the text's revision, which
  -- is not recorded here.
  let state := (← buffer.history.sync).state
  let snapshot ← buffer.text.snapshot
  let order : SaveOrder :=
    { buffer := id, snapshot, path := file.path, expect := .unchanged file.stamp }
  let .ok () ← startJob saveJob order.arguments | return
  discard <| id.beginSave snapshot state

/-- The save command as it is called: saves the buffer of the window it was
called with. -/
def saveCommand (call : Call) : EditorM Unit :=
  save call.target.window.buffer

end Editor.Files
