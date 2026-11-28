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
  `JobRefusal`, `PromptRefusal`, `ThemeRefusal`, `WorkspaceRefusal`), with the state as it was. Nothing is thrown, so a command
  matches on it, and a command's error stays a `TextError`.
- **A request holds plain data.** It cannot hold a command or a job, which
  are programs over ports that would then refer to themselves: a mode is
  named, and so is a job, and what the name stands for is the registry's.
  So five requests are answered with more than this handler by the loop,
  which knows the registry: `setMajorMode` and `setBufferMajorMode`, which
  there refuse a name no mode is registered under and run the mode's
  on-enter actions, `startJob`, which there refuses a name no job is
  registered under, `loadTheme`, which there refuses a name no theme
  is registered under, and `rehighlight`, which there highlights again the
  buffers whose language names one of its grammars. Here they take any
  name: this handler knows no registry. Each but `rehighlight` is still a
  state operation, which this handler makes; this handler answers
  `rehighlight` and changes nothing.
- **Every request is answered from the state.** A question to the registry
  or config is `RegistryRequest`'s (`Editor/Command/Registry.lean`), and
  what ends the command or runs something registered inside it is
  `ControlRequest`'s (`Editor/Command/Control.lean`): both are sub-ports of
  their own, which the loop answers. So the handler has no case it cannot
  answer from the state.
- **A marker is made by the caller.** `split`, `show` and `openWindow` are
  handed the markers of the window they make or change, which the command
  marked on the buffer's text first: the handler asks the text store
  nothing.
- **A new window on a buffer is opened by one request**, `openWindow`,
  with its spot (`WindowSpot`): after the last window of the tiled list,
  or docked at an edge. It is refused with a `LayoutRefusal`, the state as
  it was, `noSuchEdge` among them for an edge the layout has none at.
  Where a buffer goes is the asking command's to decide, with the display
  rules (`RegistryRequest.displayRules`, `EditorState.displaying`).
- **The frame's tabs are changed by one request**, `tab`, with the change
  as data (`TabChange`: select, close, rename, move). A new tab is a spot
  of `openWindow` (`WindowSpot.tab`). It is refused with a
  `LayoutRefusal`, the state as it was.
- **A window's place and its layout's parameters are changed by one
  request**, `arrange`, with the change as data (`Arrange`: promote,
  demote, rotate, exchange, zoom, balance, resize, main's count and the
  move between an edge and the tiles), so a
  new change is a variant there and no request of its own. It is refused
  with a `LayoutRefusal`, the state as it was. `split` takes a placement
  (`Placement`), which only manual splits read.
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
- **An open prompt's candidates are set by one request, and its choice is
  moved by another**: `setCandidates`, with what the prompt's sources
  answered (`Completion.Collected`), and
  `chooseCandidate`, with a step (`Editor/State.lean`, "Prompts"). Each is
  refused with a `PromptRefusal`, `notOpen`, when no prompt is open. The
  listing has no request: the loop makes it, between a command and the
  scene, from what the prompt's style answers (`Editor/Loop.lean`), so no
  command can list what the style did not answer.
