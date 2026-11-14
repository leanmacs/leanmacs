import Editor.File
import Editor.Invocation
import Editor.Scene
import Editor.UndoTree
import Editor.Value

/-!
# The editor state

What the editor is showing and editing, as one immutable value the editor
thread holds (`EditorState`): the buffers, the windows, the one frame they
are arranged in, the echo area, the input method's preedit and the prompt
that is open, if one is. The command
loop (`Editor/Loop.lean`) takes it from one event to the next and publishes
a scene of it after each.

- **A buffer** (`Buffer`) is a text of the text store, a name, the text's
  undo tree, the buffer's local values (`Value` trees, as a store's cell
  holds, `Editor/Value.lean`), and the names of its modes: one major mode
  or none, and its minor modes, the one added last first. A name here is
  only a name: what a mode is, and what its keys and its `onEnter` are, is
  the registry's (`Editor/Mode.lean`, `Editor/Config/Registry.lean`), and a
  name no registered mode has contributes nothing. It also keeps the file
  it shows, if it shows one, and its line ending ("A buffer's file",
  below).
- **Buffers are kept in slots** (`EditorState.buffers`). A `BufferId` is an
  index there, and a buffer that is removed leaves its slot empty, as the
  text store keeps the place of a released text. So an id is never used
  again, and no window's `buffer` is renumbered when another buffer goes.
- **A window** (`Window`) is a view of a buffer: its `ViewId`, which names it
  in every scene, the buffer it shows, its scroll position as an anchor
  marker of the buffer's text, and its selections as one selection marker
  of that text, whose ranges are its cursors.
- **The frame** (`Frame`) is the one window of the platform: its size, the
  split tree of the editor's windows (`Split`), the window that is focused,
  and whether the frame has the keyboard focus.

## The split tree and its invariants

The split tree is a binary tree. A leaf is a window, by its `ViewId`, or the
minibuffer's place; a split divides its rectangle along an axis, rows
(stacked) or columns (side by side), between its two children
(`Split.rects`): the first takes half the extent, rounded down, and the
second the rest. A subtree with no view takes no space and its sibling
takes all of it. So the minibuffer's place takes none while no prompt is
open, and the views tile the frame.

**While a prompt is open the minibuffer's place takes a strip.**
`Split.rects` is handed the minibuffer's view, or none. With a view, a
split one of whose children is the minibuffer's place gives that place
`Split.minibufferHeight` physical pixels along its axis, or the whole
extent when that is less, and the sibling the rest; the view's rectangle
is the place's, where the leaf is in drawing order, and the views still
tile the frame. A tree that is the place alone gives the view the whole
rectangle. The height is 32: two rows of a 16-pixel cell, one for the
input and one for the status line that carries the prompt text
(`Editor/Loop.lean`). It is a placeholder with no font behind it: nothing
in Lean knows the height of a row, since layout is the display's.

The invariants are part of the model (`EditorState.wellFormed`). They are
stated over the state's views (`EditorState.views`): the tree's windows,
in drawing order, then the minibuffer's view while a prompt is open
("Prompts", below).

- the focused window is one of the views;
- the tree has exactly one minibuffer leaf;
- the views' ids are distinct, and they are exactly the windows' ids;
- each window's buffer exists.

Each clause is seen to refuse: `ModelTest.spoilings` builds, for every
clause, a state that breaks it and keeps the others, and none is well
formed. A clause added here gets a state there.

An operation that would break one is refused with a `LayoutRefusal` and
changes nothing: it returns the state it was given. A command reaches each
as a request of the editor's port (`Editor/State/Request.lean`), whose
handler is these operations:

- `removeWindow` refuses `noSuchWindow` for a window not in the tree, and
  `onlyWindow` for the last window, which would leave nothing to focus. The
  removed window's sibling takes the place of the split that held both, and
  the window is handed back: its markers are the caller's to give up. When
  the window was focused, the focus moves to the first window, in drawing
  order, of the subtree that took its place, or, when that subtree has
  none, to the first window of the tree.
- `focusWindow` takes a window of the tree, and the minibuffer's window
  while a prompt is open, so the focus can leave the minibuffer and come
  back. It refuses `noSuchWindow` for any other.
- `splitWindow` puts a new window where the source window was, second in a
  split with it along the axis given: below it for `rows`, to its right
  for `columns`. The new window shows the source window's buffer, with the
  two markers the caller made for it, and the focus stays where it was. It
  refuses `noSuchWindow` for a source not in the tree, and
  `markersOfAnotherText` for a marker that is not of that buffer's text.
  Splitting a window and removing the new one gives back the tree from
  before the split, since the sibling of a removed window takes the place
  of their split.
- `showBuffer` has a window show another buffer, with the two markers the
  caller made on that buffer's text. It refuses `noSuchWindow`,
  `noSuchBuffer` for a buffer there is none of (a window over no buffer
  would break the last invariant), and `markersOfAnotherText`.

**A view's id is never used again.** A new window's id is the state's
`nextView`, or one more than the greatest id a window has when that is
greater, so it is new on a state built by hand too; `nextView` is then one
past it. So what a scheme or a scene keeps under a closed view's id can
never come to mean another view.

The minibuffer's place has no `ViewId`, so no operation here can remove it.
The minibuffer's window is not theirs either: `removeWindow`, `splitWindow`
and `showBuffer` refuse it with `ofMinibuffer` and its view, and
`showBuffer` refuses the same way to show the minibuffer's buffer in
another window. `removeWindow` counts the tree's windows alone, so the last
ordinary window cannot be removed while a prompt is open.

## Prompts

A prompt is a request for one string, with a text to show beside the input
(the label). How a command waits for the answer is in
`docs/design/concurrency.md`, "Prompts".

- **The open prompt is editor state** (`EditorState.prompt`, a `Prompt`):
  its label, the minibuffer's view, the asking view, which was focused
  when the prompt was asked for, and the continuation, the invocation that
  receives the answer. One prompt is open at a time.
