import Editor.Language
import Editor.Workspace.Attach

/-!
# Files: opening a file into a buffer, saving a buffer, and reloading one

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
- **Workspace.** Once the buffer holds the file, `opened` hands it to
  `Workspace.attach` (`Editor/Workspace/Attach.lean`): the cached
  workspace of the file's directory is the buffer's at once, and otherwise
  the job `find-workspace` is started to find it, a start that is refused
  being silent. A path a buffer already holds is shown and asks nothing.
- **Language.** Once the buffer is shown, `opened` asks which language the
  registry's table chooses for the path (`languageOf`, `Language.forPath`,
  `Editor/Language.lean`). For one, the buffer records its name and its
  major mode is set to `code` (`Language.codeMode`), in that order, so the
  mode's entry, inside this command, attaches and highlights the text as
  the language says (`Editor/Command/Dispatch.lean`). For none, nothing is
  recorded and no mode is set: the buffer opens with no major mode and the
  syntax tree port is asked nothing. A path a buffer already holds is shown,
  and nothing is chosen again. The minor modes a file's markers turn on
  (`Editor/Workspace/Modes.lean`) come later, from the marker job that
  `Workspace.attach` starts, in that job's own command: setting the major
  mode leaves a buffer's minor modes alone and adding a minor mode leaves
  its major mode alone, so a file under a marker ends with its language,
  `code` and the marker's minor modes (`ModelTest.compileHookChecks`).
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
  there. So the buffer is shown in the window of the list the prompt was
  asked from, or in the first window of the list when that one was closed
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
- **A visit** (`Files.visit view path point focus`) is an open that, once
  the buffer is shown, puts one cursor of the view at a point and, with
  `focus`, focuses the view: at once when a buffer holds the path, and
  otherwise when the load is delivered (`takeIn`), the order carrying the
  point and the focus (`LoadOrder.point`, `LoadOrder.focus`). The point
  (`At`) is a row from 0 and a column in characters (Unicode scalar
  values); its offset (`offsetAt`) clamps the row to the text's last line,
  never the empty row after a final line feed, and the column to the row's
  content. A visit whose load is refused says `notOpened` and changes
  nothing else: no buffer, no cursor, no focus. The compile mode visits a
  location's file so (`Editor/Compile.lean`, "Stepping").
- **Several paths open one after another** (`Files.open view path next`,
  `openAll`). Jobs run in parallel (`docs/design/concurrency.md`), so
  starting one load per path would show whichever load finished last.
  Instead the load order carries the paths still to open (`LoadOrder.next`),
  and the job's command, whatever became of its own file, opens them in the
  view its buffer was or would have been shown in. So one load is in flight
  for each open of several paths, and the last path's buffer is shown last.
  A path a buffer already holds is shown at once and the next is opened. A
  refused path in the middle is said, and the rest still open. A refused
  start is said and opens nothing more: every later start would be refused
  the same way. An interrupted delivery is rolled back with what it
  started, so the paths after it are not opened. Two opens of several paths
  in flight at once load beside each other.
- **The command as it is called asks for its path when it is given none**
  (`openCommand`). With a string as its first argument it opens that
  path, and then the strings that follow it, up to the first argument that
  is not one, one after another. With anything else first, or nothing, it
  asks for the path with a
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
- **A save with a follow-up** (`Files.save id (after := some start)`) starts
  the job `start` once the file is written, from the job's command
  (`saved`), after the save is ended; a refused save starts nothing, and
  its refusal is said as any save's is. `vc-stage-hunk` saves this way,
  so the hunk it stages is of the file as written
  (`Editor/VersionControl/Stage.lean`). Starting a job is a state request,
  so the command still makes no request of the text store. A refused
  start is said in place of `wrote <path>`.
