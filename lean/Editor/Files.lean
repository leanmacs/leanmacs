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
- **The minibuffer's view shows no file** (`shownIn`). While a prompt is
  open its view can be the one chosen: the focused view, when the asking
  view was closed and the result is delivered with the prompt open, or
  the asking view itself, when the command was called with a path while
  the minibuffer had the focus. The state refuses to show another buffer
  there. So the buffer is shown in the window of the tree the prompt was
  asked from, or in the first window of the tree when that one was closed
  too, the window the focus goes to when the prompt closes
  (`EditorState.askedFrom`), and the prompt stays open with the focus.
  This holds for a path that is already open as for one that is loaded.
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
- **A delivery that is interrupted leaves a text nobody holds.** The job's
  command makes requests of the text store, so the interrupt key can stop
  it. Its buffer and its window are rolled back, and the text it made is
  not released, as for every command (`Editor/Loop.lean`, "What is not
  undone"). The file is opened again.
- **The command as it is called asks for its path when it is given none**
  (`openCommand`). With a string as its first argument it opens that
  path. With anything else first, or nothing, it asks for the path with a
  prompt (`prompt`, `Editor/Api.lean`), labelled `openPrompt`, whose
  continuation is the open command itself with no argument of its own:
  when the prompt is accepted the command runs again with the answer as
  its first argument, in the view it was asked from
  (`docs/design/concurrency.md`, "Prompts"). A key bound to the command
  under the Vim scheme hands it a count and a register, so its first
  argument is no path, and it asks. Where the prompt is refused, because
  one is open, the echo area says so (`notAsking`), with the refusal's
  sentence.
- **Not built**: a buffer for a file that is not there yet. Opening a path
  with no file is an error. Saving under another name is not built
  either, and the save command does not ask for one: a buffer with a file
  needs no name, and one with no file needs a file that is not there yet,
  an attach with nothing expected on disk and a buffer renamed, which is
  more than a prompt.

## Save

- **The command** (`Files.save id`) reads the buffer; tells a copy of its
  undo tree the revision its text is at and keeps that tree's state;
  takes a snapshot of the text; starts the job `save-file` (`saveJob`)
  with a save order (`SaveOrder`): the buffer, the snapshot, the file's
  path, and what the save expects to find there, the stamp the buffer
  holds; and records the save as in flight (`BufferId.beginSave`), with
  the snapshot and the kept state.
- **What it refuses, it says, and starts nothing**: a buffer there is none
  of (`noBuffer`), a buffer that shows no file (`noFile`, with the
  buffer's name), and a buffer whose save is in flight (`beingSaved`).
  Two saves of one buffer in flight would both expect the stamp from
  before the first, and the second would be refused as changed on disk
  though nothing but the editor wrote the file; so the second is refused
  when it is asked, with a message that says why. Queueing it to run
  after the first is the alternative, and is more to build.
- **A start that is refused is said, and records no save.** The job is
  asked for before the save is recorded, and the save is recorded only
  when the job will be started. Where no job is registered under the save
  job's name, the command releases the snapshot it took and says so in
  the echo area (`notSaving`): the buffer is never left "being saved" with
  no job to end the save, and a later save is not refused for it.
- **A forced save** (`Files.save id true`) expects whatever is there
  (`File.Expect.whatever`), the port's override. Without it a buffer whose
  file changed on disk could never be saved, since nothing reloads one.
- **The job** (`saveWork`) saves the snapshot as the file (`File.save`)
  and finishes with the order and the reply. A refusal is a value in the
  reply: the job throws only for arguments that are not an order.
- **The job's command** (`saved`) makes one state request and then says
  what became of the file. The request ends the save in flight
  (`BufferId.endSave`): on success it records the stamp of the file the
  save wrote and marks the kept state as saved; on a refusal it changes
  neither. The echo area then reads `wrote <path>` (`wrote`), or the
  refusal (`notSaved`): a file that changed on disk since it was loaded is
  left as it is, and the buffer stays modified, with the stamp it had. A
  buffer removed while its save ran has no save to end: what became of
  the file is said all the same.
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

No check produces `denied`. The model of files has no permissions, and a
check that took a permission from a real file would fail where the gate
runs as root, in the Linux container. The route is the same for every
refusal, and the checks take it with `notFound`, `changed`, `tooLarge` and
`relativePath`.

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

/-- The label of the prompt the open command asks for its path with. -/
def openPrompt : String :=
  "Open file: "

/-- What the echo area says when the open command was called with no path
and could not ask for one: the refusal's own sentence, after the command's
name. -/
def notAsking (refusal : PromptRefusal) : String :=
  s!"{openName}: {refusal.describe}"

/-- The view a buffer is shown in when it is to be shown in `view`: `view`,
or, when `view` is the minibuffer's, which shows no other buffer, the
window of the tree the open prompt was asked from
(`EditorState.askedFrom`). -/
def shownIn (state : EditorState) (view : ViewId) : ViewId :=
  match state.prompt with
  | some asked => if asked.view == view then state.askedFrom asked else view
  | none => view

/-- The command a finished load job hands the loop: what the reply to the
load of `order.path` becomes ("Open", in the module docs). -/
def opened (order : LoadOrder) (reply : Except FileError File.Loaded) : EditorM Unit := do
  match reply with
  | .error error =>
    message (notOpened order.path error)
  | .ok loaded =>
    let path := order.path
    let state ← editorState
    let view :=
      shownIn state (if (state.window? order.view).isSome then order.view else state.frame.focused)
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
buffer and shows it ("Open", in the module docs). For the minibuffer's
view the buffer is shown in the window of the tree the prompt was asked
from (`shownIn`). Where no load job is registered it says so in the echo
area. -/
def «open» (view : ViewId) (path : System.FilePath) : EditorM Unit := do
  let state ← editorState
  if let some buffer := state.findFile path then
    let .ok () ← (shownIn state view).show buffer | message (notShown path)
    return
  if let .error refusal← startJob loadJob (LoadOrder.arguments { path, view }) then
    message (notOpening path refusal)

/-- The open command as it is called: opens the path that is its first
argument, a string, in the window it was called with. With anything else
first, or nothing, it asks for the path (`prompt`, labelled `openPrompt`),
with itself as the continuation: the answer is then its first argument,
and it runs in the view it was asked from. Where the prompt is refused,
because one is open, it says so in the echo area (`notAsking`). -/
def openCommand (call : Call) : EditorM Unit := do
  match call.arguments with
  | .str path :: _ =>
    Files.open call.target.window.id path
  | _ =>
    if let .error refusal← prompt openPrompt { command := openName } then
      message (notAsking refusal)

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

/-- What the echo area says when the buffer called `name`, which shows no
file, was to be saved. -/
def noFile (name : String) : String :=
  s!"{name} has no file to save to"

/-- What the echo area says when a buffer there is none of was to be
saved. -/
def noBuffer : String :=
  "no such buffer to save"

/-- What the echo area says when the buffer whose file is at `path` was to
be saved while a save of it is in flight. -/
def beingSaved (path : System.FilePath) : String :=
  s!"{path} is being saved"

/-- What the echo area says when the job that saves `path` was not
started. -/
def notSaving (path : System.FilePath) (refusal : JobRefusal) : String :=
  s!"cannot save {path}: {refusal.describe}"

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
the job that writes it, and records the save as in flight ("Save", in the
module docs). The save expects the stamp the buffer holds, or, with
`force`, whatever is there. It starts nothing, and says why in the echo
area, for a buffer there is none of, for one with no file and while a save
of the buffer is in flight. Where no save job is registered it says so,
releases the snapshot it took, and records no save. -/
def save (id : BufferId) (force : Bool := false) : EditorM Unit := do
  let some buffer := (← editorState).buffer? id | message noBuffer
  let some file := buffer.file | message (noFile buffer.name)
  if file.saving.isSome then
    message (beingSaved file.path)
    return
  -- The state the snapshot is of: the tree told the text's revision, which
  -- is not recorded here.
  let state := (← buffer.history.sync).state
  let snapshot ← buffer.text.snapshot
  let order : SaveOrder :=
    { buffer := id, snapshot, path := file.path
      expect := if force then .whatever else .unchanged file.stamp }
  -- The job is asked for before the save is recorded, and the save is
  -- recorded only when the job will be started: a buffer is never left
  -- "being saved" with no job to end the save.
  match ← startJob saveJob order.arguments with
  | .error refusal =>
    snapshot.release
    message (notSaving file.path refusal)
  | .ok () =>
    -- Not refused: this command read the buffer, with a file and no save
    -- in flight, and no other command runs between its requests.
    discard <| id.beginSave snapshot state

/-- The save command as it is called: saves the buffer of the window it was
called with, forced when its first argument is `true`. Its other arguments
are ignored: an input scheme hands a command a key is bound to arguments of
its own, a count and a register. -/
def saveCommand (call : Call) : EditorM Unit :=
  save call.target.window.buffer (call.arguments.head? == some (.bool true))

end Editor.Files
