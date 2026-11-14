import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Config.Stores
import Editor.Event
import Editor.InputScheme
import Editor.Key.Notation
import Editor.State

/-!
# The command loop

Events go in, the state changes, a scene comes out. `Loop.step` takes the
loop (the editor state, what the last scene showed and the input scheme's
state) and one event, handles it (`Loop.handle`), and publishes a scene of
the state after it (`Loop.publish`). It is pure: a command (`EditorM`) over
the editor's composite port, so the same loop runs on the models in
`model-test` and against the Rust library in the headless host, which pulls
the events and hands each to it.

## The scheme

A loop runs one input scheme (`Editor/InputScheme.lean`), which it is given
when it starts and keeps for its life: `Loop scheme`
(`docs/design/keymaps-and-modes.md`, "The loop runs one scheme"). It holds
the scheme's state. A step is also handed `Loop.Keys`: the active keymaps
of each view, as a function of the editor state and the view, which the
caller makes for each step. The loop applies it to its own state
(`Loop.key`): the active keymaps depend on the buffers' modes, which only
the loop's state holds, so a mode set by one key holds from the next.

- **Which keys are stepped** (`Loop.stepped?`). A key press, a repeat among
  them, whose key is not a modifier by itself (`Key.isModifier`). A release
  is not stepped, and neither is the press of Shift a window reports before
  a shifted key: stepped, it would be an unbound key and would reset the
  sequence begun.
- **The key is for the focused view** (`Loop.key`): the frame's. The
  event's text is not read: a scheme asks `Key.printed?`.
- **The scene shows the pending keys** (`Loop.pending`): what the scheme
  reports as pending, as a key string. It is empty once a sequence
  completes and after a key that goes on with no binding, since the scheme
  then reports none.
- **The scheme is told of a view that is closed** (`Loop.forgetViews`,
  `InputScheme.closeView`). After a command that ran to its end, each view
  the state before it had a window of and the state it left has none of is
  told to both states of the scheme the loop keeps. A command that did not
  run to its end closed nothing, and the scheme is told nothing.

## Running an invocation

When a key completes a sequence the scheme yields an invocation, a
command's name and plain arguments, and the loop runs it (`Loop.run`):

1. **The echo area is cleared.** It is what the last command left: a key
   that yields nothing leaves it as it was.
2. **The command is looked up** by its name (`Loop.Keys.command?`), in the
   registry as it is at this step. A name no command is registered under is
   said in the echo area: `<name>: no such command`.
3. **It is run with a `Call`** (`Editor/Command/Call.lean`): the focused
   window and its buffer, the invocation's arguments, which hold the count
   where the scheme laid it out, and the keys that yielded it, which are
   what the scheme reported as pending before the last key, then that key's
   chord.
4. **Its state requests are answered from the loop's state**
   (`EditorM.dispatched`, `Editor/Command/Dispatch.lean`), each from the
   state the one before left, starting with the echo area cleared. When the
   command runs to its end, the state it left is the loop's. When it does
   not, the loop's state is the one from before the command ("Rollback").
5. **A refusal is said in the echo area**, `<name>: refused: ` and the
   refusal (`TextError.describe`), and the editor keeps running: the step
   is not refused, and the next key is handled. What the command did before
   it was refused is rolled back ("Rollback").
6. **What the command asked to be written** (a command over a store) is
   handed back with the step (`Loop.Stepped.write`), for whoever holds the
   cells.
7. **A slow command is logged.** The loop reads the watch port's clock just
   before the command and just after it, however it ended. When it took
   longer than the threshold the step was handed (`Loop.Keys.slowAfter`,
   `Loop.slowAfter` by default), the step hands back one entry
   (`Loop.Stepped.log`): `slow command: <name> took <n> ms`. The loop
   writes no log itself: the host does, with what the step hands back.
8. **The jobs the command asked for are handed back** with the step
   (`Loop.Stepped.starts`), for the host to start ("Jobs from commands").
9. **The step says how the command ended** (`Loop.Stepped.ended`, a
   `Loop.Ending`), for a host that prints it.