- **A forced save** (`Files.save id true`) expects whatever is there
  (`File.Expect.whatever`), the port's override: the ex name `w!`, which
  writes the buffer over a file another program changed ("Reload" below
  takes the file's text instead).
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

## Reload

Reading a buffer's file again, after another program changed it, as one
edit that keeps the cursor and the markers (`Files.reload id force`).

- **The command** refuses, saying why and starting nothing: a buffer there
  is none of (`noBufferToReload`), one with no file (`noReloadFile`), one
  whose save is in flight (`beingSaved`), forced or not, and, unforced, one
  with unsaved changes (`notReloading`, which names `:e!`). Otherwise it
  takes a snapshot of the text and reads its revision, and starts the job
  `reload-file` (`reloadJob`) with a reload order (`ReloadOrder`): the
  buffer, the path, the force, the snapshot and that revision, the base.
  A refused start releases the snapshot and is said (`notReloadingJob`).
- **The job** (`reloadWork`) loads the file under the editor's limit, then
  asks for the line diff of the snapshot and the file's text
  (`Diff.lines`, `Editor/Diff.lean`) under `diffLineLimit`, and finishes
  with the loaded file and the script, or the refusal's sentence. Both are
  waits: the diff is worked on the library's diff service, off the editor
  thread, which only applies the script.
- **The job's command** (`reloaded`) releases the order's snapshot first,
  whatever follows. A refusal is said (`cannotReload`). A buffer that is
  gone or holds another path takes nothing in, silently. A save in flight
  refuses it, and so, unforced, do unsaved changes made while the file
  loaded: a reload never overwrites edits it was not told to discard.
- **A text that moved.** The script fits the text at the base revision and
  no other. If the text has moved since (an edit and its undo, a config
  command's edit, keys typed during a forced reload), the script is not
  applied: a first reload is started again at once with a fresh snapshot
  and `retried`, saying nothing, and a retried one says `reloadOvertaken`
  and leaves the buffer as it is. One retry, because a second move means
  the user is editing while it reloads. The revision is read before
  anything else, and `applyScript`'s own `moved` refusal is the port's
  guarantee besides.
- **Otherwise**, in order: the buffer's group is closed, so the reload is
  not joined to pending edits; the loaded snapshot is adopted; the script
  is applied as one transaction of origin `disk` (`TextId.applyScript`);
  the adopted snapshot is released; the group is closed again; the history
  is marked saved at the state the reload made; and the buffer holds the
  path again with the stamp the load answered. So one `u` goes back to the
  text from before the reload, and the buffer is then modified; a forced
  reload is that same one step, which `u` undoes. The cursor is a marker,
  so it moves through the script's changed ranges by bias: on a line the
  diff kept it keeps its row and column.
- **`edit-file`** (`editCommand`) is what `e` and `e!` run: a leading
  `true` is the force; a path opens it; with no path it reloads the
  window's buffer when that has a file, and otherwise asks for a path with
  the open prompt. **`reload-buffer`** (`reloadCommand`) reloads the
  window's buffer, forced when its first argument is `true`.

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

Pinned by `ModelTest.fileCommandChecks`, for a file's language
`ModelTest.languageOpenChecks`, and, for a reload,
`ModelTest.fileReloadChecks`, on the loop's driver over the editor's models
and the model of files; and by `ConfigTest.reloadChecks`, and for a file's
language `ConfigTest.languageChecks`, through the headless host on real
files.
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

/-- A point of a text a visit puts the cursor at ("Open", in the module
docs). -/
structure At where
  /-- The row, from 0. -/
  row : Nat
  /-- The column, in characters (Unicode scalar values) from the row's
  start. -/
  column : Nat
  deriving DecidableEq, Repr

/-- What the load job is started with: the file to load, and the view to
show it in. -/
structure LoadOrder where
  /-- The file's path. -/
  path : System.FilePath
  /-- The view the open command was called in. -/
  view : ViewId
  /-- The paths to open after this one, in order. -/
  next : List System.FilePath := []
  /-- For a visit, the point of the file the view's cursor is put at once
  the file is shown. -/
  point : Option At := none
  /-- For a visit, whether the view is focused once the file is shown. -/
  focus : Bool := false
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with: the path, then the
view's number, then, for a visit, the point's row and column and the focus,
then each path to open next. An order with no point and no path next
crosses as the path and the view alone. -/
def LoadOrder.arguments (order : LoadOrder) : List Argument :=
  [.str order.path.toString, .nat order.view.index] ++
    (match order.point with
    | some point => [.nat point.row, .nat point.column, .bool order.focus]
    | none => []) ++
    order.next.map (.str ·.toString)

/-- The paths `arguments` are, if each is a string. -/
def pathsOf? : List Argument → Option (List System.FilePath)
  | [] => some []
  | .str path :: rest => (pathsOf? rest).map (path :: ·)
  | _ :: _ => none

/-- The order `arguments` are, if they are one (`LoadOrder.arguments`). -/
def LoadOrder.ofArguments? : List Argument → Option LoadOrder
  | .str path :: .nat view :: .nat row :: .nat column :: .bool focus :: rest =>
    (pathsOf? rest).map fun next =>
      { path, view := ⟨view⟩, next, point := some ⟨row, column⟩, focus }
  | .str path :: .nat view :: rest => (pathsOf? rest).map fun next => { path, view := ⟨view⟩, next }
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

/-- The view a buffer is shown in when it is to be shown in `view`
(`EditorState.shownIn`): `view`, or, when `view` is the minibuffer's, which
shows no other buffer, the window the open prompt was asked from. -/
def shownIn (state : EditorState) (view : ViewId) : ViewId :=
  state.shownIn view

/-- Opens each of `paths` in `view`, one after another ("Open", in the
module docs). A path a buffer holds (`EditorState.findFile`) is shown at
once, in `shownIn`'s view, saying `notShown` on a refusal, and the next path
is opened. The first path no buffer holds is loaded by the job that loads a
file, whose order carries the paths after it, so that its result opens them
(`opened`): one load is in flight at a time, and the last path's buffer is
shown last. A start that is refused is said (`notOpening`) and opens
nothing more, since every later start would be refused the same way. -/
def openAll (view : ViewId) : List System.FilePath → EditorM Unit
  | [] => pure ()
  | path :: next => do
    let state ← editorState
    if let some buffer := state.findFile path then
      if let .error _← (shownIn state view).show buffer then
        message (notShown path)
      openAll view next
    else if let .error refusal← startJob loadJob (LoadOrder.arguments { path, view, next }) then
      message (notOpening path refusal)

/-- Puts the cursor of `view` at `offset`, one bar with its shape kept. -/
def placeCursor (view : ViewId) (offset : Nat) : EditorM Unit := do
  if let .ok selection← view.selection then
    discard <|
        view.select
          { selection with
            ranges := #[⟨offset, offset⟩], primary := 0 }

/-- The byte offset of `point` in `text` ("Open", in the module docs): the
start of its row, clamped to the last line, and the bytes of the row's first
`point.column` characters, clamped to its content. -/
def offsetAt (text : TextId) (point : At) : TextM Nat := do
  let row := min point.row ((← text.lineCount) - 1)
  let content ← text.rowContent row
  let start ← text.offsetOf ⟨row, 0⟩
  return start + (String.ofList (content.toList.take point.column)).utf8ByteSize

/-- Puts the cursor of `view`, which shows `buffer`, at `point`, and focuses
the view with `focus` ("Open", in the module docs). -/
def placeAt (view : ViewId) (buffer : BufferId) (point : At) (focus : Bool) : EditorM Unit := do
  let some shown := (← editorState).buffer? buffer | return
  placeCursor view (← offsetAt shown.text point)
  if focus then
    discard <| view.focus

/-- What a visit's order asks once `view` shows `buffer`: its cursor at the
order's point, and the focus with the order's focus. Nothing for an order
with no point. -/
def arrived (order : LoadOrder) (view : ViewId) (buffer : BufferId) : EditorM Unit := do
  if let some point := order.point then
    placeAt view buffer point order.focus

/-- What the reply to the load of `order.path` makes of that one file
("Open", in the module docs): a message on a refusal; on success the
buffer, shown in `view`, unless a buffer already holds the path; for a
visit, the view's cursor at the point and the focus (`arrived`). -/
def takeIn (order : LoadOrder) (view : ViewId) (reply : Except FileError File.Loaded) :
    EditorM Unit := do
  match reply with
  | .error error =>
    message (notOpened order.path error)
  | .ok loaded =>
    let path := order.path
    let state ← editorState
    let view := shownIn state view
    -- Another open of the path may have been delivered while this one's
    -- file loaded: the path is matched again, and nothing is taken in.
    if let some buffer := state.findFile path then
      let .ok () ← view.show buffer | message (notShown path)
      arrived order view buffer
      return
    let text ← loaded.snapshot.toText
    let name := state.freeName (path.fileName.getD path.toString)
    let .ok buffer ← addBuffer name text | message (notShown path)
    let .ok () ←
      buffer.attachFile path loaded.stamp
          (loaded.endings.dominant.getD .lf) | message (notShown path)
    Workspace.attach buffer path
    let .ok () ← view.show buffer | message (notShown path)
    -- The language is recorded before the mode is set, so the mode's entry
    -- reads it ("Open", in the module docs, "Language").
    if let some language← languageOf path then
      discard <| buffer.setLanguage (some language)
      -- The view was just shown, so it has a window, and `code` is
      -- compiled: neither refusal of `setMajorMode` can happen here.
      discard <| view.setMajorMode Language.codeName
    arrived order view buffer

/-- The command a finished load job hands the loop: what the reply to the
load of `order.path` becomes (`takeIn`), and then, whatever became of the
file, the paths the order has next, opened one after another (`openAll`).
Both are in the asking view while it still has a window, and the focused
view otherwise ("Open", in the module docs). -/
def opened (order : LoadOrder) (reply : Except FileError File.Loaded) : EditorM Unit := do
  let view (state : EditorState) : ViewId :=
    if (state.window? order.view).isSome then order.view else state.frame.focused
  takeIn order (view (← editorState)) reply
  openAll (view (← editorState)) order.next

/-- The load job: loads the file its order names, unless it is longer than
`limit` bytes, and finishes with what the reply becomes (`opened`). A
refusal is a value in the reply; it fails only for arguments that are not
an order. -/
def loadWork (limit : Nat := Files.limit) (arguments : List Argument) : Work := fun _ => do
  let some order :=
    LoadOrder.ofArguments? arguments | throw s!"{loadJob}: its arguments are not a load order"
  return opened order (← File.load order.path limit)

/-- Opens the file at `path` in `view`, and then each of `next`, one after
another (`openAll`). When a buffer holds a path (`EditorState.findFile`),
it shows that buffer and starts nothing for it. Otherwise it starts the job
that loads the file, whose result makes the buffer and shows it, and then
opens the paths after it ("Open", in the module docs). For the minibuffer's
view the buffer is shown in the window of the list the prompt was asked
from (`shownIn`). Where no load job is registered it says so in the echo
area. -/
def «open» (view : ViewId) (path : System.FilePath) (next : List System.FilePath := []) :
    EditorM Unit :=
  openAll view (path :: next)

/-- Visits the file at `path` in `view` at `point` ("Open", in the module
docs): opens it as `Files.open` does, and once the buffer is shown puts the
view's cursor at the point (`offsetAt`) and, with `focus`, focuses the
view. At once when a buffer holds the path; otherwise when the load is
delivered. A refused load says so and changes nothing else. -/
def visit (view : ViewId) (path : System.FilePath) (point : At) (focus : Bool) : EditorM Unit := do
  let state ← editorState
  let order : LoadOrder := { path, view, point := some point, focus }
  if let some buffer := state.findFile path then
    let shown := shownIn state view
    let .ok () ← shown.show buffer | message (notShown path)
    arrived order shown buffer
  else if let .error refusal← startJob loadJob order.arguments then
    message (notOpening path refusal)

/-- The strings at the front of `arguments`, as paths, up to the first
argument that is not one. -/
def leadingPaths : List Argument → List System.FilePath
  | .str path :: rest => path :: leadingPaths rest
  | _ => []

/-- The open command as it is called: opens the path that is its first
argument, a string, in the window it was called with, and after it the
strings that follow it, up to the first argument that is not one, one after
another. With anything else first, or nothing, it asks for the path
(`prompt`, labelled `openPrompt`), with itself as the continuation: the
answer is then its first argument, and it runs in the view it was asked
from. Where the prompt is refused, because one is open, it says so in the
echo area (`notAsking`). -/
def openCommand (call : Call) : EditorM Unit := do
  match call.arguments with
  | .str path :: rest =>
    Files.open call.target.window.id path (leadingPaths rest)
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
snapshot of its text to write, the file's path, what the save expects
to find there, and the job to start once the file is written, if any. -/
structure SaveOrder where
  /-- The buffer that is saved. -/
  buffer : BufferId
  /-- The snapshot the save command took of the buffer's text. -/
  snapshot : SnapshotId
  /-- The file's path. -/
  path : System.FilePath
  /-- What the save expects to find at the path. -/
  expect : File.Expect
  /-- The job started once the file is written. -/
  after : Option JobStart := none
  deriving DecidableEq, Repr

/-- What a save expects, as arguments: a word, and after `unchanged` the
stamp's seconds, nanoseconds and size. -/
def expectArguments : File.Expect → List Argument
  | .unchanged stamp =>
    [.str "unchanged", .int stamp.seconds, .nat stamp.nanoseconds, .nat stamp.size]
  | .absent => [.str "absent"]
  | .whatever => [.str "whatever"]

/-- What a save expects, read back from the start of its arguments
(`expectArguments`), and the arguments after it. -/
def expectOfArguments? : List Argument → Option (File.Expect × List Argument)
  | .str "unchanged" :: .int seconds :: .nat nanoseconds :: .nat size :: rest =>
    some (.unchanged { seconds, nanoseconds, size }, rest)
  | .str "absent" :: rest => some (.absent, rest)
  | .str "whatever" :: rest => some (.whatever, rest)
  | _ => none

/-- A job to start after a save, as arguments: none for none, and otherwise
its name, its key or `false`, and its own arguments. -/
def afterArguments : Option JobStart → List Argument
  | none => []
  | some start =>
    .str start.name ::
        (match start.key with
        | some key => Argument.str key
        | none => .bool false) ::
      start.arguments

/-- The job to start after a save, read back from its arguments
(`afterArguments`). -/
def afterOfArguments? : List Argument → Option (Option JobStart)
  | [] => some none
  | .str name :: .str key :: arguments => some (some { name, key := some key, arguments })
  | .str name :: .bool false :: arguments => some (some { name, arguments })
  | _ => none

/-- The order as the arguments a job is started with: the buffer's number,
the snapshot's, the path, then what the save expects (`expectArguments`),
then the job to start after it (`afterArguments`). -/
def SaveOrder.arguments (order : SaveOrder) : List Argument :=
  [.nat order.buffer.index, .nat order.snapshot.index, .str order.path.toString] ++
      expectArguments order.expect ++
    afterArguments order.after

/-- The order `arguments` are, if they are one (`SaveOrder.arguments`). -/
def SaveOrder.ofArguments? : List Argument → Option SaveOrder
  | .nat buffer :: .nat snapshot :: .str path :: rest => do
    let (expect, rest) ← expectOfArguments? rest
    let after ← afterOfArguments? rest
    return { buffer := ⟨buffer⟩, snapshot := ⟨snapshot⟩, path, expect, after }
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
save that was refused, and then says what became of the file; a file
written starts the order's follow-up, if it has one, and a refused start is
said. It makes no request of the text store, so it cannot be interrupted or
refused. -/
def saved (order : SaveOrder) (reply : Except FileError File.Stamp) : EditorM Unit := do
  -- Refused only when the buffer was removed while its save ran: what
  -- became of the file is said all the same.
  discard <| order.buffer.endSave order.snapshot reply.toOption
  match reply with
  | .ok _ =>
    message (wrote order.path)
    if let some start := order.after then
      if let .error refusal← startJob start.name start.arguments start.key then
        message s!"{start.name}: {refusal.describe}"
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
releases the snapshot it took, and records no save. Once the file is
written the job `after` is started, if it is given. -/
def save (id : BufferId) (force : Bool := false) (after : Option JobStart := none) :
    EditorM Unit := do
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
      expect := if force then .whatever else .unchanged file.stamp, after }
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

/-- The most lines a side of the middle of a reload's diff that the engine is
asked about: 100 000. Over it the middle is one hunk, replaced whole, so a
diff of any file costs the diff service linear time ("Reload", in the module
docs). Like `limit`, a round number with no measurement behind it. -/
def diffLineLimit : Nat :=
  100000

/-- The name the reload command is registered under. -/
def reloadName : String :=
  "reload-buffer"

/-- The name the command the ex names `e` and `e!` run is registered under. -/
def editName : String :=
  "edit-file"

/-- The name the job that reloads a file is registered under. -/
def reloadJob : String :=
  "reload-file"

/-- What the reload job is started with: the buffer, its file's path,
whether the reload is forced, the snapshot the reload command took of the
buffer's text and the revision it took it at, and whether this is the one
retry of a reload whose text moved. -/
structure ReloadOrder where
  /-- The buffer that is reloaded. -/
  buffer : BufferId
  /-- The file's path. -/
  path : System.FilePath
  /-- Whether unsaved changes are discarded. -/
  force : Bool
  /-- The snapshot of the buffer's text the file is diffed against. -/
  snapshot : SnapshotId
  /-- The revision the text was at when the snapshot was taken. -/
  base : Nat
  /-- Whether this order is the retry of one whose text moved. -/
  retried : Bool := false
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with: the buffer's number,
the path, the force, the snapshot's number, the base and the retry. -/
def ReloadOrder.arguments (order : ReloadOrder) : List Argument :=
  [.nat order.buffer.index, .str order.path.toString, .bool order.force, .nat order.snapshot.index,
    .nat order.base, .bool order.retried]

/-- The order `arguments` are, if they are one (`ReloadOrder.arguments`). -/
def ReloadOrder.ofArguments? : List Argument → Option ReloadOrder
  | [.nat buffer, .str path, .bool force, .nat snapshot, .nat base, .bool retried] =>
    some { buffer := ⟨buffer⟩, path, force, snapshot := ⟨snapshot⟩, base, retried }
  | _ => none

/-- What the echo area says when a buffer there is none of was to be
reloaded. -/
def noBufferToReload : String :=
  "no such buffer to reload"

/-- What the echo area says when the buffer called `name`, which shows no
file, was to be reloaded. -/
def noReloadFile (name : String) : String :=
  s!"{name} has no file to reload"

/-- What the echo area says when the buffer called `name` was to be reloaded,
unforced, with unsaved changes: the reload changes nothing, and `:e!` is the
way to take the file's text. -/
def notReloading (name : String) : String :=
  s!"{name} has unsaved changes; :e! discards them"

/-- What the echo area says when the job that reloads `path` was not
started. -/
def notReloadingJob (path : System.FilePath) (refusal : JobRefusal) : String :=
  s!"cannot reload {path}: {refusal.describe}"

/-- What the echo area says when the reload of `path` was refused, by the
load or by the diff: `detail` is the refusal's own sentence. -/
def cannotReload (path : System.FilePath) (detail : String) : String :=
  s!"cannot reload {path}: {detail}"

/-- What the echo area says when the text of the buffer of `path` moved twice
while it reloaded: it is left as it is. -/
def reloadOvertaken (path : System.FilePath) : String :=
  s!"{path} was edited while it reloaded; :e reloads it"

/-- What the reload job finishes with: the file loaded and the script of its
diff against the buffer's snapshot, or the sentence of the refusal of the
load or of the diff. -/
abbrev ReloadReply :=
  Except String (File.Loaded × Diff.Script)

/-- Starts the reload job with `order`. Where it is refused, it releases the
order's snapshot and says so (`notReloadingJob`). -/
def startReload (order : ReloadOrder) : EditorM Unit := do
  if let .error refusal← startJob reloadJob order.arguments then
    (TextSource.snapshot order.snapshot).release
    message (notReloadingJob order.path refusal)

/-- Reloads the buffer `id` from its file ("Reload", in the module docs): takes
a snapshot of its text and its revision, and starts the job that loads the
file and diffs the two. It starts nothing, and says why, for a buffer there
is none of, one with no file, one whose save is in flight, forced or not,
and, unless `force`, one with unsaved changes. -/
def reload (id : BufferId) (force : Bool := false) : EditorM Unit := do
  let some buffer := (← editorState).buffer? id | message noBufferToReload
  let some file := buffer.file | message (noReloadFile buffer.name)
  if file.saving.isSome then
    message (beingSaved file.path)
    return
  if !force && buffer.unsavedAt (← buffer.history.sync) then
    message (notReloading buffer.name)
    return
  let base ← buffer.text.revision
  let snapshot ← buffer.text.snapshot
  startReload { buffer := id, path := file.path, force, snapshot, base }

/-- The command a finished reload job hands the loop ("Reload", in the module
docs). It releases the order's snapshot first, whatever follows. A refusal is
said. A buffer that is gone, or holds another path, takes nothing in. A save
in flight, or, unforced, unsaved changes made while the file loaded, refuse
it. A text that moved past the order's revision is reloaded once more, and
after that is left as it is, saying so. Otherwise the script is applied as
one edit of origin `disk`, between two boundaries, and the buffer is saved at
the state it made, holding the stamp the load answered. -/
def reloaded (order : ReloadOrder) (reply : ReloadReply) : EditorM Unit := do
  (TextSource.snapshot order.snapshot).release
  match reply with
  | .error detail =>
    message (cannotReload order.path detail)
  | .ok (loaded, script) =>
    let some buffer := (← editorState).buffer? order.buffer | return
    let some file := buffer.file | return
    if file.path != order.path then
      return
    if file.saving.isSome then
      message (beingSaved order.path)
      return
    if !order.force && buffer.unsavedAt (← buffer.history.sync) then
      message (notReloading buffer.name)
      return
    let revision ← buffer.text.revision
    if revision != order.base then
      if order.retried then
        message (reloadOvertaken order.path)
      else
        let snapshot ← buffer.text.snapshot
        startReload
            { order with
              snapshot, base := revision, retried := true }
      return
    -- The reload is a step of its own: not joined to edits still pending,
    -- such as an insert session's.
    discard <| order.buffer.closeGroup
    let adopted ← loaded.snapshot.adopt
    discard <| buffer.text.applyScript order.base (.snapshot adopted) script .disk
    (TextSource.snapshot adopted).release
    discard <| order.buffer.closeGroup
    if let .ok synced← order.buffer.synced then
      discard <| EditorState.ask (.setHistory order.buffer synced.history.markSaved)
    discard <| order.buffer.attachFile order.path loaded.stamp (loaded.endings.dominant.getD .lf)

/-- The reload job: loads the file its order names, unless it is longer than
`limit` bytes, diffs it against the order's snapshot under `diffLineLimit`,
and finishes with what the reply becomes (`reloaded`). A refusal is a value
in the reply; it fails only for arguments that are not an order. Both are
waits, so the job holds no thread while the file loads or the diff is
worked. -/
def reloadWork (limit : Nat := Files.limit) (arguments : List Argument) : Work := fun _ => do
  let some order :=
    ReloadOrder.ofArguments? arguments | throw s!"{reloadJob}: its arguments are not a reload order"
  match ← File.load order.path limit with
  | .error error =>
    return reloaded order (.error error.describe)
  | .ok loaded =>
    match ← Diff.lines (.snapshot order.snapshot) (.held loaded.snapshot) diffLineLimit with
    | .error error =>
      return reloaded order (.error error.describe)
    | .ok script =>
      return reloaded order (.ok (loaded, script))

/-- The reload command as it is called: reloads the buffer of the window it
was called with, forced when its first argument is `true` (Emacs's
`revert-buffer`). -/
def reloadCommand (call : Call) : EditorM Unit :=
  reload call.target.window.buffer (call.arguments.head? == some (.bool true))

/-- The command the ex names `e` and `e!` run. A leading `true` is the force.
Then a string opens that path and the strings after it, as `open-file` does,
forced or not, since buffers persist and nothing is discarded. With no path
it reloads the buffer of the window it was called with, as Vim's `:e` does,
when that buffer has a file, and otherwise asks for a path as `open-file`
does, whose continuation is `open-file`. -/
def editCommand (call : Call) : EditorM Unit := do
  let (force, rest) :=
    match call.arguments with
    | .bool true :: rest => (true, rest)
    | rest => (false, rest)
  match rest with
  | .str path :: more =>
    Files.open call.target.window.id path (leadingPaths more)
  | _ =>
    let buffer := call.target.window.buffer
    if (((← editorState).buffer? buffer).bind (·.file)).isSome then
      reload buffer force
    else if let .error refusal← prompt openPrompt { command := openName } then
      message (notAsking refusal)

/-- The name the job that checks files for a change on disk is registered
under. -/
def checkJob : String :=
  "check-files"

/-- One file a check looks at: the buffer, its file's path, and the stamp the
buffer recorded for it when the check was asked for. -/
structure Checked where
  /-- The buffer. -/
  buffer : BufferId
  /-- Its file's path. -/
  path : System.FilePath
  /-- The stamp the buffer recorded. -/
  stamp : File.Stamp
  deriving DecidableEq, Repr

/-- The files of a check as the arguments a job is started with: for each,
the buffer's number, the path and the stamp's seconds, nanoseconds and
size. -/
def checkArguments (files : Array Checked) : List Argument :=
  files.toList.flatMap fun file =>
    [.nat file.buffer.index, .str file.path.toString, .int file.stamp.seconds,
      .nat file.stamp.nanoseconds, .nat file.stamp.size]

/-- The files `arguments` are, if they are a check's (`checkArguments`). -/
def checkOfArguments? : List Argument → Option (Array Checked)
  | [] => some #[]
  | .nat buffer :: .str path :: .int seconds :: .nat nanoseconds :: .nat size :: rest =>
    (checkOfArguments? rest).map fun others =>
      #[{ buffer := ⟨buffer⟩, path, stamp := { seconds, nanoseconds, size } }] ++ others
  | _ => none

/-- What the echo area says when the first edit of the buffer of `path` was
refused because its file changed on disk: how to reload, and that the next
edit keeps the buffer's text. -/
def changedOnDisk (path : System.FilePath) : String :=
  s!"{path} changed on disk; :e reloads it, or edit again to keep this text"

/-- What the echo area says when the first edit of the buffer of `path` was
refused because its file is gone: `:e` cannot reload a file that is not
there, and `:w!` writes it again. -/
def goneFromDisk (path : System.FilePath) : String :=
  s!"{path} is gone from disk; :w! writes it again, or edit again to keep this text"

/-- What the echo area says when a check found that the file of a buffer with
unsaved changes, at `path`, changed on disk: the two resolutions. -/
def changedUnderEdits (path : System.FilePath) : String :=
  s!"{path} changed on disk; :e! takes the file's text, :w! writes yours over it"

/-- Whether auto-reload is in effect: a command's choice, or else config's
setting. -/
def autoReloadOn : EditorM Bool :=
  EditorState.ask .autoReloadMode

/-- Starts the reload of the buffer `id` that a change on disk found by
auto-reload asks for, unforced, when the buffer has a file and no unsaved
changes. It takes the snapshot the reload diffs against. -/
def autoReloading (id : BufferId) : EditorM Unit := do
  let some buffer := (← editorState).buffer? id | return
  if buffer.isModified || (buffer.file.bind (·.saving)).isSome then
    return
  reload id

/-- What a stat's reply says of a file for the mark: its stamp, `none` for a
file that is gone, or nothing to say, for any other refusal. -/
def foundOf : Except FileError File.Stamp → Option (Option File.Stamp)
  | .ok stamp => some (some stamp)
  | .error .notFound => some none
  | .error _ => none

/-- The command a finished check hands the loop ("Files that changed on
disk", `Editor/Loop.lean`). It is made of state requests alone, so it cannot
be interrupted or rolled back. For each file the mark is set or cleared
(`BufferId.markChanged`), told when the buffer is modified, since its text
is not touched and the user is told here: the echo area says
`changedUnderEdits` for the first such buffer newly found changed. A buffer
that is unmodified is marked untold, so its next edit is refused once. -/
def checked (results : Array (Checked × Except FileError File.Stamp)) : EditorM Unit := do
  let mut said := false
  for (file, reply) in results do
    let some found := foundOf reply | continue
    let state ← editorState
    let some buffer := state.buffer? file.buffer | continue
    let modified := buffer.isModified
    let was := buffer.file.bind (·.changed)
    discard <| file.buffer.markChanged file.stamp found modified
    let fresh := found != some file.stamp && was.all (·.found != found)
    let current := (buffer.file.map (·.stamp)) == some file.stamp
    if modified && fresh && !said && current then
      message (changedUnderEdits file.path)
      said := true
    -- Under auto-reload an unmodified buffer found changed is reloaded, as
    -- a follow's change reloads it; a file that is gone is only marked.
    if !modified && current && found.isSome && found != some file.stamp then
      if ← autoReloadOn then
        autoReloading file.buffer

/-- The check job: stats each file its order names, in turn, and finishes
with what the replies become (`checked`). One stat a file, and no watch. -/
def checkWork (arguments : List Argument) : Work := fun _ => do
  let some files :=
    checkOfArguments? arguments | throw s!"{checkJob}: its arguments are not files to check"
  let mut results := #[]
  for file in files do
    results := results.push (file, ← File.stat file.path)
  return checked results

/-- The name the auto-reload command is registered under. -/
def autoReloadName : String :=
  "auto-reload-mode"

/-- The name the job that follows a file for auto-reload is registered
under. -/
def followJob : String :=
  "follow-file"

/-- How a follow job's watch coalesces: a change is delivered 50 ms after the
first, and a delivery holds one path, the file's own; past it, `missed`. -/
def followCoalescing : FileWatch.Coalescing :=
  { window := 50, bound := 1 }

/-- What the echo area says when auto-reload is on, or off. -/
def autoReloadSays (on : Bool) : String :=
  if on then "auto-reload on" else "auto-reload off"

/-- What a refused follow's message ends with: that auto-reload is off for
the buffer, and how to try again. -/
def followRetry : String :=
  "auto-reload is off for this buffer; :noautoread then :autoread retries"

/-- What the echo area says when the file at `path` could not be followed:
why, as a sentence (`FileWatchError.describe`, `FileError.describe`), then
`followRetry`. -/
def notFollowing (path : System.FilePath) (detail : String) : String :=
  s!"cannot follow {path}: {detail}; {followRetry}"

/-- What a follow job is started with: the buffer, its file's path, the stamp
the buffer recorded, which `markChanged` is guarded by, and the last stamp
found, which the job compares a stat with: `none` for a file that is gone.
The two differ exactly while the buffer is marked. -/
structure FollowOrder where
  /-- The buffer. -/
  buffer : BufferId
  /-- The file's path. -/
  path : System.FilePath
  /-- The stamp the buffer recorded. -/
  stamp : File.Stamp
  /-- The last stamp found, or `none` for a file that is gone. -/
  expected : Option File.Stamp
  deriving DecidableEq, Repr

/-- A stamp as three arguments. -/
def stampArguments (stamp : File.Stamp) : List Argument :=
  [.int stamp.seconds, .nat stamp.nanoseconds, .nat stamp.size]

/-- The order as arguments: the buffer's number, the path, the stamp, and the
expected stamp after `true`, or `false` alone for none. -/
def FollowOrder.arguments (order : FollowOrder) : List Argument :=
  [.nat order.buffer.index, .str order.path.toString] ++ stampArguments order.stamp ++
    match order.expected with
    | some expected => .bool true :: stampArguments expected
    | none => [.bool false]

/-- The order `arguments` are, if they are one (`FollowOrder.arguments`). -/
def FollowOrder.ofArguments? : List Argument → Option FollowOrder
  |
  [.nat buffer, .str path, .int seconds, .nat nanoseconds, .nat size, .bool true,
      .int expectedSeconds, .nat expectedNanoseconds, .nat expectedSize] =>
    some
      { buffer := ⟨buffer⟩, path, stamp := { seconds, nanoseconds, size }
        expected :=
          some
            { seconds := expectedSeconds, nanoseconds := expectedNanoseconds
              size := expectedSize } }
  | [.nat buffer, .str path, .int seconds, .nat nanoseconds, .nat size, .bool false] =>
    some { buffer := ⟨buffer⟩, path, stamp := { seconds, nanoseconds, size }, expected := none }
  | _ => none

/-- The command a follow job finishes with when the file's stat answered
`found`, which is not what the order expected ("Auto-reload",
`Editor/Loop.lean`). The loop arms the follow again after this step. A
stale order is ignored. An unmodified buffer is marked untold and, when the
file is there, reloaded; a gone file is only marked. A modified buffer is
marked told and its text left: its status line shows the mark. -/
def followed (order : FollowOrder) (found : Option File.Stamp) : EditorM Unit := do
  discard <| EditorState.ask (.unfollow order.buffer)
  let some buffer := (← editorState).buffer? order.buffer | return
  let some file := buffer.file | return
  if file.path != order.path || file.saving.isSome || !(← autoReloadOn) then
    return
  let modified := buffer.isModified
  discard <| order.buffer.markChanged order.stamp found modified
  if !modified && found.isSome then
    autoReloading order.buffer

/-- The command a follow job finishes with when its watch or a stat was
refused: it is said, and the follow is not armed again until the mode is
turned off and on. -/
def unfollowable (order : FollowOrder) (detail : String) : EditorM Unit := do
  discard <| EditorState.ask (.refuseFollow order.buffer)
  message (notFollowing order.path detail)

/-- What a stat's reply is for a follow: the stamp, `none` for a file that is
gone, or the refusal's sentence. -/
def followFound : Except FileError File.Stamp → Except String (Option File.Stamp)
  | .ok stamp => .ok (some stamp)
  | .error .notFound => .ok none
  | .error error => .error error.describe

/-- The follow job ("Auto-reload", `Editor/Loop.lean`): it watches the file,
then stats it, and waits for the watch's next delivery whenever the stat
answers what the order expected, so a change made before the watch existed
is still seen. It finishes with `followed` once a stat answers something
else, and with `unfollowable` when the watch or a stat is refused. A file
that is still gone waits again, so a deleted file does not spin. -/
def followWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    FollowOrder.ofArguments? arguments | throw s!"{followJob}: its arguments are not a follow order"
  match ← FileWatch.start (.file order.path) followCoalescing with
  | .error error =>
    return unfollowable order error.describe
  | .ok watch =>
    -- Each round is a stat, then a wait for a delivery; nothing else ends
    -- the job but a change, a refusal, or its cancel.
    let rec go : Nat → JobM (EditorM Unit)
      | 0 => return unfollowable order "the follow ran out of rounds"
      | rounds + 1 => do
        match followFound (← File.stat order.path) with
        | .error detail =>
          return unfollowable order detail
        | .ok found =>
          if found != order.expected then
            return followed order found
          match ← FileWatch.next watch with
          | .error error =>
            return unfollowable order error.describe
          | .ok _ =>
            go rounds
    go 1000000

/-- The auto-reload command: a `true` or `false` first argument chooses it on
or off; with none it toggles what is in effect. It says which, and is made of
state requests alone. -/
def autoReloadCommand (call : Call) : EditorM Unit := do
  let on ←
    match call.arguments with
    | .bool on :: _ =>
      pure on
    | _ =>
      do
        let current ← autoReloadOn
        pure !current
  discard <| EditorState.ask (.setAutoReload on)
  message (autoReloadSays on)

end Editor.Files