- **The minibuffer is a buffer and a window of the state.** The buffer is
  in the next slot, over a text the asking command made, with a name no
  buffer has (`Prompt.bufferName`, made free by `freeName`) and the major
  mode `Prompt.mode`. The window is in `windows`, with a new view id. So
  what works on a buffer and a window works on them with no rule of its
  own: a committed text is inserted there, the loop keeps and restores
  its markers and its history, and the scene has its view.
- **The tree does not change.** The minibuffer leaf says where the
  minibuffer's place is, and `EditorState.prompt` says whether a prompt is
  open and which window stands there. A view id on the leaf was set aside:
  the open prompt would then be in two places that an invariant must keep
  in step.
- `openPrompt` adds the buffer and the window, records the prompt with the
  focused view as its asker, focuses the new view and hands it back. It
  refuses, with the state as it was, `alreadyOpen` and the open prompt's
  view while one is open, `noWindow` when the focused view has no window
  to ask from (the state with nothing in it), and `notItsText` for a
  history or a marker of another text than the minibuffer's.
  `PromptRefusal.describe` says each as a sentence.
- `closePrompt` closes the open prompt, with an answer or with none for a
  prompt that is cancelled. It removes the minibuffer's window, empties
  its buffer's slot, and clears the prompt; the tree is as it was. It
  refuses `notOpen`, with the state as it was, when no prompt is open.
  - **The focus goes to the asking view**, even if it was moved meanwhile,
    so the answer's command runs with the window the prompt was asked in.
    When that view is no longer a window of the tree, it goes to the first
    window of the tree, in drawing order. A view's id is never used again,
    so the asker cannot have come to mean another view.
  - **Given an answer it records the continuation**, with the answer as
    its first argument and the continuation's own after it
    (`EditorState.answered`), until the loop hands it to its host
    (`Editor/Loop.lean`), as `starts` holds the jobs a command asked for.
    Closing and recording are one operation, so one request.
  - **The minibuffer's markers and text are not given up here**: the loop
    gives them up once the command that closed the prompt has run to its
    end, as it does for any window that is closed and any buffer that is
    removed.

## Buffers

- `addBuffer` gives a new buffer the next slot. It refuses `nameTaken` for
  a name a buffer already has, so that finding a buffer by its name
  (`findBuffer`) has one answer, and `notItsHistory` for an undo tree over
  another text than the buffer's.
- `removeBuffer` empties the buffer's slot. It refuses `noSuchBuffer`, and
  `shown`, with the first such view, while a window shows the buffer. The
  buffer's text is not released here: the loop releases it once the command
  that removed the buffer has run to its end (`Editor/Loop.lean`, "What a
  finished command gave up"), so a command that fails afterwards is rolled
  back whole.
- `setHistory` replaces a buffer's undo tree, for the commands that move in
  the history. It refuses `noSuchBuffer`, and `notItsHistory` for a tree
  over another text.
- `setValue` sets a buffer-local value under a name, in place of the one
  the name had; `value?` reads one.

## A buffer's file

- **A buffer keeps its file** (`Buffer.file`, a `Buffer.File`): the file's
  path, and the stamp the last load or save of it answered, which is what
  the next save expects to find on disk (`Editor/File.lean`). `none` for a
  buffer that shows no file. The stamp is not optional: a buffer comes to
  hold a file by a load, which answers one.
- **A buffer keeps its line ending** (`Buffer.lineEnding`), a line feed
  unless a file said otherwise. It is the buffer's and not the file's: a
  buffer with no file needs an answer too when a command breaks a line. It
  decides only the line break a command inserts. Nothing is translated on
  the way in or out: the text holds every byte of the file.
- **The saved state is the undo tree's** (`UndoTree.saved`, in
  `Buffer.history`), and so is whether the buffer is modified
  (`Buffer.isModified`). A second copy here would be a second answer.
- **A path is matched as a string** (`findFile`): the buffer whose file's
  path is equal to it. Two spellings of one file (a symbolic link, `..`, a
  doubled slash) are two buffers. That is safe: once one is saved, a save
  of the other is refused as changed on disk, so neither overwrites the
  other unnoticed. A canonical path would be the file system's to answer,
  which the file port does not.
- `attachFile` has a buffer hold a file: its path, its stamp and the
  buffer's line ending, with no save in flight. It refuses `noSuchBuffer`,
  and `fileOpen`, with the buffer that holds it, for a path another buffer
  holds, so that `findFile` has one answer, as `nameTaken` gives
  `findBuffer` one. Attaching the path a buffer holds to that buffer again
  replaces its stamp. It leaves the history: a buffer made over loaded
  text has a new tree, which is saved at its root.
- `freeName` is a name no buffer has, for a new buffer that would be
  called `name`: the name itself, or the name followed by `<2>`, `<3>` and
  so on, the first that is free. Two files with one base name are two
  buffers this way.
- **The state keeps a save in flight** (`Buffer.File.saving`, a
  `Buffer.Saving`): a save whose job has been started and whose result
  has not yet been delivered. It holds the snapshot the save writes and
  the state the text was in when the snapshot was taken.
  - `beginSave` records one. It refuses `noSuchBuffer`, `noFile` for a
    buffer that shows no file, and `beingSaved` while a save is in flight.
    Two saves of one buffer in flight would both expect the stamp from
    before the first, and the second would be refused as changed on disk
    though nothing but the editor wrote the file; here the second is
    refused when it is asked, with a refusal that says why.
  - `endSave` ends the one that writes a given snapshot: it is no longer
    in flight. Given the stamp of the file the save wrote, the buffer's
    file has that stamp and the kept state is the one marked as saved
    (`UndoTree.markSaved`): a buffer whose text has moved on since stays
    modified, since a save that reports late marks the state it wrote.
    Given no stamp, for a save that was refused, neither changes. It
    refuses `noSuchBuffer`, and `notBeingSaved` unless a save of the
    buffer that writes that snapshot is in flight.
  - Ending a save is one request that asks the text store nothing, so the
    command that makes it cannot be interrupted between the stamp and the
    mark. The snapshot is released by the loop, once that command has run
    to its end (`Editor/Loop.lean`, "What a finished command gave up").

