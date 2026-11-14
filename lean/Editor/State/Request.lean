import Editor.Invocation
import Editor.State

/-!
# The state requests

What a command asks of the editor state (`Editor/State.lean`): its buffers
and the files they hold, its windows, the echo area, the jobs to start and
the prompt.
A `StateRequest` is a request of the editor's port (`EditorRequest.state`,
`Editor/Command.lean`), and `EditorState.handle` is its handler: one pure
function from a request and a state to the reply and the state after it. It
reaches nothing outside the state, so it has no model and no binding: the
loop that runs a command answers the command's state requests with it, on
the models and against the library alike (`Editor/Command/Dispatch.lean`).

## The rules

- **A question is one read.** `read` hands back the whole state, and a
  question is a pure function over it (`EditorState.buffer?`, `target?`,
  `findBuffer`, `value?`, `frame.focused`). There is no request a question.
- **A write is a request of its own.** Each is one operation of
  `Editor/State.lean`, which keeps the layout invariants: a command cannot
  put a state of its own making in place of the editor's.
- **A refusal is a value.** A reply that can be refused is an `Except` of
  the operation's refusal (`LayoutRefusal`, `BufferRefusal`, `ModeRefusal`,
  `JobRefusal`, `PromptRefusal`), with the state as it was. Nothing is thrown, so a command
  matches on it, and a command's error stays a `TextError`.
- **A request holds plain data.** It cannot hold a command or a job, which
  are programs over ports that would then refer to themselves: a mode is
  named, and so is a job, and what the name stands for is the registry's.
  So two requests are answered with more than this handler by the loop,
  which knows the registry: `setMajorMode`, which there refuses a name no
  mode is registered under and runs the mode's on-enter actions, and
  `startJob`, which there refuses a name no job is registered under. Here
  each takes any name.
- **A marker is made by the caller.** `split` and `show` are handed the
  markers of the window they make or change, which the command marked on
  the buffer's text first: the handler asks the text store nothing.
- **A prompt's minibuffer is made by the caller too.** `openPrompt` is
  handed the minibuffer's text, a history over it and the two markers of
  its window, and names the command that receives the answer as an
  invocation (`Editor/State.lean`, "Prompts"). It is refused with a
  `PromptRefusal`.
- **A prompt is closed by one request**, `closePrompt`, with the answer or
  with none. Closing the minibuffer's window and recording the answer are
  that one request, which asks the text store nothing, so the command that
  makes it cannot be interrupted between the two. The handler releases
  nothing: the loop gives up the minibuffer's markers and text once the
  command has run to its end.
- **A window's wanted column is set by one request**, `setWanted`, with
  the column and the offset it is kept at, or with none
  (`Editor/State.lean`, "The wanted column"). It is refused with a
  `LayoutRefusal`, `noSuchWindow`, for a view with no window.
