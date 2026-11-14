import Editor.Command
import Editor.Command.Call
import Editor.Command.Guard
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
4. **A refusal is said in the echo area**, `<name>: refused: ` and the
   refusal (`TextError.describe`), and the editor keeps running: the step
   is not refused, and the next key is handled. What the command did before
   it was refused is rolled back ("Rollback").
5. **What the command asked to be written** (a command over a store) is
   handed back with the step (`Loop.Stepped.write`), for whoever holds the
   cells.
6. **A slow command is logged.** The loop reads the watch port's clock just
   before the command and just after it, however it ended. When it took
   longer than the threshold the step was handed (`Loop.Keys.slowAfter`,
   `Loop.slowAfter` by default), the step hands back one entry
   (`Loop.Stepped.log`): `slow command: <name> took <n> ms`. The loop
   writes no log itself: the host does, with what the step hands back.

A call into a config command is not guarded against the interpreter: an
exception thrown by interpreted code ends the process
(`docs/design/lean-runtime.md`, "An exception from the interpreter ends the
process").

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
  state is the one before the command.
- **Markers are placed back, and not left to the inverse.** A marker moves
  with every transaction: a deletion and its inverse do not return a marker
  inside the deleted range to where it was, and a command can place a
  marker with no edit. A revert hands back only the selection a transaction
  carried.
- **No group of its own.** The kept state may be a point inside an open
  group, and the revert goes back to it. The loop closes each group after
  every event (`Loop.publish`), so today the kept state is a node's, and
  the revert leaves nothing pending, no node and nothing to redo.
- **What is not undone**: the texts, snapshots and markers the command
  made, and the scenes it published. The step publishes the true scene
  right after.
- **A rollback that is refused is said, and the rest is still done.** A
  command that released a buffer's text, gave up a window's marker or
  dropped the inverses of its own edits cannot be rolled back. The echo
  area then ends `; not rolled back: ` and the first refusal.
- **A move in the history is not taken back.** When the kept state is no
  longer a state of the open group, the history moved since it was kept.
  The loop then reverts the group that is open (`UndoTree.revert`), which
  takes back the edits made since the move and leaves the text at the node
  the move reached. The echo area ends `; the command moved in the
  history`, and the markers of that text are left where the store moved
  them. No command can move the loop's tree until commands have a request
  for it, so this is pinned on a state whose history was moved by hand.

An event's own handler, such as the commit's (`Loop.insert`), is one
transaction, which the store accepts whole or refuses whole, and is not
routed through this.

## The interrupt

The Rust library raises a flag as the interrupt key arrives, before the key
is queued, and marks that event. What the loop does with the flag is here
(`Editor/Watch.lean` has the port):

- **A command the loop runs is guarded** (`EditorM.guarded`,
  `Editor/Command/Guard.lean`): the flag is asked before each of its
  requests, and once it is up the command makes no further request. It is
  then rolled back like a command that was refused, and the echo area reads
  `<name>: interrupted`.
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
   frame. A view
   whose buffer's text is at the revision it was last shown at keeps the
   same snapshot; otherwise a new snapshot is taken, and views of one
   buffer share it. A view's scroll anchor and selection are its window's
   markers, its cursor a bar in the face `cursor`, with no decorations and
   an empty status line: later phases choose those. The focused view is
   named only while the frame has the keyboard focus. The pending prefix is
   the scheme's pending keys (`Loop.pending`).
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

/-- The views of the loop's state, in drawing order, and the snapshots they
name. A text at the revision it was last shown at keeps its snapshot; any
other is given a new one. It is not refused: a view whose buffer's text
refuses, because it was released, is left out, with nothing taken for it,
and the first such refusal is handed back. -/
def views (loop : Loop scheme) : TextM (Array View × Array Shown × Option TextError) := do
  let state := loop.state
  let frame := state.frame
  let mut shown : Array Shown := #[]
  let mut views : Array View := #[]
  let mut refusal := none
  for (id, rect) in
    frame.tree.rects { x := 0, y := 0, width := frame.size.width, height := frame.size.height } do
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
            cursor, decorations := #[], status := #[] }
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

/-- The changes that replace each of `extents`, sorted and apart, of a text
of `length` bytes, with `text`, and the cursor after each insertion. -/
def replacing (length : Nat) (extents : Array Extent) (text : String) :
    Array Change × Array SelectionRange :=
  Id.run do
    let mut changes := #[]
    let mut cursors := #[]
    let mut walked := 0
    let mut shift : Int := 0
    for extent in extents do
      changes :=
        changes ++
          #[.retain (extent.start - walked), .delete (extent.stop - extent.start), .insert text]
      let after := (extent.start + shift + text.utf8ByteSize).toNat
      cursors := cursors.push ⟨after, after⟩
      shift := shift + text.utf8ByteSize - (extent.stop - extent.start)
      walked := extent.stop
    return (changes.push (.retain (length - walked)), cursors)

/-- Replaces what each range of `target`'s selection covers with `text`, as
one transaction with the user's origin, which carries the selection before
and the cursors after, and places the selection at those cursors. Refused
with `noSuchMarker` when the window's selection marker was given up. -/
def insert (target : Target) (text : String) : TextM Unit := do
  let buffer := target.buffer.text
  let .selection selection ← buffer.marker target.window.selection | throw .noSuchMarker
  let extents ← buffer.extents selection
  let (changes, cursors) := replacing (← buffer.byteLength) extents text
  let after : Selection :=
    { ranges := cursors, primary := min selection.primary (cursors.size - 1),
      shape := selection.shape }
  discard <| buffer.apply { changes, before := some selection, after := some after } Origin.user
  buffer.place target.window.selection (.selection after)

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

/-- Rolls one buffer's text back to the history state `was`: tells the
tree the revision the text is at and reverts to `was`, with the user's
origin. The tree after it, and whether the history moved since `was` was
kept: `was` is then no state of the open group, the move is not taken back,
and the group that is open is reverted instead, which takes back the edits
made since the move. -/
def revertBuffer (buffer : Buffer) (was : UndoTree.State) : TextM (UndoTree × Bool) := do
  let history ← buffer.history.sync
  if let some reverted← history.revertTo was Origin.user then
    return (reverted.tree, false)
  match ← history.revert Origin.user with
  | some reverted =>
    return (reverted.tree, true)
  | none =>
    return (history, true)

/-- Rolls `state` back to what was kept ("Rollback", in the module docs):
each kept buffer's text is reverted to its kept history state, and each
kept marker is placed back. Returns the state with the buffers' histories
after it, and what to say of the rollback after the command's error, which
is nothing when all of it was done.

It is not refused. The first thing that refuses is said, `; not rolled
back: ` and the refusal, and the rest is still done. A buffer whose history
moved since it was kept is said too, `; the command moved in the history`,
and the markers of its text are left where the store moved them. -/
def Kept.restore (kept : Kept) (state : EditorState) : TextM (EditorState × String) := do
  let mut buffers := state.buffers
  let mut refusal : Option TextError := none
  let mut moved : Array TextId := #[]
  for (index, was) in kept.histories do
    let some (some buffer) := buffers[index]? | continue
    match ← observing (revertBuffer buffer was) with
    | .ok (history, movedSince) =>
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
  return ({ state with buffers }, history ++ unrestored)

/-- What running an invocation came to. -/
structure Ran where
  /-- The editor state after it, with what it left in the echo area. -/
  state : EditorState
  /-- Whether the command ran to its end. -/
  finished : Bool
  /-- What the command asked to be written, when it ran to its end. -/
  write : Option Config.Write := none
  /-- The log entry of a command that took longer than the threshold. -/
  log : Array String := #[]

/-- `state` with what became of the command called `name` in the echo
area: its name, then `what`. -/
def said (state : EditorState) (name what : String) : EditorState :=
  { state with echo := s!"{name}: {what}" }

/-- The log entries of the command called `name`, which took `took`
milliseconds: one, with its name and how long it took, when that is more
than `threshold`, and none otherwise. -/
def slow (name : String) (took threshold : Nat) : Array String :=
  if took > threshold then #[s!"slow command: {name} took {took} ms"] else #[]

/-- Runs `invocation`, which the keys `typed` yielded, from `state` ("Running
an invocation", in the module docs): clears the echo area, looks the
command up, and runs it, guarded (`EditorM.guarded`), with the focused
window, the invocation's arguments and the keys. It is not refused: a name
with no command, a refusal of the command and an interrupt are each said in
the echo area, and a command that was refused or interrupted is rolled back,
with what could not be said after it.

Only the command is guarded. What this makes of its own requests, keeping
before it and rolling back after it, is not, so a flag that is up does not
stop a rollback.

The clock is read just before the command and just after it, however it
ended, and a command that took longer than the threshold is logged
(`slow`). Keeping and rolling back are not timed. -/
def run (keys : Keys scheme) (state : EditorState) (invocation : Invocation) (typed : List Key) :
    EditorM Ran := do
  let state := { state with echo := "" }
  let name := invocation.command
  let some command :=
    keys.command? name | return { state := said state name "no such command", finished := false }
  let some target :=
    state.focusedTarget? | return { state := said state name "no window is focused", finished := false }
  let kept ← keep state
  let started ← Watch.now
  let outcome ← (command { target, arguments := invocation.arguments, keys := typed }).guarded
  let log := slow name ((← Watch.now) - started) keys.slowAfter
  let failed (what : String) : EditorM Ran := do
    let (state, unrestored) ← kept.restore state
    return { state := said state name (what ++ unrestored), finished := false, log }
  match outcome with
  | .finished write =>
    return { state, finished := true, write, log }
  | .refused refusal =>
    failed s!"refused: {refusal.describe}"
  | .interrupted =>
    failed "interrupted"

/-- One key through the scheme, for the focused view, and the invocation it
yields, if it yields one, run (`run`): the loop after them, what the
command asked to be written, and what there is to log. The keys the command
is told of are what the scheme reported as pending before the key, then the
key's chord.

The scheme's state after the key is kept, and it is the state at rest from
then on, when the invocation ran to its end, or when the key yielded
nothing and left nothing pending. When the invocation did not run to its
end the scheme goes back to its state at rest: it is as it was before the
first key of the sequence. -/
def key (keys : Keys scheme) (loop : Loop scheme) (key : Key) :
    EditorM (Loop scheme × Option Config.Write × Array String) := do
  let before := scheme.pending loop.input
  let (input, yielded) := scheme.step (keys.maps loop.state) loop.state.frame.focused loop.input key
  let some invocation := yielded |
    return ({ loop with
          input, atRest := if (scheme.pending input).isEmpty then input else loop.atRest },
        none, #[])
  let ran ← run keys loop.state invocation (before ++ [key.chord])
  if ran.finished then
    return ({ loop with
          state := ran.state, input, atRest := input },
        ran.write, ran.log)
  else
    return ({ loop with
          state := ran.state, input := loop.atRest },
        none, ran.log)

/-- Handles `event` and publishes a scene of the state after it, and says
whether to go on. A close request and a quit stop the loop and publish
nothing. A key press is stepped through the scheme, and the invocation it
yields is run (`stepped?`, `key`). A handler that is refused leaves the
state as it was, with the refusal in the echo area. The step itself is not
refused: the publish puts a refusal of its own in the echo area too ("When
publishing is refused", in the module docs). -/
def step (keys : Keys scheme) (loop : Loop scheme) (event : Event) : EditorM (Stepped scheme) := do
  if let some pressed := stepped? event then
    let (loop, write, log) ← loop.key keys pressed
    return { loop := ← loop.publish, next := .continue, write, log }
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