## A buffer's modes

Three operations set a buffer's modes, of the same shape. Each is refused,
with the state as it was, with `BufferRefusal.noSuchBuffer` for a buffer
there is none of. They take any name: whether a mode of that name is
registered is the loop's to ask, which also runs the mode's `onEnter`
(`Editor/Command/Dispatch.lean`).

- `setMajorMode` makes a mode the buffer's major mode, and says whether it
  became it: `false`, with nothing changed, when the buffer already had it.
- `addMinorMode` puts a minor mode first; one the buffer has already
  changes nothing.
- `removeMinorMode` takes a minor mode away; one the buffer does not have
  changes nothing.

## Smaller rules

- A new state's frame is focused, on view 0, with one window over a buffer
  called `scratch` of an empty text, whose scroll anchor is at 0 and whose
  selection is one exclusive cursor at 0 (`EditorState.initial`).
- The frame's `hasFocus` is the platform window's keyboard focus. While the
  frame does not have it, the scene names no focused view.
- The preedit is the text an input method is composing in the focused
  window; `none` when it is composing nothing.
- No ambient context: a handler is given the window it acts on and its
  buffer, as a `Target`, never "the current buffer".
- The jobs a command asked to be started are kept, in order, until the
  loop hands them to its host (`EditorState.starts`, a `JobStart` each: a
  registered job's name and plain arguments).
- `EditorState.none` is an editor with no buffer and no window. It is not
  well formed, and no loop holds it: it is what a command's state requests
  are answered from where no loop runs the command
  (`Editor/Command/Model.lean`).

## Where a new field goes

| What it belongs to | Where |
|---|---|
| One buffer (its line ending, its modes) | A field of `Buffer` |
| The file a buffer shows (what the next save expects on disk) | A field of `Buffer.File` |
| One view (a goal column, a scroll offset) | A field of `Window` |
| The whole editor (registers, the pending key prefix) | A field of `EditorState` |
| The open prompt (what completes it, what it has shown) | A field of `Prompt` |
| What the user sees of it | A field of the scene (`Editor/Scene.lean`), filled in `Loop.scene`, or in `Loop.views` for a field of a view (`Editor/Loop.lean`) |

Each is pinned by `ModelTest.stateChecks`, and what the scene shows of it by
`ModelTest.loopChecks`. The operations a request reaches are pinned through
the requests' handler, by `ModelTest.stateRequestChecks`.
-/

namespace Editor

/-- The name of a buffer: the index of its slot in the state's buffers. It is
never used again once its buffer is removed. -/
structure BufferId where
  /-- Which buffer. -/
  index : Nat
  deriving DecidableEq, Repr

/-- A save of a buffer that is in flight: its job has been started, and its
result has not yet been delivered. -/
structure Buffer.Saving where
  /-- The snapshot of the buffer's text the save writes. -/
  snapshot : SnapshotId
  /-- The state the text was in when the snapshot was taken: the one to
  mark as saved when the save reports. -/
  state : UndoTree.State
  deriving DecidableEq, Repr

/-- The file a buffer shows: where it is, and what the next save of it
expects to find there. -/
structure Buffer.File where
  /-- The file's path, as it was opened: a path is matched to a buffer by
  equality with this. -/
  path : System.FilePath
  /-- The stamp the last load or save of the file answered. -/
  stamp : File.Stamp
  /-- The save of the buffer that is in flight, if one is. -/
  saving : Option Buffer.Saving := none
  deriving DecidableEq, Repr

/-- A buffer: a text and what the editor keeps about it. -/
structure Buffer where
  /-- Its name, as the user sees it. -/
  name : String
  /-- Its text, in the text store. -/
  text : TextId
  /-- The history of its text. -/
  history : UndoTree
  /-- Its local values, by name. -/
  locals : Array (String × Value) := #[]
  /-- The name of its major mode, if it has one. -/
  major : Option String := none
  /-- The names of its minor modes, the one added last first. -/
  minors : Array String := #[]
  /-- The file it shows; `none` for a buffer that shows none. -/
  file : Option Buffer.File := none
  /-- The line break a command inserts in it: its file's dominant line
  ending, and a line feed for a buffer with no file or a file with no line
  break. Nothing else is decided by it. -/
  lineEnding : File.LineEnding := .lf
  deriving BEq, Repr

/-- Whether the buffer's text is in another state than the one last saved,
as its history knows it (`UndoTree.isModified`): right once the history was
told the revision the text is at, which the loop does before each scene. -/
def Buffer.isModified (buffer : Buffer) : Bool :=
  buffer.history.isModified

/-- A window: a view of a buffer. -/
structure Window where
  /-- The view's name in every scene. -/
  id : ViewId
  /-- The buffer it shows. -/
  buffer : BufferId
  /-- Its scroll position: an anchor marker of the buffer's text. -/
  scroll : MarkerId
  /-- Its selections: one selection marker of the buffer's text, whose
  ranges are its cursors. -/
  selection : MarkerId
  deriving DecidableEq, Repr

/-- The axis a split divides its rectangle along. -/
inductive Axis where
  /-- One child above the other. -/
  | rows
  /-- One child beside the other. -/
  | columns
  deriving DecidableEq, Repr

/-- The arrangement of a frame's windows. -/
inductive Split where
  /-- A window, by the name of its view. -/
  | window (id : ViewId)
  /-- The minibuffer's place. -/
  | minibuffer
  /-- `first` and `second` dividing a rectangle along `axis`: `first` above
  or to the left. -/
  | split (axis : Axis) (first second : Split)
  deriving DecidableEq, Repr

/-- The one window of the platform, and how the editor's windows are
arranged in it. -/
structure Frame where
  /-- Its size, in physical pixels. -/
  size : Size
  /-- Its split tree. -/
  tree : Split
  /-- The window that is focused within it. -/
  focused : ViewId
  /-- Whether it has the keyboard focus. -/
  hasFocus : Bool := true
  deriving DecidableEq, Repr

/-- A job a command asked to be started: the name it is registered under,
and the arguments to start it with. It is plain data: the job itself is
the registry's. -/
structure JobStart where
  /-- The name the job is registered under. -/
  name : String
  /-- What the job is started with, in order. -/
  arguments : List Argument := []
  deriving DecidableEq, Repr

/-- An open prompt: a request for one string ("Prompts", in the module
docs). It is plain data: the command that receives the answer is named. -/
structure Prompt where
  /-- The text shown beside the input. -/
  label : String
  /-- The minibuffer's view: the window the answer is typed in, which stands
  in the minibuffer's place while the prompt is open. -/
  view : ViewId
  /-- The asking view: the one that was focused when the prompt was asked
  for, which gets the focus back when the prompt is closed. -/
  asker : ViewId
  /-- The continuation: the command that receives the answer, and plain
  arguments of the asker's own, which follow the answer. -/
  continuation : Invocation
  deriving DecidableEq, Repr

/-- The name of the major mode the minibuffer's buffer is made with. A mode
is registered under it by whoever ships the minibuffer's commands
(`Editor/Minibuffer.lean`); with none registered it contributes nothing. -/
def Prompt.mode : String :=
  "minibuffer"

/-- What the minibuffer's buffer is called, unless a buffer already has the
name (`EditorState.freeName`). -/
def Prompt.bufferName : String :=
  "minibuffer"

/-- Everything the editor is showing and editing. -/
structure EditorState where
  /-- The buffers, one a slot; a `BufferId` is an index here, and the slot of
  a buffer that was removed is `none`. -/
  buffers : Array (Option Buffer)
  /-- The windows, each named by its view's id. -/
  windows : Array Window
  /-- The frame. -/
  frame : Frame
  /-- The echo area's text. -/
  echo : String := ""
  /-- The text an input method is composing in the focused window, if any. -/
  preedit : Option String := none
  /-- The id the next new window gets, unless a window already has one as
  great: an id is never used again. -/
  nextView : Nat := 1
  /-- The jobs commands asked to be started, in order, which the loop has
  not yet handed to its host. -/
  starts : Array JobStart := #[]
  /-- The prompt that is open, if one is: its view is a window of `windows`
  that is not in the frame's tree. -/
  prompt : Option Prompt := none
  /-- The continuations of the prompts commands accepted, each with its
  answer as its first argument, in order, which the loop has not yet handed
  to its host. -/
  answered : Array Invocation := #[]
  deriving BEq, Repr

/-- What a handler acts on: a window and the buffer it shows. -/
structure Target where
  /-- The window. -/
  window : Window
  /-- Its buffer. -/
  buffer : Buffer
  deriving BEq, Repr

/-- Why an operation on the layout was refused. -/
inductive LayoutRefusal where
  /-- It would remove the last window, leaving nothing to focus. -/
  | onlyWindow
  /-- The window is not in the frame's tree. -/
  | noSuchWindow (id : ViewId)
  /-- The state has no buffer of this id for a window to show. -/
  | noSuchBuffer (id : BufferId)
  /-- A marker handed in for a window is not a marker of the text of the
  buffer the window is to show. -/
  | markersOfAnotherText
  /-- The operation is on the minibuffer's window, `view`, or would show the
  minibuffer's buffer in another window: that window is closed by answering
  or cancelling its prompt, and only it shows its buffer. -/
  | ofMinibuffer (view : ViewId)
  deriving DecidableEq, Repr

/-- Why an operation on the prompt was refused. -/
inductive PromptRefusal where
  /-- A prompt is open already, in `view`: there is one at a time. -/
  | alreadyOpen (view : ViewId)
  /-- No prompt is open. -/
  | notOpen
  /-- The history or a marker handed in for the minibuffer is of another
  text than the minibuffer's. -/
  | notItsText
  /-- No window is focused for the prompt to be asked from. -/
  | noWindow
  deriving DecidableEq, Repr

/-- Why an operation on the prompt was refused, as a sentence for the echo
area. -/
def PromptRefusal.describe : PromptRefusal → String
  | .alreadyOpen _ => "a prompt is open already"
  | .notOpen => "no prompt is open"
  | .notItsText => "the minibuffer's history and markers are not of its text"
  | .noWindow => "no window is focused to ask from"

/-- Why an operation on a buffer was refused. -/
inductive BufferRefusal where
  /-- The state has no buffer of this id. -/
  | noSuchBuffer (id : BufferId)
  /-- A buffer already has this name. -/
  | nameTaken (name : String)
  /-- This window shows the buffer. -/
  | shown (view : ViewId)
  /-- The undo tree is the history of another text than the buffer's. -/
  | notItsHistory
  /-- Another buffer, `other`, holds the file at this path. -/
  | fileOpen (other : BufferId)
  /-- The buffer shows no file. -/
  | noFile
  /-- A save of the buffer is in flight. -/
  | beingSaved
  /-- No save of the buffer is in flight, or the one that is writes another
  snapshot. -/
  | notBeingSaved
  deriving DecidableEq, Repr

/-- Why a job was not started. -/
inductive JobRefusal where
  /-- No job is registered under this name. -/
  | noSuchJob (name : String)
  deriving DecidableEq, Repr

/-- Why a job was not started, as a sentence for the echo area. -/
def JobRefusal.describe : JobRefusal → String
  | .noSuchJob name => s!"no job is registered under {name}"

/-- Why setting a mode was refused. -/
inductive ModeRefusal where
  /-- The state has no window of this view. -/
  | noSuchWindow (id : ViewId)
  /-- No mode is registered under this name. -/
  | noSuchMode (name : String)
  deriving DecidableEq, Repr

namespace Split

/-- The windows of the tree, in drawing order. -/
def windows : Split → Array ViewId
  | .window id => #[id]
  | .minibuffer => #[]
  | .split _ first second => first.windows ++ second.windows

/-- How many minibuffer leaves the tree has. -/
def minibuffers : Split → Nat
  | .window _ => 0
  | .minibuffer => 1
  | .split _ first second => first.minibuffers + second.minibuffers

/-- The extent of `rect` along `axis`: its height for rows, and its width for
columns. -/
def extent (axis : Axis) (rect : Rect) : Nat :=
  match axis with
  | .rows => rect.height
  | .columns => rect.width

/-- `rect` cut in two along `axis`: the first part takes `first` of its
extent along the axis, or all of it when that is less, and the second the
rest. -/
def cut (axis : Axis) (rect : Rect) (first : Nat) : Rect × Rect :=
  let first := min first (extent axis rect)
  match axis with
  | .rows =>
    ({ rect with height := first },
      { rect with
        y := rect.y + first, height := rect.height - first })
  | .columns =>
    ({ rect with width := first },
      { rect with
        x := rect.x + first, width := rect.width - first })

/-- `rect` cut in two along `axis`: the first part takes half its extent
along the axis, rounded down, and the second the rest. -/
def halve (axis : Axis) (rect : Rect) : Rect × Rect :=
  cut axis rect (extent axis rect / 2)

/-- How much of its split's extent the minibuffer's place takes while a
prompt is open, in physical pixels: two rows of a 16-pixel cell, one for
the input and one for the status line that carries the prompt text. It is a
placeholder: nothing here knows the height of a row. -/
def minibufferHeight : Nat :=
  32

/-- Whether the subtree is the minibuffer's place and nothing else: it has
the minibuffer leaf and no window. -/
def isMinibufferPlace (tree : Split) : Bool :=
  tree.windows.isEmpty && tree.minibuffers > 0

/-- The rectangle of each view of the tree laid out in `rect`, in drawing
order: its windows, and `minibuffer`, the minibuffer's view while a prompt
is open, where the minibuffer's place is. A split halves its rectangle
along its axis; a subtree with no view takes nothing, and its sibling takes
all of it. So with no minibuffer's view the minibuffer's place takes
nothing. With one, a split one of whose children is the minibuffer's place
gives that place `minibufferHeight` along its axis, or the whole extent
when that is less, and the sibling the rest. -/
def rects (tree : Split) (rect : Rect) (minibuffer : Option ViewId := none) :
    Array (ViewId × Rect) :=
  match tree with
  | .window id => #[(id, rect)]
  | .minibuffer => (minibuffer.map (·, rect)).toArray
  | .split axis first second =>
    let empty (child : Split) : Bool :=
      child.windows.isEmpty && !(minibuffer.isSome && child.isMinibufferPlace)
    if empty first then second.rects rect minibuffer
    else
      if empty second then first.rects rect minibuffer
      else
        let (one, other) :=
          if first.isMinibufferPlace then cut axis rect minibufferHeight
          else
            if second.isMinibufferPlace then
              cut axis rect (extent axis rect - min minibufferHeight (extent axis rect))
            else halve axis rect
        first.rects one minibuffer ++ second.rects other minibuffer

/-- The tree without the window `id`, whose sibling takes the place of the
split that held both, and that sibling; `none` when `id` is not a leaf of the
tree or is the whole tree. -/
def remove (id : ViewId) : Split → Option (Split × Split)
  | .window _ | .minibuffer => none
  | .split axis first second =>
    if first == .window id then some (second, second)
    else
      if second == .window id then some (first, first)
      else
        match first.remove id with
        | some (rest, took) => some (.split axis rest second, took)
        | none => (second.remove id).map fun (rest, took) => (.split axis first rest, took)

/-- The tree with the window `id` in a split of its own, first, along
`axis`, and the window `made` second: below it for rows, to its right for
columns. A tree that does not have `id` is as it was. -/
def divide (id : ViewId) (axis : Axis) (made : ViewId) : Split → Split
  | .window leaf => if leaf == id then .split axis (.window leaf) (.window made) else .window leaf
  | .minibuffer => .minibuffer
  | .split along first second =>
    .split along (first.divide id axis made) (second.divide id axis made)

end Split

namespace EditorState

/-- The window whose view is `id`, if there is one. -/
def window? (state : EditorState) (id : ViewId) : Option Window :=
  state.windows.find? (·.id == id)

/-- The buffer `id` names, if there is one: none for an id no buffer was
given, and for one whose buffer was removed. -/
def buffer? (state : EditorState) (id : BufferId) : Option Buffer :=
  state.buffers[id.index]?.join

/-- The window whose view is `id` and its buffer: what a handler acting on
that view is given. -/
def target? (state : EditorState) (id : ViewId) : Option Target := do
  let window ← state.window? id
  let buffer ← state.buffer? window.buffer
  return { window, buffer }

/-- The focused window and its buffer. -/
def focusedTarget? (state : EditorState) : Option Target :=
  state.target? state.frame.focused

/-- The minibuffer's view: the open prompt's, if a prompt is open. -/
def minibufferView? (state : EditorState) : Option ViewId :=
  state.prompt.map (·.view)

/-- The minibuffer's buffer: the one the open prompt's window shows, if a
prompt is open. -/
def minibufferBuffer? (state : EditorState) : Option BufferId := do
  return (← state.window? (← state.minibufferView?)).buffer

/-- The views of the state: the windows of the frame's tree, in drawing
order, then the minibuffer's view while a prompt is open. -/
def views (state : EditorState) : Array ViewId :=
  state.frame.tree.windows ++ state.minibufferView?.toArray

/-- Whether the state keeps the layout invariants, over its views
(`views`: the tree's windows, then the open prompt's view): the focused
window is among them, the tree has one minibuffer leaf, the views' ids are
distinct and are exactly the windows' ids, and each window's buffer
exists. -/
def wellFormed (state : EditorState) : Bool :=
  let ids := state.views
  ids.contains state.frame.focused && state.frame.tree.minibuffers == 1 &&
    ids.toList.eraseDups.length == ids.size &&
    ids.size == state.windows.size &&
    ids.all (fun id => (state.window? id).isSome) &&
    state.windows.all fun window => (state.buffer? window.buffer).isSome

/-- A buffer called `scratch` over a new empty text, and one window on it,
focused, in a frame of `size` with the minibuffer's place below it. The
window's scroll anchor is at 0, and its selection one exclusive cursor at
0. -/
def initial (size : Size) : TextM EditorState := do
  let text ← createText ""
  let scroll ← text.mark (.anchor { offset := 0, bias := .before })
  let selection ← text.mark (.selection { ranges := #[⟨0, 0⟩], shape := .exclusive })
  let history ← UndoTree.over text
  return {
      buffers := #[some { name := "scratch", text, history }]
      windows := #[{ id := ⟨0⟩, buffer := ⟨0⟩, scroll, selection }]
      frame := { size, tree := .split .rows (.window ⟨0⟩) .minibuffer, focused := ⟨0⟩ } }

/-- Removes the window `id` from the frame: its sibling takes the place of
the split that held both, and the window is handed back, its markers the
caller's to give up. A focused window's focus moves to the first window of
what took its place, or of the tree when that has none. Refused, with the
state unchanged, with `ofMinibuffer` for the minibuffer's window, with
`noSuchWindow` for a window not in the tree and with `onlyWindow` for the
last one of the tree: the minibuffer's window does not count. -/
def removeWindow (id : ViewId) (state : EditorState) : Except LayoutRefusal Window × EditorState :=
  let tree := state.frame.tree
  match state.minibufferView? == some id, state.window? id, tree.windows.contains id with
  | true, _, _ => (.error (.ofMinibuffer id), state)
  | false, some window, true =>
    match tree.remove id with
    | some (rest, took) =>
      if rest.windows.isEmpty then (.error .onlyWindow, state)
      else
        let focused :=
          if state.frame.focused == id then
            (took.windows[0]?).getD ((rest.windows[0]?).getD state.frame.focused)
          else state.frame.focused
        (.ok window,
          { state with
            windows := state.windows.filter (·.id != id)
            frame :=
              { state.frame with
                tree := rest, focused } })
    | none => (.error .onlyWindow, state)
  | false, _, _ => (.error (.noSuchWindow id), state)

/-- Focuses the window `id`: a window of the tree, or the minibuffer's while
a prompt is open. Refused, with the state unchanged, with `noSuchWindow`
for any other. -/
def focusWindow (id : ViewId) (state : EditorState) : Except LayoutRefusal Unit × EditorState :=
  if state.views.contains id then
    (.ok (), { state with frame := { state.frame with focused := id } })
  else (.error (.noSuchWindow id), state)

/-- `state` with the buffer `id` changed by `change`, and what `change`
said. Refused, with the state unchanged, with `noSuchBuffer` for a buffer
there is none of. -/
private def changeBuffer {α : Type} (id : BufferId) (change : Buffer → α × Buffer)
    (state : EditorState) : Except BufferRefusal α × EditorState :=
  match state.buffer? id with
  | some buffer =>
    let (said, changed) := change buffer
    (.ok said, { state with buffers := state.buffers.set! id.index (some changed) })
  | none => (.error (.noSuchBuffer id), state)

/-- Makes the mode `name` the major mode of the buffer `id`, and says
whether it became the major mode: `false`, with nothing changed, when the
buffer already had it. Any name is taken. Refused, with the state
unchanged, with `noSuchBuffer` for a buffer there is none of. -/
def setMajorMode (id : BufferId) (name : String) (state : EditorState) :
    Except BufferRefusal Bool × EditorState :=
  changeBuffer id
    (fun buffer =>
      if buffer.major == some name then (false, buffer)
      else (true, { buffer with major := some name }))
    state

/-- Adds the minor mode `name` to the buffer `id`, first; a minor mode the
buffer already has changes nothing. Refused, with the state unchanged,
with `noSuchBuffer` for a buffer there is none of. -/
def addMinorMode (id : BufferId) (name : String) (state : EditorState) :
    Except BufferRefusal Unit × EditorState :=
  changeBuffer id
    (fun buffer =>
      if buffer.minors.contains name then ((), buffer)
      else ((), { buffer with minors := #[name] ++ buffer.minors }))
    state

/-- Removes the minor mode `name` from the buffer `id`; one the buffer does
not have changes nothing. Refused, with the state unchanged, with
`noSuchBuffer` for a buffer there is none of. -/
def removeMinorMode (id : BufferId) (name : String) (state : EditorState) :
    Except BufferRefusal Unit × EditorState :=
  changeBuffer id (fun buffer => ((), { buffer with minors := buffer.minors.filter (· != name) }))
    state

/-- An editor with no buffer and no window, in a frame of no size whose tree
is the minibuffer's place alone. It is not well formed: nothing is focused.
It is what a command's state requests are answered from where no loop runs
the command. -/
protected def none : EditorState :=
  { buffers := #[], windows := #[],
    frame := { size := ⟨0, 0⟩, tree := .minibuffer, focused := ⟨0⟩ } }

/-- The buffer called `name`, if there is one. Names are unique among the
buffers a request added (`addBuffer`), so there is at most one. -/
def findBuffer (state : EditorState) (name : String) : Option BufferId :=
  (state.buffers.findIdx? fun slot => slot.any (·.name == name)).map (⟨·⟩)

/-- The buffer that holds the file at `path`, if one does: the one whose
file's path is equal to it, as a string. A request attaches a path to one
buffer only (`attachFile`), so there is at most one. -/
def findFile (state : EditorState) (path : System.FilePath) : Option BufferId :=
  (state.buffers.findIdx? fun slot => slot.any (·.file.any (·.path == path))).map (⟨·⟩)

/-- A name no buffer has, for a new buffer that would be called `name`: the
name itself, or the name followed by `<2>`, `<3>` and so on, the first no
buffer has. With `n` buffers one of the first `n + 1` candidates is free. -/
def freeName (state : EditorState) (name : String) : String :=
  let free (candidate : String) : Bool := (state.findBuffer candidate).isNone
  if free name then name
  else
    (((List.range (state.buffers.size + 1)).map fun index => s!"{name}<{index + 2}>").find?
          free).getD
      name

/-- Has the buffer `id` hold the file at `path`, whose stamp is `stamp`,
and gives it the line ending `ending`. Its history is left as it is.
Refused, with the state unchanged, with `noSuchBuffer` for a buffer there
is none of, and with `fileOpen`, and the buffer that holds it, for a path
another buffer holds. -/
def attachFile (id : BufferId) (path : System.FilePath) (stamp : File.Stamp)
    (ending : File.LineEnding) (state : EditorState) : Except BufferRefusal Unit × EditorState :=
  match state.buffer? id, state.findFile path with
  | none, _ => (.error (.noSuchBuffer id), state)
  | some _, some holder => if holder == id then attached else (.error (.fileOpen holder), state)
  | some _, none => attached
where
  /-- The state with the file attached. -/
  attached : Except BufferRefusal Unit × EditorState :=
    changeBuffer id
      (fun buffer =>
        ((),
          { buffer with
            file := some { path, stamp }, lineEnding := ending }))
      state

/-- Records a save of the buffer `id` as in flight: it writes `snapshot`,
which was taken with the buffer's text in the state `saved`. Refused, with
the state unchanged, with `noSuchBuffer` for a buffer there is none of,
with `noFile` for a buffer that shows no file, and with `beingSaved` while
a save of it is in flight. -/
def beginSave (id : BufferId) (snapshot : SnapshotId) (saved : UndoTree.State)
    (state : EditorState) : Except BufferRefusal Unit × EditorState :=
  match state.buffer? id with
  | none => (.error (.noSuchBuffer id), state)
  | some buffer =>
    match buffer.file with
    | none => (.error .noFile, state)
    | some file =>
      if file.saving.isSome then (.error .beingSaved, state)
      else
        changeBuffer id
          (fun buffer =>
            ((),
              { buffer with
                file := some { file with saving := some { snapshot, state := saved } } }))
          state

/-- Ends the save of the buffer `id` that writes `snapshot`: the save is no
longer in flight. With the stamp of the file it wrote, the buffer's file
has that stamp, and the state the save kept is the one marked as saved in
the buffer's history (`UndoTree.markSaved`), wherever the text is by now.
With `none`, for a save that was refused, neither changes. Refused, with
the state unchanged, with `noSuchBuffer` for a buffer there is none of, and
with `notBeingSaved` unless a save of the buffer that writes `snapshot` is
in flight. -/
def endSave (id : BufferId) (snapshot : SnapshotId) (stamp : Option File.Stamp)
    (state : EditorState) : Except BufferRefusal Unit × EditorState :=
  match state.buffer? id with
  | none => (.error (.noSuchBuffer id), state)
  | some buffer =>
    match buffer.file with
    | none => (.error .notBeingSaved, state)
    | some file =>
      match file.saving with
      | none => (.error .notBeingSaved, state)
      | some saving =>
        if saving.snapshot != snapshot then (.error .notBeingSaved, state)
        else
          let ended : Buffer :=
            match stamp with
            | some stamp =>
              { buffer with
                file :=
                  some
                    { file with
                      stamp, saving := none }
                history := buffer.history.markSaved saving.state }
            | none => { buffer with file := some { file with saving := none } }
          changeBuffer id (fun _ => ((), ended)) state

/-- The value the buffer `id` keeps under `name`, if it keeps one. -/
def value? (state : EditorState) (id : BufferId) (name : String) : Option Value := do
  let buffer ← state.buffer? id
  (← buffer.locals.find? (·.1 == name)).2

/-- Adds a buffer called `name` over `text`, whose history is `history`, in
the next slot, and hands back its id. Refused, with the state unchanged,
with `nameTaken` for a name a buffer already has, and with `notItsHistory`
for a history over another text. -/
def addBuffer (name : String) (text : TextId) (history : UndoTree) (state : EditorState) :
    Except BufferRefusal BufferId × EditorState :=
  if (state.findBuffer name).isSome then (.error (.nameTaken name), state)
  else
    if history.text != text then (.error .notItsHistory, state)
    else
      (.ok ⟨state.buffers.size⟩,
        { state with buffers := state.buffers.push (some { name, text, history }) })

/-- Removes the buffer `id`: its slot is empty from then on, and its id is
never used again. Its text is the caller's to release. Refused, with the
state unchanged, with `noSuchBuffer` for a buffer there is none of, and
with `shown`, and the first such view, while a window shows it. -/
def removeBuffer (id : BufferId) (state : EditorState) : Except BufferRefusal Unit × EditorState :=
  match state.buffer? id, state.windows.find? (·.buffer == id) with
  | none, _ => (.error (.noSuchBuffer id), state)
  | some _, some window => (.error (.shown window.id), state)
  | some _, none => (.ok (), { state with buffers := state.buffers.set! id.index none })

/-- Makes `history` the undo tree of the buffer `id`. Refused, with the
state unchanged, with `noSuchBuffer` for a buffer there is none of, and
with `notItsHistory` for a tree over another text than the buffer's. -/
def setHistory (id : BufferId) (history : UndoTree) (state : EditorState) :
    Except BufferRefusal Unit × EditorState :=
  match state.buffer? id with
  | none => (.error (.noSuchBuffer id), state)
  | some buffer =>
    if history.text != buffer.text then (.error .notItsHistory, state)
    else changeBuffer id (fun buffer => ((), { buffer with history })) state

/-- Has the buffer `id` keep `value` under `name`, in place of the value the
name had, if it had one. Refused, with the state unchanged, with
`noSuchBuffer` for a buffer there is none of. -/
def setValue (id : BufferId) (name : String) (value : Value) (state : EditorState) :
    Except BufferRefusal Unit × EditorState :=
  changeBuffer id
    (fun buffer =>
      ((),
        { buffer with
          locals :=
            if buffer.locals.any (·.1 == name) then
              buffer.locals.map fun kept => if kept.1 == name then (name, value) else kept
            else buffer.locals.push (name, value) }))
    state

/-- The id a new window gets: `nextView`, or one more than the greatest id
a window has when that is greater. -/
def freshView (state : EditorState) : ViewId :=
  ⟨state.windows.foldl (fun least window => max least (window.id.index + 1)) state.nextView⟩

/-- Splits the window `id` along `axis`: a new window on the same buffer,
with `scroll` and `selection` as its markers, is second in a split where
`id` was, and its id is handed back. The focus stays. Refused, with the
state unchanged, with `ofMinibuffer` for the minibuffer's window, with
`noSuchWindow` for a window not in the tree, and with
`markersOfAnotherText` when a marker is not of that buffer's text. -/
def splitWindow (id : ViewId) (axis : Axis) (scroll selection : MarkerId) (state : EditorState) :
    Except LayoutRefusal ViewId × EditorState :=
  match state.minibufferView? == some id, state.target? id,
    state.frame.tree.windows.contains id with
  | true, _, _ => (.error (.ofMinibuffer id), state)
  | false, some target, true =>
    if scroll.text != target.buffer.text || selection.text != target.buffer.text then
      (.error .markersOfAnotherText, state)
    else
      let made := state.freshView
      (.ok made,
        { state with
          windows :=
            state.windows.push { id := made, buffer := target.window.buffer, scroll, selection }
          frame := { state.frame with tree := state.frame.tree.divide id axis made }
          nextView := made.index + 1 })
  | false, _, _ => (.error (.noSuchWindow id), state)

/-- Has the window `id` show the buffer `buffer`, with `scroll` and
`selection` as its markers. Refused, with the state unchanged, with
`ofMinibuffer`, and the minibuffer's view, for the minibuffer's window and
for the minibuffer's buffer in another window, with `noSuchWindow` for a
window not in the tree, with `noSuchBuffer` for a buffer there is none of,
and with `markersOfAnotherText` when a marker is not of that buffer's
text. -/
def showBuffer (id : ViewId) (buffer : BufferId) (scroll selection : MarkerId)
    (state : EditorState) : Except LayoutRefusal Unit × EditorState :=
  match state.minibufferView? with
  | some view =>
    if view == id || state.minibufferBuffer? == some buffer then
      (.error (.ofMinibuffer view), state)
    else showing
  | none => showing
where
  /-- The state with the buffer shown, for a window and a buffer that are
  not the minibuffer's. -/
  showing : Except LayoutRefusal Unit × EditorState :=
    if (state.window? id).isNone || !state.frame.tree.windows.contains id then
      (.error (.noSuchWindow id), state)
    else
      match state.buffer? buffer with
      | none => (.error (.noSuchBuffer buffer), state)
      | some shown =>
        if scroll.text != shown.text || selection.text != shown.text then
          (.error .markersOfAnotherText, state)
        else
          (.ok (),
            { state with
              windows :=
                state.windows.map fun window =>
                  if window.id == id then
                    { window with
                      buffer, scroll, selection }
                  else window })

/-- Opens a prompt, asked from the focused view: a buffer in the next slot
over `text`, whose history is `history`, with the minibuffer's mode
(`Prompt.mode`) and a name no buffer has (`Prompt.bufferName`, made free),
and a window on it, with a new view id and `scroll` and `selection` as its
markers. The prompt is recorded with `label`, `continuation` and the
focused view as its asker; the new view is focused and handed back. The
tree is as it was. Refused, with the state unchanged, with `alreadyOpen`,
and its view, while a prompt is open, with `noWindow` when the focused view
has no window, and with `notItsText` for a history or a marker of another
text than `text`. -/
def openPrompt (label : String) (continuation : Invocation) (text : TextId) (history : UndoTree)
    (scroll selection : MarkerId) (state : EditorState) :
    Except PromptRefusal ViewId × EditorState :=
  match state.prompt, state.window? state.frame.focused with
  | some asked, _ => (.error (.alreadyOpen asked.view), state)
  | none, none => (.error .noWindow, state)
  | none, some asker =>
    if history.text != text || scroll.text != text || selection.text != text then
      (.error .notItsText, state)
    else
      let view := state.freshView
      (.ok view,
        { state with
          buffers :=
            state.buffers.push
              (some
                { name := state.freeName Prompt.bufferName, text, history
                  major := some Prompt.mode })
          windows :=
            state.windows.push { id := view, buffer := ⟨state.buffers.size⟩, scroll, selection }
          frame := { state.frame with focused := view }
          nextView := view.index + 1
          prompt := some { label, view, asker := asker.id, continuation } })

/-- Closes the open prompt: the minibuffer's window is removed, its buffer's
slot is emptied, and the focus goes to the asking view, or, when that view
is no longer a window of the tree, to the first window of the tree, in
drawing order. The tree is as it was. Given an answer, the prompt's
continuation is recorded with the answer as its first argument, before its
own (`answered`). The minibuffer's markers and text are the caller's to
give up. Refused, with the state unchanged, with `notOpen` when no prompt
is open. -/
def closePrompt (answer : Option String) (state : EditorState) :
    Except PromptRefusal Unit × EditorState :=
  match state.prompt with
  | none => (.error .notOpen, state)
  | some asked =>
    let windows := state.frame.tree.windows
    let focused :=
      if windows.contains asked.asker then asked.asker else windows[0]?.getD asked.asker
    (.ok (),
      { state with
        buffers :=
          match state.minibufferBuffer? with
          | some buffer => state.buffers.set! buffer.index none
          | none => state.buffers
        windows := state.windows.filter (·.id != asked.view)
        frame := { state.frame with focused }
        prompt := none
        answered :=
          match answer with
          | some answer =>
            state.answered.push
              { asked.continuation with arguments := .str answer :: asked.continuation.arguments }
          | none => state.answered })

end EditorState

end Editor
