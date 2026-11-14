import Editor.Api
import Editor.Command.Call
import Editor.Job

/-!
# Files: opening a file into a buffer

The command that opens a file, written over the editor API
(`Editor/Api.lean`) and the job port's file requests (`Editor/Job.lean`,
`Editor/File.lean`). A command may not wait and a job may, so opening is
three programs: a command that starts a job, the job, which loads the file,
and the job's command, which the loop runs like any command once the job
has ended (`Editor/Loop.lean`, "Jobs from commands"). The editor thread
never waits for a file.

`Editor.lean` imports this module, so config calls `Files.open`. The
commands and the jobs as compiled code registers them are in
`Editor/Files/Compiled.lean`.

## Open

- **The command** (`Files.open view path`) starts the job `load-file`
  (`loadJob`) with a load order (`LoadOrder`): the path, and the view the
  command was called in, the asking view. It does not judge the path: the
  file port refuses one that is not absolute, and that refusal takes the
  route every refusal takes.
- **The job** (`loadWork`) loads the file (`File.load`), unless it is
  longer than a limit, and finishes with the order and the reply. A
  refusal is a value in the reply: the job throws only for arguments that
  are not an order.
- **The job's command** (`opened`) makes the buffer when the result is
  delivered. On a refusal it says so in the echo area (`notOpened`) and
  changes nothing else, so the window still shows what it showed. On
  success it makes a text of the snapshot the job loaded
  (`JobSnapshotId.toText`), adds a buffer over it, called by the path's
  base name, has the buffer hold the file (`BufferId.attachFile`: the
  path, the stamp the load answered, and the file's dominant line ending,
  or a line feed for a file with no line break), and shows the buffer in
  the asking view (`ViewId.show`), with one cursor at its start. The
  buffer's history is a new tree, saved at its root, so the buffer is not
  modified.
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

## Every refusal takes one route

A refusal of the file port is a value (`FileError`), and reaches the echo
area through one function a command: `notOpened path error` is
`cannot open <path>: ` and the refusal's own sentence
(`FileError.describe`). What a refusal says is `Editor/File.lean`'s to
change: a test compares the echo area with this function applied to the
refusal it expects, never with the sentence.

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
    let text ← loaded.snapshot.toText
    let .ok buffer ← addBuffer (path.fileName.getD path.toString) text | message (notShown path)
    let .ok () ←
      buffer.attachFile path loaded.stamp
          (loaded.endings.dominant.getD .lf) | message (notShown path)
    let .ok () ← order.view.show buffer | message (notShown path)

/-- The load job: loads the file its order names, unless it is longer than
`limit` bytes, and finishes with what the reply becomes (`opened`). A
refusal is a value in the reply; it fails only for arguments that are not
an order. -/
def loadWork (limit : Nat := Files.limit) (arguments : List Argument) : Work := fun _ => do
  let some order :=
    LoadOrder.ofArguments? arguments | throw s!"{loadJob}: its arguments are not a load order"
  return opened order (← File.load order.path limit)

/-- Opens the file at `path` in `view`: starts the job that loads it, whose
result makes the buffer and shows it ("Open", in the module docs). Where no
load job is registered it says so in the echo area. -/
def «open» (view : ViewId) (path : System.FilePath) : EditorM Unit := do
  if let .error refusal← startJob loadJob (LoadOrder.arguments { path, view }) then
    message (notOpening path refusal)

/-- The open command as it is called: opens the path that is its first
argument, a string, in the window it was called with. With anything else
first, or nothing, it says so in the echo area. -/
def openCommand (call : Call) : EditorM Unit :=
  match call.arguments with
  | .str path :: _ => Files.open call.target.window.id path
  | _ => message noPath

end Editor.Files