A call into a config command is not guarded against the interpreter: an
exception thrown by interpreted code ends the process
(`docs/design/lean-runtime.md`, "An exception from the interpreter ends the
process").

## Every command goes through the loop

A key is one of three ways a command comes to run, and the loop runs all
three the same way (`Loop.dispatch`): the command is dispatched from the
loop's state, so it is guarded and its state requests are answered; it is
rolled back if it does not run to its end; what it gave up is given up, its
jobs are handed back, and a scene is published after it.

- **A key's invocation** (`Loop.key`, above).
- **A command run by its name** (`Loop.runNamed`), for a host's driver. It
  is an invocation with no arguments and no keys: the echo area is cleared,
  the name is looked up, and the command is called with the focused window.
  The scheme's states are left as they are but for a view the command
  closed: no key was typed.
- **A command the loop is handed** (`Loop.deliver`), with a label for it: a
  finished job's command, which is no invocation. The echo area is **not**
  cleared, because a result that arrives in the background should not wipe
  what the user is reading; a command that says nothing leaves it. When the
  command does not run to its end the echo area reads `<label>: refused: `
  and the refusal, or `<label>: interrupted`, as an invocation's does under
  its name.

## Jobs from commands

A command starts a job by the name it is registered under, with plain
arguments (`startJob`, `Editor/Api.lean`). A request holds no job: a job is
a program that ends in a program over the editor's port, so a request of
that port cannot carry one (`docs/design/lean-runtime.md`, "A request that
carries a program over its own port"). The loop starts none either: it
holds no job table.

- **The name is checked when the command asks.** The request is refused,
  as a value the command sees, with `noSuchJob` for a name the step was not
  told a job is registered under (`Loop.Registered.jobs`).
- **A start is kept in the state** until the command ends
  (`EditorState.starts`). After a command that ran to its end the loop
  takes the starts out of the state and hands them back with the step, in
  the order they were asked for. A command that did not run to its end
  starts no job: its starts go with the state it left.
- **The host starts each**, for whoever registered it, and when the job has
  ended hands the loop the command it finished with (`Loop.deliver`). The
  result comes back through the host's queue, so events that arrived before
  it are handled before it: a job never interleaves with a command.
- **On the models** `Loop.Driver` (`Editor/Loop/Driver.lean`) is that host:
  it runs each job a step hands back on the job model and keeps what it
  ended with until a test says the job is finished.

Pinned by `ModelTest.driverChecks`.

**The scheme after a command that failed.** The loop keeps two states of
the scheme: the one after the last key (`Loop.input`), and the last one at
rest (`Loop.atRest`), in which nothing was pending. When an invocation does
not run to its end, the scheme goes back to its state at rest: it is as it
was before the first key of the sequence, so a key that entered a state of
the scheme's has not entered it, and no prefix is left pending. When the
invocation runs to its end, or a key yields nothing and leaves nothing
pending, the state at rest becomes the state after the key.

## Rollback

A command that does not run to its end leaves the texts and the windows as
they were before it (`docs/design/concurrency.md`, "Foreground: commands").

- **Before a command** the loop keeps (`Loop.keep`), for each buffer, the
  state of its undo tree once told the revision its text is at, and, for
  each window, its selection marker and its scroll marker as read. A buffer
  whose text refuses, and a marker that does, is not kept.
- **After a command that did not run to its end** (`Loop.Kept.restore`)
  each kept buffer's tree is told the revision and reverted to the kept
  state (`UndoTree.revertTo`), with the user's origin, and the tree it
  returns is the buffer's. Then each kept marker is placed back. The editor
  state is the one before the command: the windows, the buffers, the echo
  and everything else a state request of the command changed are as they
  were.
- **The tree that is reverted is the one the command left**, when the kept
  state is a state of its open group. A command can move in a buffer's
  history and record the moved tree (`StateRequest.setHistory`). The tree
  from before the command does not know of the move, and the move dropped
  the inverses that tree's edges cross: reverting it would be refused, or
  would leave a tree out of step with the store. So each kept buffer is
  reverted from the tree it has in the state the command left, when that
  state still has the buffer, over the same text, and from the tree it had
  before otherwise. The buffer of the state the loop keeps gets the tree
  that comes back.
- **A boundary the command set is taken back with its edits.** A command
  can close the open group (`BufferId.closeGroup`). The kept state is then
  no state of the open group of the tree the command left, though nothing
  moved. The tree from before the command knows of no boundary set since:
  told the revision, its open group is everything the command did, so it
  is the one reverted, by one inverse, and the buffer's. The steps the
  command closed go with the tree the command left: the history has no
  step for the command and nothing to redo, and the markers are placed
  back. That tree is reverted only when the tree the command left still
  has each of its edges as it has them (`UndoTree.keepsEdgesOf`): a move
  over one of them dropped the inverse the edge held, and the tree from
  before is then out of step with the store. When the command also moved
  over a step it had closed itself, the store refuses the revert, with
  nothing changed, since that move dropped inverses of the run, and the
  command is one that moved in the history (below).
- **A mark of the saved state is taken back.** A command can mark a state
  of a buffer's history as saved: by recording a tree it marked
  (`StateRequest.setHistory`), or by ending a save
  (`StateRequest.endSave`). The tree the command left carries that mark,
  and it may be the tree that is reverted. So the tree that comes back is
  given the saved state of the tree from before the command: a buffer that
  was modified is modified again, beside the stamp and the save in flight
  the state from before has. Without this a failed command that ended a
  save would leave a buffer that says "not modified" beside a stamp from
  before the save.
- **Markers are placed back, and not left to the inverse.** A marker moves
  with every transaction: a deletion and its inverse do not return a marker
  inside the deleted range to where it was, and a command can place a
  marker with no edit. A revert hands back only the selection a transaction
  carried.
- **No group of its own.** The kept state may be a point inside an open
  group, and the revert goes back to it, whether or not the command set a
  boundary: the edits from before the command are then still pending. The
  loop closes each group after every event (`Loop.publish`), so today the
  kept state is a node's, and the revert leaves nothing pending, no node
  and nothing to redo.
- **What is not undone**: the texts, snapshots and markers the command
  made, and the scenes it published. The step publishes the true scene
  right after.
- **A rollback that is refused is said, and the rest is still done.** A
  command that released a buffer's text, gave up a window's marker or
  dropped the inverses of its own edits cannot be rolled back. The echo
  area then ends `; not rolled back: ` and the first refusal.
- **A move in the history is not taken back.** When the kept state is no
  longer a state of the open group, and the tree from before the command
  cannot be reverted to it, the history moved since it was kept. The loop
  then reverts the group that is open (`UndoTree.revert`), which takes
  back the edits made since the move and leaves the text at the node the
  move reached. The echo area ends `; the command moved in the history`,
  and the markers of that text are left where the store moved them. It is
  pinned on a command that moves and records the move, on one that sets a
  boundary and moves over the step it closed, and on a state whose history
  was moved by hand.

An event's own handler, such as the commit's (`Loop.insert`), is one
transaction, which the store accepts whole or refuses whole, and is not
routed through this.

## What a finished command gave up

A state request that closes a window, removes a buffer or ends a save
changes the editor state and nothing in the text store: the window's
markers, the buffer's text and the save's snapshot are still held. The loop
gives them up, once the command has run to its end (`Loop.gaveUp`), by
comparing the state from before the command with the state it left:

- **A window's markers.** Each marker of a window of the state before that
  no window of the state after uses is given up (`TextId.unmark`): the
  window was closed, or shown another buffer.
- **A buffer's text.** The text of each buffer of the state before whose
  slot is empty in the state after is released, unless a buffer that is
  left is over the same text. The markers go first, so a window closed with
  its buffer gives up its markers on a text that is still there.
- **A save's snapshot.** The snapshot of each save in flight in the state
  before (`Buffer.File.saving`, `Editor/State.lean`) that is not in flight
  in the state after is released (`Loop.savesInFlight`): the save's result
  was delivered and its command ended the save, whether the save wrote the
  file or was refused, or the buffer was removed while its save ran. The
  command that takes the snapshot and begins the save releases nothing: the
  job reads the snapshot.
- **Not before the command has ended.** A command that is refused or
  interrupted after it closed a window, removed a buffer or ended a save
  is rolled back whole: nothing was given up, so the window and the buffer
  of the state from before are over markers and a text that still answer,
  and the save that is in flight again is over a snapshot that still
  reads. Giving up inside the request would leave a rollback with a window
  over markers that are gone.
- **A refusal is said.** What the store refuses here, such as the release
  of a text the command had released itself, is in the echo area, as a
  refusal met while publishing is (`refused: ` and the refusal), in place
  of what the command left there. The rest is still given up.
- **What is not given up**: the texts, snapshots and markers a command
  made and no window or buffer of the state it left holds, whether it ran
  to its end or not.

## The interrupt

The Rust library raises a flag as the interrupt key arrives, before the key
is queued, and marks that event. What the loop does with the flag is here
(`Editor/Watch.lean` has the port):

- **A command the loop runs is guarded** (`EditorM.dispatched`,
  `Editor/Command/Dispatch.lean`, "The guard", the rule's one definition):
  the flag is asked before each of its requests that reaches the library,
  and once it is up the command makes no further request. A state request
  is answered without asking. The command is then rolled back like one
  that was refused, and the echo area reads `<name>: interrupted`.
- **Only the command is guarded.** The loop's own requests (keeping,
  rolling back, publishing) are not, so a flag that is up stops neither a
  rollback nor a scene.
- **The flag comes down when the loop takes the interrupt key off the
  queue** (`Loop.take`): for an event the library marked
  (`Received.interrupt`), the loop makes the request `Watch.lower`, and for
  no other event. The library decided once, at arrival, which event is an
  interrupt key, so the two cannot disagree. The flag is a count, so with
  two interrupt keys queued it stays up until the second is taken.
- **The interrupt key is then stepped like any key**, after the flag is
  lowered, so a scheme can bind it, and what it is bound to is not
  interrupted by it.
- **Consequences.** A command for a key queued ahead of the interrupt key
  finds the flag up at its first check and makes no request. An interrupt
  key that arrives while nothing runs interrupts nothing: the flag is down
  again before the next key's command starts. The echo of an interrupted
  command is still there after the interrupt key is stepped and found
  bound to nothing, since a key that yields nothing leaves the echo. A
  command that makes no request is not interruptible.

## What each event does

| Event | What it does to the state |
|---|---|
| `commit text` | Replaces what each range of the focused window's selection covers with `text`, as one transaction with the user's origin, and clears the preedit |
| `preedit text` | Sets the preedit to `text`; an empty one clears it |
| `compositionDisabled` | Clears the preedit |
| `resize` | Sets the frame's size; the views are laid out in it when the scene is made. Its scale is not kept: the scene has no field for it |
| `focus gained` | Sets whether the frame has the keyboard focus |
| `closeRequested`, `quit` | Nothing: the step says stop, and publishes nothing |
| a key press | It is stepped through the scheme, whose state the loop keeps ("The scheme"), and the invocation it yields, if it yields one, is run ("Running an invocation") |
| a key release, the press of a modifier by itself, a pointer, `windowOpened`, `compositionEnabled`, a message, a completion | Nothing |

A handler is given what it acts on (a `Target`: the window and its buffer),
never "the current buffer". When one is refused, the state stays as it was
and the echo area reads `refused: ` and the refusal (`TextError.describe`).
A handler's edit is one transaction, so a refusal leaves nothing behind in
the store; what a command leaves behind is rolled back ("Rollback").

## After each event

Every event but `closeRequested` and `quit` publishes a scene, whether it
changed the state or not (`Loop.publish`):

1. **The histories.** Each buffer's undo tree is told the revision its text
   is at, and its group is closed (`EditorState.recordHistories`): what an
   event edited is one step of the history.
2. **The scene** (`Loop.views`, `Loop.scene`). Each window in the tree, in
   drawing order, is a view in the rectangle `Split.rects` gives it in the
   frame. While a prompt is open the minibuffer's window is a view too, in
   the strip the minibuffer's place then takes (`Editor/State.lean`, "The
   split tree and its invariants"): its text is the input typed so far,
   its selection the cursor in it, and it is the focused view while it has
   the focus. A view
   whose buffer's text is at the revision it was last shown at keeps the
   same snapshot; otherwise a new snapshot is taken, and views of one
   buffer share it. A view's scroll anchor and selection are its window's
   markers, its cursor a bar in the face `cursor`, with no decorations:
   later phases choose those. Its status line is two fields at most
   (`Loop.status`): its buffer's name, in the face `Loop.nameFace`, and,
   while the buffer is modified (`Buffer.isModified`), the text
   `Loop.modifiedMark` in the face `Loop.modifiedFace`. "Modified" is the
   presence of the second field: a buffer that is not has no such field.
   The answer is right because the histories were told their texts'
   revisions in step 1. The minibuffer's view has another status line
   (`Loop.statusOf`): one field, the prompt's label, in the face
   `Loop.promptFace`, with no name and no modified field. That is how the
   scene shows the prompt text: the scene's shape is the display
   contract, and it has no field for a prompt. The input is the whole text
   of the minibuffer's buffer, so the label is no part of it: the text
   store has no read-only range to keep a label in. The focused view is named only while the frame has
   the keyboard focus. The pending prefix is the scheme's pending keys
   (`Loop.pending`).
3. **Publish** it through the display port.
4. **Release** each snapshot the previous scene named that this one does
   not. So a scene's handles are alive while it is the last one published,
   and a real binding resolves them when it is published.

Every edit the loop makes for an input event carries `Origin.user`.

## When publishing is refused

Publishing asks the store too: each buffer's text for its revision, a text
that changed for a snapshot, and the store to release the snapshots the
last scene named. Each is refused once the text or the snapshot is gone,
and a command can release either: their ids are plain indices. The cause
that refuses a handler (the focused buffer's text was released) refuses
these as well, so a publish that failed with them would lose the echo the
handler's refusal had just written.

`Loop.publish` is therefore not refused by any of them, and neither is
`Loop.step`: a scene is published after the event all the same.

- **A buffer whose text refuses keeps its history as it was.** The other
  buffers' histories are recorded.
- **A view whose buffer's text refuses is left out of the scene**, and
  nothing is taken for it. The other views keep their rectangles, so the
  views then do not tile the frame, and the scene names a focused view it
  does not hold when that view is the one left out.
- **The refusal is in the echo area**, as a refused handler's is (`refused: `
  and `TextError.describe`), in the state the loop keeps and in the scene
  it publishes. It is the first refusal of the publish, and it replaces the
  echo a refused handler wrote in the same step.
- **A release that is refused** comes after the scene is published, for a
  snapshot that was released behind the loop. The loop keeps the new
  scene's snapshots all the same, and the refusal is in the echo area of
  the state it returns, so the next scene shows it.

Nothing here touches the layout or the windows: the state the loop keeps is
the one the handler left, with the echo set, and a well-formed state stays
well formed. A host still has to deal with a program of the loop that is
refused, because an `EditorM` can be; none is today, and a host prints one
that is instead of dropping it (`Headless.Running.attempt`).

One case is not seen: a snapshot of the last scene released behind the loop
while its text did not change. The loop asks nothing of a snapshot it
keeps, so nothing is refused, and the scenes go on naming a snapshot that
is gone until the text changes.

These are pinned by `ModelTest.loopChecks`, and through the headless host by
`ConfigTest.scriptChecks`.

## Where a new event handler goes

A new event is handled by a case of `Loop.handle`, which hands a handler of
its own the `Target` it acts on (`EditorState.focusedTarget?`, or the window
the event names) and the state. Its effect on the state and on the scene is
pinned by a check in `ModelTest.loopChecks`, on the models.

What a key does is not a handler's: keys, the commands they run and
rollback are pinned by `ModelTest.dispatchChecks`, on the models and the
test scheme.

The known gap: no view scrolls to follow its cursor in this phase (phase
15).
-/

namespace Editor

/-- What a view showed: a buffer's text, the revision it was at, and the
snapshot taken of it then. -/
structure Loop.Shown where
  /-- The text. -/
  text : TextId
  /-- Its revision when the snapshot was taken. -/
  revision : Nat
  /-- The snapshot. -/
  snapshot : SnapshotId
  deriving DecidableEq, Repr

/-- The loop's own state, for a loop that runs the input scheme `scheme`:
the editor state, the snapshots the last scene named, and the scheme's
state.

The scheme is a parameter and not a field: an `InputScheme` has type-valued
fields, so it is in `Type 1`, and a loop is handed through `EditorM` and
`IO`, whose values are in `Type`. It has no equality, since a scheme's state
has none. -/
structure Loop (scheme : InputScheme) where
  /-- The editor state. -/
  state : EditorState
  /-- The snapshots the last scene published named, one a text. -/
  shown : Array Loop.Shown := #[]
  /-- The scheme's state after the last key. -/
  input : scheme.State := scheme.init
  /-- The scheme's state at rest: the last one in which nothing was pending
  and no command had just failed. It is what the scheme goes back to when
  the invocation a key yields does not run to its end. -/
  atRest : scheme.State := scheme.init

/-- What the loop does after a step. -/
inductive Loop.Next where
  /-- Pull the next event. -/
  | continue
  /-- End: the window was asked to close, or the queue was quit. -/
  | stop
  deriving DecidableEq, Repr

/-- How long a command may take before it is logged as slow, in
milliseconds, unless a step is handed another threshold. -/
def Loop.slowAfter : Nat :=
  100

/-- What a step is handed beside the loop and the event: what the keys are
looked up in, and what an invocation runs. It is rebuilt by the caller for
each step, from the registry as it then is, so a reload changes it between
two events. -/
structure Loop.Keys (scheme : InputScheme) where
  /-- The active keymaps of each view in an editor state, in precedence
  order. The loop applies it to its own state. -/
  maps : EditorState → ViewId → List (Keymap scheme.Binding) := fun _ _ => []
  /-- What an invocation of the command of a name runs: given what it is
  called with, the program, whose value is what the command asks to be
  written; `none` for a name no command is registered under. -/
  command? : String → Option (Call → EditorM (Option Config.Write)) := fun _ => none
  /-- How long a command may take before it is logged as slow, in
  milliseconds: one that takes longer is logged. -/
  slowAfter : Nat := Loop.slowAfter
  /-- What a command's state requests are told of the registry
  (`Editor/Command/Dispatch.lean`). -/
  registered : Loop.Registered := {}

/-- How a command the loop ran ended. -/
inductive Loop.Ending where
  /-- It ran to its end. -/
  | finished
  /-- It was refused, with `error`, and rolled back. -/
  | refused (error : TextError)
  /-- The interrupt flag was up before one of its requests, and it was
  rolled back. -/
  | interrupted
  /-- No command is registered under the name. -/
  | noSuchCommand
  /-- No window is focused for the command to act on. -/
  | noWindow
  deriving DecidableEq, Repr

/-- What a step hands back: the loop after it, and what to do next. A
one-shot output of a step is a field here. -/
structure Loop.Stepped (scheme : InputScheme) where
  /-- The loop after the step. -/
  loop : Loop scheme
  /-- Whether to pull the next event. -/
  next : Loop.Next
  /-- What the command the step ran asked to be written: the new tree of a
  store's cell, for whoever holds the cells to write back. `none` for a
  step that ran no command, and for one whose command did not run to its
  end. -/
  write : Option Config.Write := none
  /-- What the step has to say to whoever keeps a log, one entry a line: a
  command it ran that took longer than the threshold. The loop writes
  nothing itself. -/
  log : Array String := #[]
  /-- The jobs the command the step ran asked to be started, in the order it
  asked, for the host to start. None for a step that ran no command, and
  for one whose command did not run to its end. -/
  starts : Array JobStart := #[]
  /-- How the command the step ran ended; `none` for a step that ran no
  command. -/
  ended : Option Loop.Ending := none

namespace EditorState

/-- `state` with `refusal` in the echo area: `refused: ` and what it was. -/
def refused (state : EditorState) (refusal : TextError) : EditorState :=
  { state with echo := s!"refused: {refusal.describe}" }

/-- `state`, with `refusal` in the echo area if there is one. -/
def refusedBy (state : EditorState) : Option TextError → EditorState
  | some refusal => state.refused refusal
  | none => state

/-- Tells each buffer's undo tree the revision its text is at, and closes its
group: what an event edited becomes one step of its history. It is not
refused: a buffer whose text refuses, because it was released, keeps its
history as it was, and the first such refusal is handed back. -/
def recordHistories (state : EditorState) : TextM (EditorState × Option TextError) := do
  let mut buffers := #[]
  let mut refusal := none
  for slot in state.buffers do
    let some buffer := slot |
      buffers := buffers.push none
      continue
    match ← observing buffer.history.sync with
    | .ok history =>
      buffers := buffers.push (some { buffer with history := history.close })
    | .error error =>
      buffers := buffers.push (some buffer)
      refusal := refusal <|> some error
  return ({ state with buffers }, refusal)

end EditorState

namespace Loop

variable {scheme : InputScheme}

/-- A loop that runs `scheme`, over the initial state, in a frame of `size`,
with nothing shown yet and no key typed. -/
def start (scheme : InputScheme) (size : Size) : TextM (Loop scheme) :=
  return { state := ← EditorState.initial size }

/-- How every view's cursors are drawn, until the phases that choose them. -/
def cursor : Cursor :=
  { shape := .bar, face := ⟨"cursor"⟩ }

/-- The face of the status line's first field, the buffer's name. -/
def nameFace : FaceName :=
  ⟨"status.name"⟩

/-- The face of the status line's modified field. -/
def modifiedFace : FaceName :=
  ⟨"status.modified"⟩

/-- What the status line's modified field says. -/
def modifiedMark : String :=
  "[+]"

/-- The face of the minibuffer's status line, which is the prompt's label. -/
def promptFace : FaceName :=
  ⟨"minibuffer.prompt"⟩

/-- The status line of a view of `buffer`: the buffer's name, and, while the
buffer is modified, the modified field after it. A buffer that is not
modified has no such field, not an empty one. -/
def status (buffer : Buffer) : Array StatusField :=
  #[{ text := buffer.name, face := nameFace }] ++
    if buffer.isModified then #[{ text := modifiedMark, face := modifiedFace }] else #[]

/-- The status line of the view `id` of `state`, which shows `buffer`: the
prompt's label alone, in `promptFace`, for the minibuffer's view, and the
buffer's (`status`) for any other. -/
def statusOf (state : EditorState) (id : ViewId) (buffer : Buffer) : Array StatusField :=
  match state.prompt with
  | some asked =>
    if asked.view == id then #[{ text := asked.label, face := promptFace }] else status buffer
  | none => status buffer

/-- The views of the loop's state, in drawing order, and the snapshots they
name: its windows, and the minibuffer's view in the minibuffer's place
while a prompt is open. A text at the revision it was last shown at keeps
its snapshot; any other is given a new one. A view's status line is its
buffer's, and the prompt's label for the minibuffer's view (`statusOf`). It
is not refused: a view whose buffer's text refuses, because it was
released, is left out, with nothing taken for it, and the first such
refusal is handed back. -/
def views (loop : Loop scheme) : TextM (Array View × Array Shown × Option TextError) := do
  let state := loop.state
  let frame := state.frame
  let mut shown : Array Shown := #[]
  let mut views : Array View := #[]
  let mut refusal := none
  for (id, rect) in
    frame.tree.rects { x := 0, y := 0, width := frame.size.width, height := frame.size.height }
      state.minibufferView? do
    let some target := state.target? id | continue
    let text := target.buffer.text
    let taken ←
      observing do
          let revision ← text.revision
          match
            (shown ++ loop.shown).find? fun was => was.text == text && was.revision == revision with
          | some was =>
            pure (revision, was.snapshot)
          | none =>
            return (revision, ← text.snapshot)
    match taken with
    | .error error =>
      refusal := refusal <|> some error
    | .ok (revision, snapshot) =>
      unless shown.any (·.text == text) do
        shown := shown.push { text, revision, snapshot }
      views :=
        views.push
          { id, rect, snapshot, scroll := target.window.scroll,
            selections := #[target.window.selection]
            cursor, decorations := #[], status := statusOf state id target.buffer }
  return (views, shown, refusal)

/-- The scene of `state` over `views`: what the state says of the frame, the
echo area and the preedit, around the views made of its windows, with
`pending` as the keys typed of a sequence not yet completed. -/
def scene (state : EditorState) (views : Array View) (pending : String) : Scene :=
  let frame := state.frame
  { size := frame.size, views, focused := if frame.hasFocus then some frame.focused else none
    echo := state.echo, pending, preedit := state.preedit }

/-- The keys the scheme reports as pending in the loop's state, as a key
string (`Key.notations`): what the scene shows of a sequence begun and not
completed, and empty when none is. -/
def pending (loop : Loop scheme) : String :=
  Key.notations (scheme.pending loop.input)

/-- Records the histories, publishes a scene of the state, and releases each
snapshot the last scene named that this one does not. It is not refused
("When publishing is refused", in the module docs): a refusal of a buffer's
text is in the echo area of the scene it publishes, and one of a release in
the echo area of the state it returns. -/
def publish (loop : Loop scheme) : EditorM (Loop scheme) := do
  let (state, unrecorded) ← loop.state.recordHistories
  let (views, shown, unshown) ← ({ loop with state } : Loop scheme).views
  let state := state.refusedBy (unrecorded <|> unshown)
  Display.publish (scene state views loop.pending)
  let mut unreleased := none
  for was in loop.shown do
    unless shown.any (·.snapshot == was.snapshot) do
      if let .error error← (observing was.snapshot.release : TextM (Except TextError Unit)) then
        unreleased := unreleased <|> some error
  return { loop with
      state := state.refusedBy unreleased, shown }

/-- Replaces what each range of `target`'s selection covers with `text`, as
one transaction with the user's origin, which carries the selection before
and the cursors after, and places the selection at those cursors
(`Target.replaceSelections`, `Editor/Api.lean`). Refused with
`noSuchMarker` when the window's selection marker was given up. -/
def insert (target : Target) (text : String) : TextM Unit :=
  target.replaceSelections text

/-- What `event` does to `state` ("What each event does", in the module
docs). -/
def handle (state : EditorState) : Event → EditorM EditorState
  | .preedit text => return { state with preedit := if text.isEmpty then none else some text }
  | .compositionDisabled => return { state with preedit := none }
  | .resize resize =>
    return { state with frame := { state.frame with size := ⟨resize.width, resize.height⟩ } }
  | .focus gained => return { state with frame := { state.frame with hasFocus := gained } }
  | .commit text => do
    let some target := state.focusedTarget? | return { state with preedit := none }
    insert target text
    return { state with preedit := none }
  | _ => return state

/-- Whether the loop steps `event` through its scheme: a key press, a
repeat among them, whose key is not a modifier by itself
(`Key.isModifier`). The key it steps, if so. -/
def stepped? : Event → Option Key
  | .key key true _ => if key.isModifier then none else some key
  | _ => none

/-- What the loop keeps before a command, to roll back to if the command
does not run to its end ("Rollback", in the module docs). -/
structure Kept where
  /-- For each buffer whose text answered, by its index in the state's
  buffers: the state of its undo tree, once told the revision the text was
  at. -/
  histories : Array (Nat × UndoTree.State) := #[]
  /-- Each window's selection marker and scroll marker that answered, as it
  was read. -/
  markers : Array (MarkerId × Marker) := #[]
  deriving DecidableEq, Repr

/-- What to roll back to from `state`: each buffer's history state and each
window's markers, as they are now. It is not refused: a buffer whose text
refuses, and a marker that does, is not kept. -/
def keep (state : EditorState) : TextM Kept := do
  let mut histories := #[]
  for index in [0:state.buffers.size] do
    let some buffer := state.buffer? ⟨index⟩ | continue
    if let .ok history← observing buffer.history.sync then
      histories := histories.push (index, history.state)
  let mut markers := #[]
  for window in state.windows do
    for id in [window.selection, window.scroll] do
      if let .ok marker← observing (id.text.marker id) then
        markers := markers.push (id, marker)
  return { histories, markers }

/-- Rolls one buffer's text back to the history state `was`, which `kept`,
the buffer's tree from before the command, was in when it was kept. `left`
is the tree the command left. Each tree it reverts is told the revision the
text is at first, and each revert is made with the user's origin. The tree
after it, and whether the history moved since `was` was kept.

- `left` is reverted to `was` when `was` is a state of its open group: the
  command set no boundary and made no move it did not make back.
- Otherwise the command set a boundary or moved. When `left` still has
  every edge of `kept` (`UndoTree.keepsEdgesOf`), `kept` is reverted to
  `was`: its open group is everything since, across the steps the command
  closed, and none of them is left. The store refuses that when the command
  also moved over a step of its own.
- Otherwise the history moved: the move is not taken back, and the group
  that is open in `left` is reverted instead, which takes back the edits
  made since the move. -/
def revertBuffer (kept left : UndoTree) (was : UndoTree.State) : TextM (UndoTree × Bool) := do
  let history ← left.sync
  if let some reverted← history.revertTo was Origin.user then
    return (reverted.tree, false)
  if left.keepsEdgesOf kept then
    -- Refused, with nothing changed, when the command moved over a step of
    -- its own: the move dropped inverses of the run this would take back.
    let whole ←
      observing do
          (← kept.sync).revertTo was Origin.user
    if let .ok (some reverted) := whole then
      return (reverted.tree, false)
  match ← history.revert Origin.user with
  | some reverted =>
    return (reverted.tree, true)
  | none =>
    return (history, true)

/-- Rolls back to what was kept ("Rollback", in the module docs), from
`before`, the state from before the command, and `after`, the state the
command left: each kept buffer's text is reverted to its kept history
state (`revertBuffer`), from the tree the buffer has in `before` and the
one it has in `after`, when `after` still has it over the same text, and
each kept marker is placed back. The tree that comes back is given the
saved state the buffer's tree has in `before`. Returns `before`
with the buffers' histories after it, and what to say of the rollback after
the command's error, which is nothing when all of it was done.

It is not refused. The first thing that refuses is said, `; not rolled
back: ` and the refusal, and the rest is still done. A buffer whose history
moved since it was kept is said too, `; the command moved in the history`,
and the markers of its text are left where the store moved them. -/
def Kept.restore (kept : Kept) (before after : EditorState) : TextM (EditorState × String) := do
  let mut buffers := before.buffers
  let mut refusal : Option TextError := none
  let mut moved : Array TextId := #[]
  for (index, was) in kept.histories do
    let some (some buffer) := buffers[index]? | continue
    -- The tree the command left knows of a move the command made, and of
    -- the boundaries it set.
    let left :=
      match after.buffer? ⟨index⟩ with
      | some left => if left.text == buffer.text then left.history else buffer.history
      | none => buffer.history
    match ← observing (revertBuffer buffer.history left was) with
    | .ok (reverted, movedSince) =>
      -- The tree that was reverted may be the one the command left, which
      -- carries a mark of the saved state the command set: the mark from
      -- before the command is put back.
      let history := { reverted with saved := buffer.history.saved }
      buffers := buffers.modify index (·.map ({ · with history }))
      if movedSince then
        moved := moved.push buffer.text
    | .error error =>
      refusal := refusal <|> some error
  for (id, marker) in kept.markers do
    unless moved.contains id.text do
      if let .error error← observing (id.text.place id marker) then
        refusal := refusal <|> some error
  let history := if moved.isEmpty then "" else "; the command moved in the history"
  let unrestored :=
    match refusal with
    | some error => s!"; not rolled back: {error.describe}"
    | none => ""
  return ({ before with buffers }, history ++ unrestored)

/-- The snapshots of the saves in flight in `state`: one for each buffer
that has one (`Buffer.File.saving`). -/
def savesInFlight (state : EditorState) : Array SnapshotId :=
  state.buffers.filterMap fun slot => ((slot.bind (·.file)).bind (·.saving)).map (·.snapshot)

/-- Gives up what a command that ran to its end dropped ("What a finished
command gave up", in the module docs), `before` being the state from before
it and `after` the state it left: each marker of a window of `before` that
no window of `after` uses, then the snapshot of each save in flight in
`before` that is not in flight in `after`, and then the text of each buffer
of `before` whose slot is empty in `after`, unless a buffer of `after` is
over it. It is not refused: the first thing the store refuses is handed
back, and the rest is still given up. -/
def gaveUp (before after : EditorState) : TextM (Option TextError) := do
  let mut refusal := none
  let held := after.windows.flatMap fun window => #[window.selection, window.scroll]
  for window in before.windows do
    for id in [window.selection, window.scroll] do
      unless held.contains id do
        if let .error error← observing (id.text.unmark id) then
          refusal := refusal <|> some error
  let saving := savesInFlight after
  for snapshot in savesInFlight before do
    unless saving.contains snapshot do
      if let .error error← (observing snapshot.release : TextM (Except TextError Unit)) then
        refusal := refusal <|> some error
  for index in [0:before.buffers.size] do
    let some buffer := before.buffer? ⟨index⟩ | continue
    if (after.buffer? ⟨index⟩).isSome || after.buffers.any (·.any (·.text == buffer.text)) then
      continue
    if let .error error← observing buffer.text.release then
      refusal := refusal <|> some error
  return refusal

/-- The views `before` has a window of and `after` has none of: the views a
command that took the one to the other closed. -/
def closedViews (before after : EditorState) : Array ViewId :=
  before.windows.filterMap fun window =>
    if (after.window? window.id).isNone then some window.id else none

/-- `state`, a state of the loop's scheme, once it is told that each of
`views` is closed (`InputScheme.closeView`). -/
def forgetViews (views : Array ViewId) (state : scheme.State) : scheme.State :=
  views.foldl (fun state view => scheme.closeView view state) state

/-- What running a command came to. -/
structure Ran where
  /-- The editor state after it, with what it left in the echo area. -/
  state : EditorState
  /-- How the command ended. -/
  ending : Ending
  /-- The views the command closed, when it ran to its end. -/
  closed : Array ViewId := #[]
  /-- What the command asked to be written, when it ran to its end. -/
  write : Option Config.Write := none
  /-- The log entry of a command that took longer than the threshold. -/
  log : Array String := #[]
  /-- The jobs the command asked to be started, when it ran to its end. -/
  starts : Array JobStart := #[]

/-- Whether the command ran to its end. -/
def Ran.finished (ran : Ran) : Bool :=
  ran.ending == .finished

/-- `state` with what became of the command called `name` in the echo
area: its name, then `what`. -/
def said (state : EditorState) (name what : String) : EditorState :=
  { state with echo := s!"{name}: {what}" }

/-- The log entries of the command called `name`, which took `took`
milliseconds: one, with its name and how long it took, when that is more
than `threshold`, and none otherwise. -/
def slow (name : String) (took threshold : Nat) : Array String :=
  if took > threshold then #[s!"slow command: {name} took {took} ms"] else #[]

/-- Runs `command` from `state`, under `name`, as the loop runs every
command ("Every command goes through the loop", in the module docs):
dispatched (`EditorM.dispatched`: guarded, with its state requests answered
from `state`). The state of a command that ran to its end is the one it
left, with the jobs it asked for taken out and handed back. It is not
refused: a refusal of the command and an interrupt are each said in the
echo area, after `name`, and a command that was refused or interrupted is
rolled back to the state from before it, with what could not be said after
it.

Only the command is guarded. What this makes of its own requests, keeping
before it, rolling back after it and giving up what a command that ran to
its end dropped (`gaveUp`), is not, so a flag that is up does not stop a
rollback.

The clock is read just before the command and just after it, however it
ended, and a command that took longer than the threshold is logged
(`slow`). Keeping and rolling back are not timed. -/
def dispatch (keys : Keys scheme) (state : EditorState) (name : String)
    (command : EditorM (Option Config.Write)) : EditorM Ran := do
  let kept ← keep state
  let started ← Watch.now
  let (outcome, left) ← command.dispatched keys.registered state
  let log := slow name ((← Watch.now) - started) keys.slowAfter
  let failed (what : String) (ending : Ending) : EditorM Ran := do
    let (state, unrestored) ← kept.restore state left
    return { state := said state name (what ++ unrestored), ending, log }
  match outcome with
  | .finished write =>
    let ungiven ← gaveUp state left
    return {
        state := { left.refusedBy ungiven with starts := #[] }
        ending := .finished
        closed := closedViews state left
        write
        log
        starts := left.starts }
  | .refused refusal =>
    failed s!"refused: {refusal.describe}" (.refused refusal)
  | .interrupted =>
    failed "interrupted" .interrupted

/-- Runs `invocation`, which the keys `typed` yielded, from `state` ("Running
an invocation", in the module docs): clears the echo area, looks the
command up, and runs it (`dispatch`) with the focused window, the
invocation's arguments and the keys. It is not refused: a name with no
command and a state with no focused window are each said in the echo area,
as what became of a command that did not run to its end is. -/
def run (keys : Keys scheme) (state : EditorState) (invocation : Invocation) (typed : List Key) :
    EditorM Ran := do
  let state := { state with echo := "" }
  let name := invocation.command
  let some command :=
    keys.command?
      name | return { state := said state name "no such command", ending := .noSuchCommand }
  let some target :=
    state.focusedTarget? | return { state := said state name "no window is focused", ending := .noWindow }
  dispatch keys state name (command { target, arguments := invocation.arguments, keys := typed })

/-- What a step that ran a command hands back, before its scene is
published: `loop` with the state the command left, and the scheme's two
states told of each view the command closed (`forgetViews`). -/
def ranInto (loop : Loop scheme) (ran : Ran) : Stepped scheme :=
  { loop :=
      { loop with
        state := ran.state
        input := forgetViews ran.closed loop.input
        atRest := forgetViews ran.closed loop.atRest }
    next := .continue
    write := ran.write
    log := ran.log
    starts := ran.starts
    ended := some ran.ending }

/-- One key through the scheme, for the focused view, and the invocation it
yields, if it yields one, run (`run`): what the step hands back, with the
loop after them, whose scene is not yet published. The keys the command is
told of are what the scheme reported as pending before the key, then the
key's chord.

The scheme's state after the key is kept, and it is the state at rest from
then on, when the invocation ran to its end, or when the key yielded
nothing and left nothing pending. When the invocation did not run to its
end the scheme goes back to its state at rest: it is as it was before the
first key of the sequence. -/
def key (keys : Keys scheme) (loop : Loop scheme) (key : Key) : EditorM (Stepped scheme) := do
  let before := scheme.pending loop.input
  let (input, yielded) := scheme.step (keys.maps loop.state) loop.state.frame.focused loop.input key
  let some invocation := yielded |
    return {
        loop :=
          { loop with
            input, atRest := if (scheme.pending input).isEmpty then input else loop.atRest }
        next := .continue }
  let ran ← run keys loop.state invocation (before ++ [key.chord])
  if ran.finished then
    return ({ loop with
              input, atRest := input } :
            Loop scheme).ranInto
        ran
  else
    return ({ loop with input := loop.atRest } : Loop scheme).ranInto ran

/-- Runs `invocation`, which no key yielded (`run`), and publishes a scene of
the state after it: the echo area is cleared, the command is looked up, and
it is called with the focused window, the invocation's arguments and no
keys. The scheme's states are left as they are, but for a view the command
closed. -/
def invoke (keys : Keys scheme) (loop : Loop scheme) (invocation : Invocation) :
    EditorM (Stepped scheme) := do
  let stepped := loop.ranInto (← run keys loop.state invocation [])
  return { stepped with loop := ← stepped.loop.publish }

/-- Runs the command registered under `name` as an invocation with no
arguments that no key yielded (`invoke`), and publishes a scene of the
state after it: what a host's driver asks for. -/
def runNamed (keys : Keys scheme) (loop : Loop scheme) (name : String) : EditorM (Stepped scheme) :=
  loop.invoke keys { command := name }

/-- Runs `command`, which the loop is handed with `label` as its name, and
publishes a scene of the state after it: how a finished job's command is
run. It is run as every command is (`dispatch`), and it is no invocation:
the echo area is not cleared, so a command that says nothing leaves what
the user was reading. When it does not run to its end the echo area reads
`<label>: refused: ` and the refusal, or `<label>: interrupted`. -/
def deliver (keys : Keys scheme) (loop : Loop scheme) (label : String) (command : EditorM Unit) :
    EditorM (Stepped scheme) := do
  let ran ←
    dispatch keys loop.state label do
        command
        return none
  let stepped := loop.ranInto ran
  return { stepped with loop := ← stepped.loop.publish }

/-- Handles `event` and publishes a scene of the state after it, and says
whether to go on. A close request and a quit stop the loop and publish
nothing. A key press is stepped through the scheme, and the invocation it
yields is run (`stepped?`, `key`). A handler that is refused leaves the
state as it was, with the refusal in the echo area. The step itself is not
refused: the publish puts a refusal of its own in the echo area too ("When
publishing is refused", in the module docs). -/
def step (keys : Keys scheme) (loop : Loop scheme) (event : Event) : EditorM (Stepped scheme) := do
  if let some pressed := stepped? event then
    let stepped ← loop.key keys pressed
    return { stepped with loop := ← stepped.loop.publish }
  match event with
  | .closeRequested | .quit =>
    return { loop, next := .stop }
  | _ =>
    let state ←
      try
        handle loop.state event
      catch refusal =>
        pure (loop.state.refused refusal)
    return { loop := ← { loop with state }.publish, next := .continue }

/-- Lowers the interrupt flag for an event taken off the queue when the
library marked it as a press of the interrupt key (`interrupt`), and for no
other: one fewer interrupt key is on the queue. `take` makes it for each
event it steps, and a host for a window event no loop takes, one it cannot
read or one that arrives when it has no loop: that event has been taken off
the queue all the same. -/
def lowerFor (interrupt : Bool) : WatchM Unit := do
  if interrupt then
    Watch.lower

/-- Takes what arrived off the queue: lowers the interrupt flag when the
library marked the event as a press of the interrupt key
(`Received.interrupt`, `lowerFor`), and then steps the event like any other
(`step`), so a scheme can bind the interrupt key. This is what a host calls
for each event it pulls.

The flag is lowered first: the key has been taken off the queue, so what
its own binding runs is not interrupted by it. -/
def take (keys : Keys scheme) (loop : Loop scheme) (received : Received) :
    EditorM (Stepped scheme) := do
  lowerFor received.interrupt
  loop.step keys received.event

end Loop

end Editor