- **A file is attached by one request, and a save is two.** `attachFile`
  has a buffer hold a file a load answered. `beginSave` records a save in
  flight, with the snapshot it writes, which the command took first, and
  `endSave` ends it with what the save answered: the stamp and the saved
  mark are set by that one request (`Editor/State.lean`, "A buffer's
  file"). The handler releases no snapshot: the loop does, once the
  command that ended the save has run to its end.

## Where an addition goes

| Addition | Where |
|---|---|
| A question about the state | A pure function over `EditorState` (`Editor/State.lean`); nothing here |
| A new way to change the state | An operation in `Editor/State.lean`, a constructor here with its case in `Reply` and in `handle`, and the operation a command calls in `Editor/Api.lean` |
| A request that needs the registry | The same, and its case in `EditorM.dispatched` (`Editor/Command/Dispatch.lean`) |

Pinned by `ModelTest.stateRequestChecks`.
-/

namespace Editor

/-- What a command may ask of the editor state. -/
inductive StateRequest where
  /-- The whole state, as it is. -/
  | read
  /-- Add a buffer called `name` over `text`, whose history is `history`. -/
  | addBuffer (name : String) (text : TextId) (history : UndoTree)
  /-- Remove the buffer `id`. -/
  | removeBuffer (id : BufferId)
  /-- Make `history` the undo tree of the buffer `id`. -/
  | setHistory (id : BufferId) (history : UndoTree)
  /-- Have the buffer `id` keep `value` under `name`. -/
  | setValue (id : BufferId) (name : String) (value : Value)
  /-- Make the mode called `name` the major mode of the buffer `view`
  shows. -/
  | setMajorMode (view : ViewId) (name : String)
  /-- Add the minor mode called `name` to the buffer `id`. -/
  | addMinorMode (id : BufferId) (name : String)
  /-- Remove the minor mode called `name` from the buffer `id`. -/
  | removeMinorMode (id : BufferId) (name : String)
  /-- Split the window `view` along `axis`: a new window on its buffer, with
  `scroll` and `selection` as its markers. -/
  | split (view : ViewId) (axis : Axis) (scroll selection : MarkerId)
  /-- Remove the window `view`. -/
  | removeWindow (view : ViewId)
  /-- Focus the window `view`. -/
  | focus (view : ViewId)
  /-- Have the window `view` show the buffer `buffer`, with `scroll` and
  `selection` as its markers. -/
  | «show» (view : ViewId) (buffer : BufferId) (scroll selection : MarkerId)
  /-- Put `text` in the echo area. -/
  | message (text : String)
  /-- Start the job registered under `name`, with `arguments`. -/
  | startJob (name : String) (arguments : List Argument)
  /-- Have the buffer `id` hold the file at `path`, whose stamp is `stamp`,
  with `ending` as the buffer's line ending. -/
  |
  attachFile (id : BufferId) (path : System.FilePath) (stamp : File.Stamp)
    (ending : File.LineEnding)
  /-- Record a save of the buffer `id` as in flight: it writes `snapshot`,
  taken with the buffer's text in the state `saved`. -/
  | beginSave (id : BufferId) (snapshot : SnapshotId) (saved : UndoTree.State)
  /-- End the save of the buffer `id` that writes `snapshot`: with the stamp
  of the file it wrote, or with `none` for a save that was refused. -/
  | endSave (id : BufferId) (snapshot : SnapshotId) (stamp : Option File.Stamp)
  /-- Open a prompt labelled `label`, whose answer the command of
  `continuation` receives: the minibuffer is a buffer over `text`, whose
  history is `history`, in a window with `scroll` and `selection` as its
  markers. -/
  |
  openPrompt (label : String) (continuation : Invocation) (text : TextId) (history : UndoTree)
    (scroll selection : MarkerId)
  /-- Close the open prompt: with `answer`, which its continuation's command
  receives, or with `none` for a prompt that is cancelled. -/
  | closePrompt (answer : Option String)
  /-- Have the window `view` keep `wanted` as its wanted column, or none. -/
  | setWanted (view : ViewId) (wanted : Option Window.Wanted)

/-- The type of the reply to each request. -/
abbrev StateRequest.Reply : StateRequest → Type
  | .read => EditorState
  | .addBuffer .. => Except BufferRefusal BufferId
  | .removeBuffer _ => Except BufferRefusal Unit
  | .setHistory .. => Except BufferRefusal Unit
  | .setValue .. => Except BufferRefusal Unit
  | .setMajorMode .. => Except ModeRefusal Bool
  | .addMinorMode .. => Except BufferRefusal Unit
  | .removeMinorMode .. => Except BufferRefusal Unit
  | .split .. => Except LayoutRefusal ViewId
  | .removeWindow _ => Except LayoutRefusal Window
  | .focus _ => Except LayoutRefusal Unit
  | .show .. => Except LayoutRefusal Unit
  | .message _ => Unit
  | .startJob .. => Except JobRefusal Unit
  | .attachFile .. => Except BufferRefusal Unit
  | .beginSave .. => Except BufferRefusal Unit
  | .endSave .. => Except BufferRefusal Unit
  | .openPrompt .. => Except PromptRefusal ViewId
  | .closePrompt _ => Except PromptRefusal Unit
  | .setWanted .. => Except LayoutRefusal Unit

namespace EditorState

/-- Makes the mode called `name` the major mode of the buffer the window
`view` shows, and says whether it became the major mode
(`EditorState.setMajorMode`). Any name is taken. Refused, with the state
unchanged, with `noSuchWindow` for a view with no window. -/
def setMajorModeOf (view : ViewId) (name : String) (state : EditorState) :
    Except ModeRefusal Bool × EditorState :=
  match state.target? view with
  | none => (.error (.noSuchWindow view), state)
  | some target =>
    match state.setMajorMode target.window.buffer name with
    | (.ok became, next) => (.ok became, next)
    | (.error _, _) => (.error (.noSuchWindow view), state)

/-- The reply to `request` from `state`, and the state after it: each
request is its operation of `Editor/State.lean`. A refused request leaves
the state as it was. -/
def handle : (request : StateRequest) → EditorState → request.Reply × EditorState
  | .read, state => (state, state)
  | .addBuffer name text history, state => state.addBuffer name text history
  | .removeBuffer id, state => state.removeBuffer id
  | .setHistory id history, state => state.setHistory id history
  | .setValue id name value, state => state.setValue id name value
  | .setMajorMode view name, state => state.setMajorModeOf view name
  | .addMinorMode id name, state => state.addMinorMode id name
  | .removeMinorMode id name, state => state.removeMinorMode id name
  | .split view axis scroll selection, state => state.splitWindow view axis scroll selection
  | .removeWindow view, state => state.removeWindow view
  | .focus view, state => state.focusWindow view
  | .show view buffer scroll selection, state => state.showBuffer view buffer scroll selection
  | .message text, state => ((), { state with echo := text })
  | .startJob name arguments, state =>
    (.ok (), { state with starts := state.starts.push { name, arguments } })
  | .attachFile id path stamp ending, state => state.attachFile id path stamp ending
  | .beginSave id snapshot saved, state => state.beginSave id snapshot saved
  | .endSave id snapshot stamp, state => state.endSave id snapshot stamp
  | .openPrompt label continuation text history scroll selection, state =>
    state.openPrompt label continuation text history scroll selection
  | .closePrompt answer, state => state.closePrompt answer
  | .setWanted view wanted, state => state.setWanted view wanted

end EditorState

end Editor