- **What comes later is taken by five requests, none guarded**, so a
  delivery is not interrupted between them (`Editor/Completion/Later.lean`):
  `addCandidates`, a batch of a source's job, taken only for the open
  prompt's view, the source's index and its generation, and dropped
  otherwise (a stale job's), with a `Bool` reply; `sourceAnswered`, the
  end of that job; `sourceFailed`, the end of a job that threw, which says
  `<source>: <message>` in the echo area; `listMatched`, the listing a match job made, kept only
  for the match in flight; and `matchFailed`, a match job that could not
  list, which says why in the echo area. Each is the operation of the same
  name (`Editor/State.lean`, "Prompts"). A delivery is never wrong to
  list: it holds the candidates themselves, not indices.
- **An invocation to run next is recorded by one request**, `invoke`: it
  is put after the invocations already recorded
  (`EditorState.Outbox.answered`), a prompt's answer among them, and the
  loop hands them to its host once the command has run to its end
  (`Editor/Loop.lean`, "Prompts"). This is how a command has another run
  after it, as a step of its own.
- **A session at point is opened, moved, retyped, retaken and closed by
  one request each** (`openAtPoint`, `chooseAtPoint`, `retypeAtPoint`,
  `retakeAtPoint`, `closeAtPoint`), each refused with an `AtPointRefusal`
  (`Editor/State.lean`, "A session at point"). Which at-point sources a
  buffer's chain has for an occasion is a question to the registry
  (`RegistryRequest.atPointSources`, `Editor/Command/Registry.lean`), and
  an at-point source's region is asked inside the asking command
  (`ControlRequest.askAtPoint`, `Editor/Command/Control.lean`). `retype`
  records what a command typed in
  place of typed text (`EditorState.retyped`), which the loop tells the
  input scheme once the command has run to its end.
- **The editor is asked to quit by one request**, `quit`, which sets the
  state's flag and nothing else (`Editor/State.lean`, "Quit"). The handler
  does not judge whether the editor may quit: the command that asks
  checks first (`quit`, `Editor/Api.lean`), since that needs the text
  store, and the loop decides when the editor leaves.
- **A job is started by one request, and cancelled by another.**
  `startJob` keeps the start, with its name, its arguments and its key if
  it has one, in the state's outbox (`EditorState.Outbox.starts`,
  `Editor/State/Outbox.lean`, "The outbox"), and `cancelJob` keeps a key
  (`EditorState.Outbox.cancels`), until the loop hands them to its host
  once the command has run to its end (`Editor/Loop.lean`, "Jobs from
  commands"). A start of a key cancels the running job of that key, and a
  cancel ends the job of its key; the host keeps the keys.
- **A reload of the config is asked for by one request**, `reload`,
  which sets a flag of the state (`EditorState.Outbox.reload`) until the
  loop hands it to its host, as `starts` holds the jobs a command asked
  for (`Editor/Loop.lean`, "Reload from a command").
- **A theme is loaded by one request**, `loadTheme`, which keeps the name
  in the state (`EditorState.Outbox.theme`), the latest one wins, until
  the loop hands it to its host, as `reload` is kept (`Editor/Loop.lean`,
  "A theme switch from a command").
- **A window's wanted column is set by one request**, `setWanted`, with
  the column, a goal of the display's or the line's end, and the offset it
  is kept at, or with none (`Editor/State.lean`, "The wanted column"). The
  handler stores the column as it is given. It is refused with a
  `LayoutRefusal`, `noSuchWindow`, for a view with no window.
- **A window's jump list and the marks are set by three requests**
  (`Editor/State.lean`, "The jump list and marks"): `setJumps` replaces a
  window's jump list and previous-context mark whole, refused
  `noSuchWindow`, and `noSuchBuffer` or `markersOfAnotherText` for a place
  held where no buffer holds it; `setLocalMark` sets or unsets a buffer's
  mark, refused `noSuchBuffer` and `markerOfAnotherText`; and
  `setGlobalMark` sets or unsets a global mark, refused `noSuchBuffer` and
  `markerOfAnotherText` for a held place. Each keeps what it is given: the
  rules of recording and moving are `Editor/Jumps.lean`'s, and the markers
  a request drops are the loop's to give up (`Editor/Loop.lean`, "What a
  finished command gave up").
- **A file is attached by one request, and a save is two.** `attachFile`
  has a buffer hold a file a load answered. `beginSave` records a save in
  flight, with the snapshot it writes, which the command took first, and
  `endSave` ends it with what the save answered: the stamp and the saved
  mark are set by that one request (`Editor/State.lean`, "A buffer's
  file"). The handler releases no snapshot: the loop does, once the
  command that ended the save has run to its end. What a check of the
  file found is recorded by one request, `markChanged`, and that the user
  was told of it by another, `tellChanged`, so the command a check finishes
  with is made of state requests alone and cannot be interrupted.
- **A register is set by one request**, `setRegister`, with its name
  (`Editor/State.lean`, "Registers"). It is never refused: a name is any
  string, and which names mean something is the asking command's rule. A
  command reads a register with a read of the state
  (`EditorState.register?`).
- **The last search is set by one request**, `setLastSearch`
  (`Editor/State.lean`, "The last search"), as the last find is.
- **The last character find is set by one request**, `setLastFind`
  (`Editor/State.lean`, "The last find"). It is never refused. A command
  reads it with a read of the state (`EditorState.lastFind`).
- **The scroll margin is set by one request**, `setScrollMargin`, with a
  number of rows (`Editor/State.lean`, "The scroll margin"). It is never
  refused: any number is taken. A command reads the margin with a read of
  the state (`EditorState.scrollMargin`).
- **Workspaces are changed by five requests** (`Editor/State.lean`,
  "Workspaces"): `recordWorkspace` takes in what the finder answered for a
  directory, and is never refused; `registerWorkspace` makes a workspace
  that is not on this machine, and refuses `local`; `setWorkspaceValue` and
  `setProjectValue` set a value in a store, and refuse `noSuchWorkspace`
  and `noSuchProject` (`WorkspaceRefusal`); `setUnscopedValue` sets a
  value in the store of the buffers outside any workspace, and is never
  refused. A command reads them with a
  read of the state (`EditorState.workspaceOf?`, `workspaces`).
- **A buffer's language is recorded by name**, `setLanguage`, as its major
  mode is: any name is taken, and refused `noSuchBuffer` alone.
- **Config's grammars are answered by two requests**: `setGrammars`
  replaces the answers the registration of config's declared grammars
  brought back (`Editor/State.lean`, "Config's grammars"), never refused;
  and `rehighlight`, with grammar names, which the loop answers by
  highlighting again each buffer whose language names one of them
  (`Editor/Command/Dispatch.lean`), and which this handler answers with
  the state unchanged. The core's `register-grammars` job's command makes
  both (`Editor/Language/Grammar/Register.lean`).
- **A session restore puts back what it read by four requests**
  (`Editor/Restore/Run.lean`), each plain data: `restoreFrame`, the
  frame's tabs and every window of them, refused `promptOpen` and
  `malformed` (`Editor/State.lean`, "Tabs"); `restoreWorkspaces`, a table
  whose cells the restore's command already met with their codecs, which it
  asked the registry for (`RegistryRequest.storeCodec`), never refused;
  `markRestored`, a buffer made or reopened, refused `noSuchBuffer`; and
  `restoreCells`, the declared stores' cells, kept in the outbox
  (`EditorState.Outbox.restoredCells`) for the host that holds the cells.
- **A restart hands its plan over by `handOver`**, kept in the outbox
  (`EditorState.Outbox.handOver`) for the host to exec once its session and
  record are written (`Editor/Restore/Restart.lean`).

## Where an addition goes

| Addition | Where |
|---|---|
| A question about the state | A pure function over `EditorState` (`Editor/State.lean`); nothing here |
| A new way to change the state | An operation in `Editor/State.lean`, a constructor here with its case in `Reply` and in `handle`, and the operation a command calls in `Editor/Api.lean` |
| A change of the state the registry gates (a name it must know) | The same, and its case in `Program.dispatched` (`Editor/Command/Dispatch.lean`) |
| Something a command asks the loop to hand its host | A field of `EditorState.Outbox` (`Editor/State/Outbox.lean`, "Where a new entry goes"), a constructor here whose case sets it, and the function a command calls in `Editor/Api.lean` |
| A question to the registry or config, a new config setting a command reads among them | Not here: a constructor of `RegistryRequest` (`Editor/Command/Registry.lean`, "Where an addition goes") |
| A way to end the command, or to run something registered inside it | Not here: a constructor of `ControlRequest` (`Editor/Command/Control.lean`, "Where an addition goes") |

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
  /-- Give the buffer `id` the name `name`. -/
  | renameBuffer (id : BufferId) (name : String)
  /-- Make `history` the undo tree of the buffer `id`. -/
  | setHistory (id : BufferId) (history : UndoTree)
  /-- Add an excerpt buffer called `name` over the excerpt text `text`, whose
  history is `history` and whose excerpts are `entries`. -/
  |
  addExcerptBuffer (name : String) (text : TextId) (history : UndoTree)
    (entries : Array Buffer.ExcerptEntry := #[])
  /-- Make `excerpts` what the excerpt buffer `id` keeps of its edits. -/
  | setExcerptHistory (id : BufferId) (excerpts : Buffer.Excerpts)
  /-- Have the buffer `id` keep `value` under `name`. -/
  | setValue (id : BufferId) (name : String) (value : Value)
  /-- Make the mode called `name` the major mode of the buffer `view`
  shows. -/
  | setMajorMode (view : ViewId) (name : String)
  /-- Make the mode called `name` the major mode of the buffer `id`, which
  no window need show. -/
  | setBufferMajorMode (id : BufferId) (name : String)
  /-- Add the minor mode called `name` to the buffer `id`. -/
  | addMinorMode (id : BufferId) (name : String)
  /-- Remove the minor mode called `name` from the buffer `id`. -/
  | removeMinorMode (id : BufferId) (name : String)
  /-- Split the window `view`: a new window on its buffer, with `scroll` and
  `selection` as its markers, put in the frame's list as `placement` says
  under manual splits and right after it under the other layouts. -/
  | split (view : ViewId) (scroll selection : MarkerId) (placement : Placement := {})
  /-- Make `change` on the window `view` (`Arrange`): a reorder of the list or
  a change of the layout's parameters. -/
  | arrange (view : ViewId) (change : Arrange)
  /-- Open a new window on the buffer `buffer`, with `scroll` and `selection`
  as its markers, at `spot`: after the last of the tiled list, or docked at
  an edge. -/
  | openWindow (buffer : BufferId) (scroll selection : MarkerId) (spot : WindowSpot)
  /-- Make `change` on the frame's tabs (`TabChange`): select, close, rename
  or move one. -/
  | tab (change : TabChange)
  /-- Remove the window `view`. -/
  | removeWindow (view : ViewId)
  /-- Focus the window `view`. -/
  | focus (view : ViewId)
  /-- Have the window `view` show the buffer `buffer`, with `scroll` and
  `selection` as its markers. -/
  | «show» (view : ViewId) (buffer : BufferId) (scroll selection : MarkerId)
  /-- Put `text` in the echo area. -/
  | message (text : String)
  /-- Start the job registered under `name`, with `arguments`, under the key
  `key` if it has one. -/
  | startJob (name : String) (arguments : List Argument) (key : Option String := none)
  /-- Cancel the job of the key `key`, if there is one, once the asking
  command has run to its end. -/
  | cancelJob (key : String)
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
  /-- Record what a check of the buffer `id`'s file found, if its stamp is
  still `stamp`: the file's stamp now, or `none` for one that is gone, and
  whether the user was told (`EditorState.markChanged`). -/
  | markChanged (id : BufferId) (stamp : File.Stamp) (found : Option File.Stamp) (told : Bool)
  /-- Mark the change on disk of the buffer `id`'s file as told. -/
  | tellChanged (id : BufferId)
  /-- Make the buffer `id` read-only to editing commands, or not. -/
  | setReadOnly (id : BufferId) (on : Bool)
  /-- Set the spans of the buffer `id`, in place of those it had. -/
  | setSpans (id : BufferId) (spans : Array Decoration)
  /-- Set the align-to stops of the buffer `id`, in place of those it had. -/
  | setStops (id : BufferId) (stops : Array AlignStop)
  /-- Set the wrap indents of the buffer `id`, in place of those it had. -/
  | setIndents (id : BufferId) (indents : Array WrapIndent)
  /-- Set the links of the buffer `id`, in place of those it had. -/
  | setLinks (id : BufferId) (links : Array Link)
  /-- Declare the foldable ranges of the buffer `id`, keeping the state of
  each whose key survives. -/
  | setFolds (id : BufferId) (declared : Array Foldable)
  /-- Write the parts of the buffer `id` from the rich-text description
  `rich`, from the byte `start` on, by the prefix rule. -/
  | setRichText (id : BufferId) (rich : RichText) (start : Nat)
  /-- Append the parts of the rich-text description `tail`, moved `offset`
  bytes on, to those of the buffer `id`. -/
  | appendRichText (id : BufferId) (tail : RichText) (offset : Nat)
  /-- Set the rendered Markdown document of the buffer `id`, or take it
  away. -/
  | setMarkdown (id : BufferId) (doc : Option Markdown.Doc)
  /-- Fold or unfold the foldable range of the buffer `id` keyed `key`. -/
  | setFolded (id : BufferId) (key : String) (folded : Bool)
  /-- Set the gutter of the buffer `id`, or take it away. -/
  | setGutter (id : BufferId) (gutter : Option Buffer.Gutter)
  /-- Tell the version-control gutter's state what arrived. -/
  | gutter (change : GutterChange)
  /-- Set what the session's reconciler keeps (`Editor/Restore.lean`), in
  place of what it kept. -/
  | setRestore (kept : Restore.Kept)
  /-- Put back the frame a session restore recorded: `record`'s tabs, its
  views this run's ids, with `windows`, every window of them, a float
  anchored at a position held by the marker `anchors` gives its view, and
  the next view's id at least `next`. -/
  |
  restoreFrame (record : Restore.Frame.Record) (windows : Array Window)
    (anchors : Array (Nat × MarkerId)) (next : Nat)
  /-- Take in `table`, a workspace table a session restore made, its cells
  already met. -/
  | restoreWorkspaces (table : Workspace.Table)
  /-- Mark the buffer `id` as made or reopened by a session restore. -/
  | markRestored (id : BufferId)
  /-- Hand the host `cells`, the declared stores' cells a session restore
  read. -/
  | restoreCells (cells : Array KeptCell)
  /-- Hand the host `plan`, a restart whose session and record are written,
  to exec (`EditorState.Outbox.handOver`). -/
  | handOver (plan : Restart.Plan)
  /-- Choose auto-reload on or off, for as long as the editor runs. -/
  | setAutoReload (on : Bool)
  /-- Stop following the buffer `id` for auto-reload: its follow job ended. -/
  | unfollow (id : BufferId)
  /-- Mark the following of the buffer `id` as refused: its watch could not
  be made. -/
  | refuseFollow (id : BufferId)
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
  /-- Replace the open prompt's candidates, the passed ones and its category
  with what its sources answered, `collected`. -/
  | setCandidates (collected : Completion.Collected)
  /-- Move the open prompt's choice by `step` through its listing. -/
  | chooseCandidate (step : Candidates.Step)
  /-- Take `batch`, a batch of the job of the asking source `index` of the
  prompt open in `view`, at `generation`; dropped otherwise. -/
  | addCandidates (view : ViewId) (index generation : Nat) (batch : Array Completion.Candidate)
  /-- The job of the asking source `index` of the prompt open in `view`, at
  `generation`, has ended. -/
  | sourceAnswered (view : ViewId) (index generation : Nat)
  /-- The job of the asking source `index` of the prompt open in `view`, at
  `generation`, failed with `message`. -/
  | sourceFailed (view : ViewId) (index generation : Nat) (message : String)
  /-- List `listed`, which a match job made for `pattern` at `revision`, in
  the prompt open in `view`, if that is the match in flight. -/
  |
  listMatched (view : ViewId) (pattern : String) (revision : Nat) (listed : Array Completion.Listed)
  /-- The match in flight for `pattern` at `revision` in the prompt open in
  `view` could not list, for `message`. -/
  | matchFailed (view : ViewId) (pattern : String) (revision : Nat) (message : String)
  /-- Open a session at point, `session`, with what its sources answered,
  `collected`. -/
  | openAtPoint (session : AtPointSession) (collected : Completion.Collected)
  /-- Close the open session at point, and hand it back. -/
  | closeAtPoint
  /-- Move the open session's choice by `step` through its listing. -/
  | chooseAtPoint (step : Candidates.Step)
  /-- Record what a preview left in the open session's region, and whether
  a preview was made. -/
  | retypeAtPoint (shown : String) (previewed : Bool)
  /-- Record an edit the user made in the open session's region, which now
  holds `text`. -/
  | retakeAtPoint (text : String)
  /-- Record that this command typed `text` in `view` in place of typed
  text, for the input scheme. -/
  | retype (view : ViewId) (text : String)
  /-- Have the window `view` keep `wanted` as its wanted column, or none. -/
  | setWanted (view : ViewId) (wanted : Option Window.Wanted)
  /-- Have the window `view` keep `jumps` as its jump list and
  previous-context mark. -/
  | setJumps (view : ViewId) (jumps : Jumps)
  /-- Have the buffer `id` hold its mark `char` by `marker`, or no longer
  hold it for none. -/
  | setLocalMark (id : BufferId) (char : Char) (marker : Option MarkerId)
  /-- Have the buffer `id` keep `history` beside its marks, in place of what
  it kept. -/
  | setMarkHistory (id : BufferId) (history : Marks.History)
  /-- Set the global mark `char` at `place`, or unset it for none. -/
  | setGlobalMark (char : Char) (place : Option Place)
  /-- Have the theme called `name` loaded once this command has run to its
  end. -/
  | loadTheme (name : String)
  /-- Have `invocation` run after this command, as a step of its own. -/
  | invoke (invocation : Invocation)
  /-- Ask the editor to quit. -/
  | quit
  /-- Ask for the config to be reloaded. -/
  | reload
  /-- Keep `register` under `name`, in place of the register the name
  had. -/
  | setRegister (name : String) (register : Register)
  /-- Keep `find` as the last character find. -/
  | setLastFind (find : Find)
  /-- Keep `search` as the last search. -/
  | setLastSearch (search : Search)
  /-- Keep `rows` rows between every view's cursor's row and the first and
  the last row it shows. -/
  | setScrollMargin (rows : Nat)
  /-- Take in what the finder answered for `directory` under the config
  generation `generation`: the workspace, added or with its branch updated,
  and the directory's cached answer. -/
  |
  recordWorkspace (directory : System.FilePath) (generation : Nat) (found : Option Workspace.Found)
  /-- Register a workspace at `location`, not on this machine, of the
  project of `remote`, with `branch` checked out if it is given. -/
  | registerWorkspace (location : Location) (remote : String) (branch : Option String)
  /-- Have the workspace at `location` keep `value` under `name`. -/
  | setWorkspaceValue (location : Location) (name : String) (value : Value)
  /-- Have the project of `identity` keep `value` under `name`. -/
  | setProjectValue (identity : Project.Identity) (name : String) (value : Value)
  /-- Have the unscoped store, of the buffers outside any workspace, keep
  `value` under `name`. -/
  | setUnscopedValue (name : String) (value : Value)
  /-- Record `name` as the language of the buffer `id`, or that it has
  none. -/
  | setLanguage (id : BufferId) (name : Option String)
  /-- Replace the recorded answers of config's grammars with `answers`. -/
  | setGrammars (answers : Language.Grammar.Answers)
  /-- Highlight again each buffer whose language's tree names one of
  `grammars`, as its major mode now says: answered by the loop, which
  knows the registry. -/
  | rehighlight (grammars : Array String)

/-- The type of the reply to each request. -/
abbrev StateRequest.Reply : StateRequest → Type
  | .read => EditorState
  | .addBuffer .. => Except BufferRefusal BufferId
  | .removeBuffer _ => Except BufferRefusal Unit
  | .renameBuffer .. => Except BufferRefusal Unit
  | .setHistory .. => Except BufferRefusal Unit
  | .addExcerptBuffer .. => Except BufferRefusal BufferId
  | .setExcerptHistory .. => Except BufferRefusal Unit
  | .setValue .. => Except BufferRefusal Unit
  | .setMajorMode .. => Except ModeRefusal Bool
  | .setBufferMajorMode .. => Except ModeRefusal Bool
  | .addMinorMode .. => Except BufferRefusal Unit
  | .removeMinorMode .. => Except BufferRefusal Unit
  | .split .. => Except LayoutRefusal ViewId
  | .arrange .. => Except LayoutRefusal Unit
  | .openWindow .. => Except LayoutRefusal ViewId
  | .tab _ => Except LayoutRefusal Unit
  | .removeWindow _ => Except LayoutRefusal Window
  | .focus _ => Except LayoutRefusal Unit
  | .show .. => Except LayoutRefusal Unit
  | .message _ => Unit
  | .startJob .. => Except JobRefusal Unit
  | .cancelJob _ => Unit
  | .attachFile .. => Except BufferRefusal Unit
  | .beginSave .. => Except BufferRefusal Unit
  | .endSave .. => Except BufferRefusal Unit
  | .markChanged .. => Except BufferRefusal Unit
  | .tellChanged _ => Except BufferRefusal Unit
  | .setReadOnly .. => Except BufferRefusal Unit
  | .setSpans .. => Except BufferRefusal Unit
  | .setStops .. => Except BufferRefusal Unit
  | .setIndents .. => Except BufferRefusal Unit
  | .setLinks .. => Except BufferRefusal Unit
  | .setFolds .. => Except BufferRefusal Unit
  | .setRichText .. => Except BufferRefusal Unit
  | .appendRichText .. => Except BufferRefusal Unit
  | .setMarkdown .. => Except BufferRefusal Unit
  | .setFolded .. => Except BufferRefusal Unit
  | .setGutter .. => Except BufferRefusal Unit
  | .gutter _ => Unit
  | .setRestore _ => Unit
  | .restoreFrame .. => Except LayoutRefusal Unit
  | .restoreWorkspaces _ => Unit
  | .markRestored _ => Except BufferRefusal Unit
  | .restoreCells _ => Unit
  | .handOver _ => Unit
  | .setAutoReload _ => Unit
  | .unfollow _ => Unit
  | .refuseFollow _ => Unit
  | .openPrompt .. => Except PromptRefusal ViewId
  | .closePrompt _ => Except PromptRefusal Unit
  | .setCandidates _ => Except PromptRefusal Unit
  | .chooseCandidate _ => Except PromptRefusal Unit
  | .addCandidates .. => Bool
  | .sourceAnswered .. => Unit
  | .sourceFailed .. => Unit
  | .listMatched .. => Unit
  | .matchFailed .. => Unit
  | .openAtPoint .. => Except AtPointRefusal Unit
  | .closeAtPoint => Except AtPointRefusal AtPointSession
  | .chooseAtPoint _ => Except AtPointRefusal Unit
  | .retypeAtPoint .. => Except AtPointRefusal Unit
  | .retakeAtPoint _ => Except AtPointRefusal Unit
  | .retype .. => Unit
  | .setWanted .. => Except LayoutRefusal Unit
  | .setJumps .. => Except LayoutRefusal Unit
  | .setLocalMark .. => Except BufferRefusal Unit
  | .setMarkHistory .. => Except BufferRefusal Unit
  | .setGlobalMark .. => Except BufferRefusal Unit
  | .loadTheme _ => Except ThemeRefusal Unit
  | .invoke _ => Unit
  | .quit => Unit
  | .reload => Unit
  | .setRegister .. => Unit
  | .setLastFind _ => Unit
  | .setLastSearch _ => Unit
  | .setScrollMargin _ => Unit
  | .recordWorkspace .. => Unit
  | .registerWorkspace .. => Except WorkspaceRefusal Unit
  | .setWorkspaceValue .. => Except WorkspaceRefusal Unit
  | .setProjectValue .. => Except WorkspaceRefusal Unit
  | .setUnscopedValue .. => Unit
  | .setLanguage .. => Except BufferRefusal Unit
  | .setGrammars _ => Unit
  | .rehighlight _ => Unit

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

/-- Makes the mode called `name` the major mode of the buffer `id`, and
says whether it became the major mode (`EditorState.setMajorMode`). Any
name is taken. Refused, with the state unchanged, with `noSuchBuffer` for
a buffer there is none of. -/
def setMajorModeOfBuffer (id : BufferId) (name : String) (state : EditorState) :
    Except ModeRefusal Bool × EditorState :=
  match state.setMajorMode id name with
  | (.ok became, next) => (.ok became, next)
  | (.error _, _) => (.error (.noSuchBuffer id), state)

/-- The reply to `request` from `state`, and the state after it: each
request is its operation of `Editor/State.lean`. A refused request leaves
the state as it was. -/
def handle : (request : StateRequest) → EditorState → request.Reply × EditorState
  | .read, state => (state, state)
  | .addBuffer name text history, state => state.addBuffer name text history
  | .removeBuffer id, state => state.removeBuffer id
  | .renameBuffer id name, state => state.renameBuffer id name
  | .setHistory id history, state => state.setHistory id history
  | .addExcerptBuffer name text history entries, state =>
    state.addExcerptBuffer name text history entries
  | .setExcerptHistory id excerpts, state => state.setExcerptHistory id excerpts
  | .setValue id name value, state => state.setValue id name value
  | .setMajorMode view name, state => state.setMajorModeOf view name
  | .setBufferMajorMode id name, state => state.setMajorModeOfBuffer id name
  | .addMinorMode id name, state => state.addMinorMode id name
  | .removeMinorMode id name, state => state.removeMinorMode id name
  | .split view scroll selection placement, state =>
    state.splitWindow view scroll selection placement
  | .arrange view change, state => state.arrange view change
  | .openWindow buffer scroll selection spot, state => state.openWindow buffer scroll selection spot
  | .tab change, state => state.changeTab change
  | .removeWindow view, state => state.removeWindow view
  | .focus view, state => state.focusWindow view
  | .show view buffer scroll selection, state => state.showBuffer view buffer scroll selection
  | .message text, state => ((), { state with echo := text })
  | .startJob name arguments key, state =>
    (.ok (), { state with outbox.starts := state.outbox.starts.push { name, arguments, key } })
  | .cancelJob key, state => ((), { state with outbox.cancels := state.outbox.cancels.push key })
  | .attachFile id path stamp ending, state => state.attachFile id path stamp ending
  | .beginSave id snapshot saved, state => state.beginSave id snapshot saved
  | .endSave id snapshot stamp, state => state.endSave id snapshot stamp
  | .markChanged id stamp found told, state => state.markChanged id stamp found told
  | .tellChanged id, state => state.tellChanged id
  | .setReadOnly id on, state => state.setReadOnly id on
  | .setSpans id spans, state => state.setSpans id spans
  | .setStops id stops, state => state.setStops id stops
  | .setIndents id indents, state => state.setIndents id indents
  | .setLinks id links, state => state.setLinks id links
  | .setFolds id declared, state => state.setFolds id declared
  | .setRichText id rich start, state => state.setRichText id rich start
  | .appendRichText id tail offset, state => state.appendRichText id tail offset
  | .setMarkdown id doc, state => state.setMarkdown id doc
  | .setFolded id key folded, state => state.setFolded id key folded
  | .setGutter id gutter, state => state.setGutter id gutter
  | .gutter change, state => ((), state.changeGutter change)
  | .setRestore kept, state => ((), { state with restore := kept })
  | .restoreFrame record windows anchors next, state =>
    state.restoreFrame record windows anchors next
  | .restoreWorkspaces table, state => ((), state.restoreWorkspaces table)
  | .markRestored id, state => state.markRestored id
  | .restoreCells cells, state =>
    ((), { state with outbox.restoredCells := state.outbox.restoredCells ++ cells })
  | .handOver plan, state => ((), { state with outbox.handOver := some plan })
  | .setAutoReload on, state => ((), { state with autoReload := some on })
  | .unfollow id, state => ((), { state with following := state.following.filter (·.buffer != id) })
  | .refuseFollow id, state =>
    ((),
      { state with
        following :=
          state.following.map fun entry =>
            if entry.buffer == id then { entry with refused := true } else entry })
  | .openPrompt label continuation text history scroll selection, state =>
    state.openPrompt label continuation text history scroll selection
  | .closePrompt answer, state => state.closePrompt answer
  | .setCandidates collected, state => state.setCandidates collected
  | .chooseCandidate step, state => state.chooseCandidate step
  | .addCandidates view index generation batch, state =>
    state.addCandidates view index generation batch
  | .sourceAnswered view index generation, state => ((), state.sourceAnswered view index generation)
  | .sourceFailed view index generation message, state =>
    ((), state.sourceFailed view index generation message)
  | .listMatched view pattern revision listed, state =>
    ((), state.listMatched view pattern revision listed)
  | .matchFailed view pattern revision message, state =>
    ((), state.matchFailed view pattern revision message)
  | .openAtPoint session collected, state => state.openAtPoint session collected
  | .closeAtPoint, state => state.closeAtPoint
  | .chooseAtPoint step, state => state.chooseAtPoint step
  | .retypeAtPoint shown previewed, state => state.retypeAtPoint shown previewed
  | .retakeAtPoint text, state => state.retakeAtPoint text
  | .retype view text, state => ((), state.retype view text)
  | .setWanted view wanted, state => state.setWanted view wanted
  | .setJumps view jumps, state => state.setJumps view jumps
  | .setLocalMark id char marker, state => state.setLocalMark id char marker
  | .setMarkHistory id history, state => state.setMarkHistory id history
  | .setGlobalMark char place, state => state.setGlobalMark char place
  | .loadTheme name, state => (.ok (), { state with outbox.theme := some name })
  | .invoke invocation, state =>
    ((), { state with outbox.answered := state.outbox.answered.push invocation })
  | .quit, state => ((), { state with quitting := true })
  | .reload, state => ((), { state with outbox.reload := true })
  | .setRegister name register, state => ((), state.setRegister name register)
  | .setLastFind find, state => ((), state.setLastFind find)
  | .setLastSearch search, state => ((), state.setLastSearch search)
  | .setScrollMargin rows, state => ((), state.setScrollMargin rows)
  | .recordWorkspace directory generation found, state =>
    ((), state.recordWorkspace directory generation found)
  | .registerWorkspace location remote branch, state =>
    state.registerWorkspace location remote branch
  | .setWorkspaceValue location name value, state => state.setWorkspaceValue location name value
  | .setProjectValue identity name value, state => state.setProjectValue identity name value
  | .setUnscopedValue name value, state => ((), state.setUnscopedValue name value)
  | .setLanguage id name, state => state.setLanguage id name
  | .setGrammars answers, state => ((), state.setGrammars answers)
  | .rehighlight _, state => ((), state)

end EditorState

end Editor
