import Editor.Command
import Editor.Scroll

/-!
# The editor API

The operations a command is written with, beyond the text port's own
(`Editor/Text.lean`): each is a program over the editor's port (`EditorM`,
`Editor/Command.lean`) made of state requests (`Editor/State/Request.lean`)
and text requests. `Editor.lean` imports this module, so config sees them.

## Asking the state

- `EditorState.ask request` makes one state request and returns its reply.
- `editorState` reads the whole state. A question is a pure function over
  it (`EditorState.buffer?`, `target?`, `findBuffer`, `value?`,
  `frame.focused`), so a command reads once and asks as much as it likes.

A reply that can be refused is a value, an `Except` of the operation's
refusal, which the command matches on: nothing here throws a refusal of the
state. What the text store refuses is thrown, as everywhere in `EditorM`.

The loop that runs a command answers its state requests
(`Editor/Command/Dispatch.lean`). Run bare, a command finds an editor with
nothing in it.

## Buffers

- `createBuffer name contents` makes a text holding `contents`, empty by
  default, and a buffer of that name over it, with a new undo tree. The
  name is checked against a read of the state first, so a name a buffer
  already has is refused (`nameTaken`) with no text made.
- `addBuffer name text` makes a buffer over a text the command already
  has: one it copied, or took in from a job's snapshot.
- `findBuffer name` is the buffer of that name, if there is one. Names are
  unique, so there is at most one.
- `BufferId.remove` removes a buffer no window shows. Its text is released
  by the loop once the command has run to its end (`Editor/Loop.lean`,
  "What a finished command gave up"), so a command that fails afterwards
  is rolled back whole.
- `BufferId.rename id name` gives a buffer another name; a name another
  buffer has is refused (`nameTaken`).
- `BufferId.hasUnsavedChanges id` is whether a buffer has unsaved changes
  (`Buffer.unsavedAt`), by a copy of its undo tree told the revision its
  text is at, so an edit made earlier in the same command counts. `quit`,
  `list-buffers` and `close-buffer` all ask it (`Editor/Buffers.lean`).
- `BufferId.text` is the buffer's text. Reading a buffer is the text
  port's reads on it (`TextId.read`, `rowContent`, `slice`, `byteLength`
  and the rest of `Editor/Text.lean`): there is no read request of the
  state beside them.
- `BufferId.attachFile id path stamp ending` has a buffer hold a file: its
  path, the stamp a load of it answered, and the buffer's line ending
  (`Editor/State.lean`, "A buffer's file"). A path another buffer holds is
  refused (`fileOpen`). Which buffer holds a path is a question of the
  state (`EditorState.findFile`).

## Edits at positions

Every edit here goes through the text port's `apply`, as one transaction
made by the user (`Origin.user`), so it is one revision, one entry of the
edit log, and one step for the buffer's history to be told of.

- `TextId.replaceRange text start stop s` replaces the bytes of `text`
  from `start` up to, not including, `stop` with `s`
  (`Transaction.replacing`). It is refused as the store refuses a
  transaction that does not fit its text, with `badChange`: an offset
  inside a character or past the end, and a range that ends before it
  starts.
- `BufferId.insertAt` and `BufferId.deleteRange` are that on the buffer's
  text: an insertion replaces an empty range, and a deletion replaces a
  range with nothing.
- Proved on the text model (`replaceRange_insert_delete`,
  `Editor/Api/Theorems.lean`): inserting a string at a character boundary
  and deleting the range it occupies leaves the text's contents as they
  were.

## Selections

A window's selection is a selection marker of its buffer's text
(`Window.selection`), whose ranges are the view's cursors. A command that
was handed its `Target` uses the operations on it, which are programs over
the text port; one that has a view's id uses the operations on `ViewId`,
which read the window from the state first and are refused, as a value,
with `noSuchWindow` for a view with no window.

- `selection` reads the selection, in the form the store keeps one in, and
  `select` places it. A selection the store refuses is thrown
  (`badSelection`).
- `insertAtSelections s` inserts `s` at the head of each range. Each range
  becomes a cursor just after its insertion; the primary and the shape
  are kept.
- `deleteSelections` deletes what each range covers, by the selection's
  shape (`TextId.extents`), and leaves a cursor where each started.
- `Target.replaceSelections s` replaces what each range covers with `s`
  and leaves a cursor after each: what a committed text does
  (`Editor/Loop.lean`).
- `insertLineBreak` breaks the line at the head of each range, with the
  buffer's line ending (`Buffer.lineEnding`, `File.LineEnding.text`): a
  line feed, or a carriage return and a line feed in a buffer whose file's
  lines mostly end that way. A command that breaks a line at the cursors
  calls it, and none writes `"\n"` itself. A command whose edit must carry
  the selection from before the command, and so is made with
  `Target.replaceCarrying`, reads the buffer's line ending itself: evil's
  commands that open a line (`Editor/Evil.lean`) and its line-wise put and
  line-wise registers (`Editor/Evil/Registers.lean`,
  `Editor/Evil/Operators.lean`). Nothing else is translated: a committed
  text and a text read from the clipboard are inserted as they are.

Each is one transaction made by the user that carries the selection before
and the cursors after, so undoing it hands the selection back
(`replaceExtents`), and the selection marker is then placed at the
cursors. The heads of a kept selection are in order, since its ranges are
sorted and apart, so they are the extents an insertion replaces.

- `Target.replaceCarrying extent s before after` is the edit of a command
  that says both selections itself: one transaction that replaces one
  extent and carries `before` and `after` as they are handed in
  (`TextId.replaceCarrying`), and then places `after`. The operations above
  carry the window's selection as it is when they are called. A command
  that has moved the selection since it was called, or that leaves the
  cursor somewhere other than after what it inserted, hands in the
  selection from before the command and the one it leaves, so an undo of
  its step hands back the cursor the user saw and a redo the one the
  command left.

## Undo

The undo operations work over the buffer's own undo tree
(`Buffer.history`, `Editor/UndoTree.lean`), with no new request of the
text store: each reads the buffer, tells the tree the revision its text is
at, does its part, and records the tree that comes back as the buffer's
(`StateRequest.setHistory`).

- `BufferId.closeGroup` sets the boundary: the edits since the last one
  become one step. With nothing pending it makes no node.
- `BufferId.undo` and `BufferId.redo` move one step, with the user's
  origin, and hand back the selection to place (`Undone`): the selection
  before the step's first edit for an undo, and the one after its last for
  a redo. `none` is the tree's "there is nothing to do": an undo at the
  root, a redo with no step to go to or with an edit pending.
- **The selection is handed back, not placed.** Placing it is the
  caller's: which view it belongs to, and what its cursor's shape becomes,
  are the input scheme's to say. The store hands back a selection only for
  an edit that carried one, which the selection edits above do.
- **The loop's boundary still follows.** The loop closes each buffer's
  group after every event (`Editor/Loop.lean`, "After each event"). After a
  command that moved, that tells the moved tree nothing new and makes no
  node, so a move is not itself a step.
- **But inside an insert session the loop sets no boundary.** While the
  input scheme reports a view of the buffer as in an insert session, the
  loop leaves the buffer's group open, and closes it once no view of the
  buffer is in one: everything edited meanwhile is one step
  (`Editor/Loop.lean`, "Insert sessions"). A command that wants a boundary
  inside a session sets it itself (`BufferId.closeGroup`), and an undo
  inside one closes the open group first, as always.
- **A command that sets a boundary and then fails** is rolled back whole,
  from the tree the buffer had before it: the edits before the boundary
  and after it are taken back, and the steps the command closed are not in
  the history (`Editor/Loop.lean`, "Rollback").
- **A command that moves and then fails** is rolled back from the tree it
  recorded: the edits it made after the move are taken back, and the move
  is not (`Editor/Loop.lean`, "Rollback").
- `BufferId.isModified` says whether the buffer's text is in another state
  than the one last saved. It tells the tree the text's revision first, so
  an edit made earlier in the same command counts. A question of the state
  alone (`Buffer.isModified` on a buffer read from `editorState`) answers
  for the revision the tree was last told, which is the text's after each
  event and may not be in the middle of a command.

## Windows

Each operation is a request over the layout operations of
`Editor/State.lean`, which keep the layout invariants, and is refused, as
a value, with their `LayoutRefusal`.

- `ViewId.split view axis` makes a new window on the same buffer, below
  the view for `Axis.rows` and to its right for `Axis.columns`, and returns
  its view. The new window has markers of its own: copies, marked on the
  buffer's text, of the source window's scroll anchor and selection as
  they are. The focus stays.
- `ViewId.close` removes a window. The last one is refused (`onlyWindow`).
  Closing the view a split made gives back the tree from before the split.
  The window's markers are given up by the loop once the command has run
  to its end (`Editor/Loop.lean`, "What a finished command gave up").
- `ViewId.focus` focuses a window.
- `ViewId.show view buffer` has the window show another buffer, with a
  scroll anchor at that buffer's start and one cursor at its start, of the
  shape the window's selection had. Showing the buffer the window already
  shows changes nothing and marks nothing. The markers the window had are
  given up by the loop, as a closed window's are.

A view's id is never used again (`Editor/State.lean`).

## Scrolling

A window's scroll position is an anchor marker of its buffer's text
(`Window.scroll`): the view shows the text from the visual row that holds
it. Where the anchor goes is a policy over the display's two queries, in
`Editor/Scroll.lean`; what a command needs to read it, place it and ask
about its view is here.

- `Target.anchor` reads the window's scroll anchor: its offset in the text
  as it is now, and its bias. It is refused with `noSuchMarker` when the
  marker was given up or is no anchor.
- `Target.scrollTo offset` places it there, with the bias `before`, which
  is the bias every window's scroll anchor is made with: text inserted at
  the first row's start is then in view. It is refused with `badPosition`
  for an offset that is not a position.
  - **Placing a marker is no edit**: no revision, no step of the history,
    and the view keeps its snapshot. An edit above the view moves the
    anchor with the text, which is what keeps the view on the same rows.
  - **A command that scrolls and fails is rolled back**: the loop keeps and
    places back each window's scroll marker (`Editor/Loop.lean`,
    "Rollback").
- `Target.onArea run` runs `run` with what the display is asked about the
  view with (`Scroll.Area`): a snapshot of the buffer's text, taken there,
  and the view's rectangle and padding, read from the state
  (`EditorState.rect?`, `EditorState.paddingOf`). So
  a command asks which rows its view shows (`Scroll.Area.rows`) and where
  a position goes by rows (`Display.linesFrom`) of the text as its own
  edits have left it.
  - **The snapshot is released when `run` has ended**, also when it was
    refused, and the refusal is then thrown. The rule is
    `TextId.withSnapshot`'s (`Editor/Command.lean`, "A snapshot round a
    command's questions"), which this calls once it has the rectangle.
    The save command takes and releases a snapshot the same way.
  - **A command that is interrupted, gives up or breaks off inside `run`
    leaves the snapshot**: the loop ends a command's program at that
    request, and a snapshot a command took is not undone
    (`Editor/Loop.lean`, "Rollback", "What is not undone"). It is one
    shared version of the text, held until the store is dropped.
  - **`none`, with nothing taken and nothing run**, for a view that is not
    laid out: one whose window is not in the frame's tree.
  - Not done: handing a command the last scene's snapshot. It is stale
    once the command, or one run before it in the same step, has edited
    the text.

Each makes a text request, and each has a case in `Editor/Api/Cases.lean`.

- `setScrollMargin rows` sets the scroll margin: how many rows every view
  keeps between its cursor's row and the first and the last row it shows
  (`Editor/State.lean`, "The scroll margin"; Vim's `scrolloff`). The loop
  holds it from the next scene on. A command reads it from the state
  (`EditorState.scrollMargin` on `editorState`).
  - **It is never refused**: any number is taken, and a view keeps at most
    half the rows it fits, or as many as its text has where it shows the
    whole text.
  - **It is editor state**, so a command that sets it and then does not
    run to its end leaves the margin there was, and a reload leaves it.
  - It makes no request of the library. Pinned by
    `ModelTest.apiStateChecks`.

## Buffer-local values, modes and the wanted column

These are Lean state alone: none makes a request of the library, so none
has a case on the real binding. They are pinned once, on the models
(`ModelTest.apiStateChecks`, `ModelTest.modeEnterChecks`).

- `ViewId.setWanted view wanted` has the view's window keep a wanted
  column, the column its vertical motions aim for, with the offset the
  cursor was left at, or none (`Editor/State.lean`, "The wanted column").
  The column is a goal the display passed back, or the line's end: a
  command gets a goal from the display (`Display.linesFrom`) and does not
  make one up from a count of characters. A command reads it from the state (`EditorState.window?` on
  `editorState`), which has what the command's own requests have left. Its
  target's window (`Target.window.wanted`) has the column kept when the
  command was called.
- `BufferId.setValue id name value` has a buffer keep a plain tree
  (`Value`, `Editor/Value.lean`) under a name, in place of the one the name
  had, and `BufferId.value?` reads it.
- `BufferId.addMinorMode` and `BufferId.removeMinorMode` add and remove a
  minor mode. No action runs.
- `ViewId.setMajorMode view name` makes a mode the major mode of the buffer
  the view shows, and says whether it became it: `false`, with nothing
  run, when the buffer already had it. The loop that runs the command
  refuses a name no mode is registered under (`noSuchMode`) and runs the
  on-enter actions of the mode's lineage, root first, inside the command
  (`Editor/Command/Dispatch.lean`).

## Messages

`message text` puts `text` in the echo area. The loop clears the echo area
when an invocation runs, so a command's message is in the scene published
after it and stays until the next invocation; a key that yields nothing
leaves it. Of two messages in one command the last is the one shown: the
echo area is one text, and there is no log of messages. A command that
does not run to its end leaves no message: the echo area then says what
became of it (`Editor/Loop.lean`, "Running an invocation"). Pinned by
`ModelTest.loopChecks`.

## Giving up

`giveUp reason` ends the command there: it found that what it was asked
cannot be done (`docs/design/concurrency.md`, "Foreground: commands").

- **Its type is `EditorM α` for any `α`**, so it stands wherever a value
  is wanted: nothing after it runs.
- **The loop rolls the command back** to the texts, the markers and the
  editor state from before it, as it rolls back one that was refused, and
  the echo area reads `<name>: <reason>`, with no `refused:`
  (`Editor/Loop.lean`, "Running an invocation"). The input scheme goes
  back to its state at rest, so a key that entered a state of the scheme's
  has not entered it.
- **It cannot be caught.** It makes one state request
  (`StateRequest.giveUp`), at which the loop ends the command's program
  (`Editor/Command/Dispatch.lean`, "A command that gives up"). Nothing is
  thrown, so a `try` round the call does not go on.
- **Run where no loop dispatches the command** it is refused, with
  `badSelection`: the runners' handler changes nothing, and a command run
  bare finds an editor with nothing in it to act on.
- **A message is not this.** A command that says why it did nothing and
  returns ran to its end: what it did so far stays, and a key that entered
  a state has entered it. Give up when the call must leave no trace.

## Breaking off

`breakOff reason` ends the command there too, and keeps what it did: it
found that what its key stands for cannot be done, after doing something
that is to stay. It is how evil's operate command leaves the cursor where a
motion got to before it failed, with the operator cancelled
(`Editor/Evil/Operators.lean`).

- **Its type is `EditorM α` for any `α`**, and it cannot be caught, as
  `giveUp` cannot: it makes one state request (`StateRequest.breakOff`),
  at which the loop ends the command's program
  (`Editor/Command/Dispatch.lean`, "A command that breaks off").
- **The loop rolls nothing back.** The texts, the markers and the editor
  state the command reached are kept, as a finished command's are, and
  what it asked to be started or run after it is handed back. The echo
  area reads `<name>: <reason>`, in place of what the command said.
- **The input scheme goes back to its state at rest**, as after a command
  that gave up: a key that entered a state of the scheme's has not entered
  it, and its edit is not the last change. So the command leaves the
  selection as the state the view was in before the key has it.
- **Run where no loop dispatches the command** it is refused, with
  `badSelection`, as `giveUp` is.

It makes no request of the library. Pinned by
`ModelTest.dispatchStateChecks` and `ModelTest.dispatchCommandGivesUpChecks`.

## Registers

`setRegister name register` keeps a register, a text and whether it is
whole lines, under a name, in place of the register the name had
(`Editor/State.lean`, "Registers"). A command reads one from the state
(`EditorState.register?` on `editorState`), which has what the command's
own requests have left.

- **It is never refused**: a name is any string. Which names mean
  something is the rule of the commands that set and read them.
- **A register is editor state**, so a command that sets one and then
  does not run to its end leaves the register the name had
  (`Editor/Loop.lean`, "Rollback").
- It makes no request of the library. Pinned by
  `ModelTest.apiStateChecks`, and the rollback by
  `ModelTest.dispatchRollbackChecks`.

`setLastFind find` keeps the last character find, which `;` and `,` repeat
(`Editor/State.lean`, "The last find"), in place of the one there was. It
is set as a register is: never refused, editor state that a command which
does not run to its end leaves as it was, and no request of the library.
A command reads it from the state (`EditorState.lastFind` on
`editorState`). Pinned through evil's character finds by
`ModelTest.evilFindChecks`. `setLastSearch search` keeps the last search
the same way (`Editor/State.lean`, "The last search"), which `n` and `N`
repeat and the loop draws the matches of; pinned through evil's searches
by `ModelTest.evilSearchChecks`.

## Ex bindings

`exBinding name` asks which command the ex name `name` is bound to, and
what the name takes (`Ex.Binding`, `Editor/Ex/Line.lean`). The loop that
runs the command answers from the registry as it is at that step
(`Editor/Command/Dispatch.lean`); `none` is a name nobody bound. It is how
the ex command (`Editor/Ex.lean`) finds what a line runs: a command is a
program over the editor's port and cannot hold the registry.

## Running another command

`invoke invocation` asks for an invocation to be run once this command has
run to its end, as a step of its own, before the next event
(`Editor/Loop.lean`, "Prompts"). The command is looked up when its step
runs, and a name no command is registered under is said then. A command
that does not run to its end has nothing run after it. It is the way to
have another command run for what the other command is: one that writes a
store has its write written back, and its failure is said under its own
name. Pinned by `ModelTest.promptChecks`.

`runCommand name call` has the command registered under `name` run inside
this command, with `call`, and answers whether there was one
(`Editor/Command/Dispatch.lean`, "Requests that name something
registered"; `Editor/Loop.lean`, "A command run inside another").

- **The command is the one a key's invocation of the name runs**, looked
  up in the registry as it is at this step, so config's command of a name
  a compiled command has is the one that runs. A command is a program over
  the editor's port and cannot hold the registry, and no reply can hold a
  command, so the loop runs it.
- **It is part of this command**: one step of the history with it, rolled
  back with it, and said under this command's name when it fails. A
  command run this way that gives up, breaks off or is refused ends this
  command the same way.
- **A command that asks for a store to be written gives this command up**:
  only a command the loop runs has its write written back, so the write
  would be lost.
- **`false`, with nothing run**, for a name no command is registered
  under, and where no loop runs the command.
- It is how evil's dot repeat replays a change (`Editor/Evil/Repeat.lean`).
  Pinned by `ModelTest.dispatchStateChecks` and
  `ModelTest.dispatchRunCommandChecks`.

## Quit

`quit` asks the editor to quit (`docs/design/concurrency.md`, "Quit";
`Editor/State.lean`, "Quit"). A command cannot end the process: it asks,
the loop says stop once the editor can leave, and the host ends its loop.

- **It is refused, as a value, while a buffer that holds a file has
  unsaved changes** (`QuitRefusal.unsaved`, with the name of the first such
  buffer), with nothing asked and the state as it was. The check tells a
  copy of each file-holding buffer's undo tree the revision its text is
  at, as a save does, so an edit made earlier in the same command counts.
  What the text store refuses there is thrown, as everywhere.
- **A buffer with no file never blocks**: it cannot be saved, so a rule
  that counted it would leave no way to quit once anything was typed in
  the scratch buffer.
- **A save in flight does not refuse it.** A buffer whose text is in the
  state its save in flight is writing has no unsaved changes; the editor
  is asked, and leaves once that save's result has been delivered. A
  buffer edited since its save began has unsaved changes.
- It makes one text request for each buffer that holds a file, so it has
  a case in `Editor/Api/Cases.lean`. Its rules are pinned by
  `ModelTest.apiStateChecks`.

## Reload

`reloadConfig` asks for the config to be reloaded. The request is kept
until the command has run to its end, and the loop then hands it to its
host, which asks its config session (`Editor/Loop.lean`, "Reload from a
command"). The reload runs in the background and is installed between two
later events. A command that is refused or interrupted after asking asks
for none. It makes no request of the library. Pinned by
`ModelTest.dispatchQuitChecks`.

## Themes

`themeNames` answers the names themes are registered under, each once, and
`loadTheme name` asks for the theme of that name to be the theme in force
(`docs/design/text-and-display.md`, "Themes and config"). The request is
kept until the command has run to its end, and the loop then hands it to
its host, which switches the theme with no reload and draws the next scene
in it (`Editor/Loop.lean`, "A theme switch from a command"). A name no theme
is registered under is refused as a value (`noSuchTheme`), when the command
asks, and nothing changes; a command that is refused or interrupted after
asking loads none. Neither makes a request of the library. Pinned by
`ModelTest.dispatchStateChecks` and `ModelTest.dispatchQuitChecks`.

## Jobs

`startJob name arguments` asks for the job registered under `name` to be
started with `arguments`, plain values (`Argument`). A command cannot wait,
so what the job computes comes back later, as the command the job's handler
makes of it, which the loop runs like any command, after whatever events
arrived before it (`Editor/Loop.lean`, "Jobs from commands").

- **The job is named, not carried.** A request of the editor's port holds
  plain data, and a job ends in a program over that port. A job that takes
  arguments is registered with `jobWith` (`Editor/Setup.lean`).
- **A name no job is registered under is refused**, as a value
  (`noSuchJob`), when the command asks.
- **The job is started once the command has run to its end**, for whoever
  registered it. A command that is refused or interrupted after asking
  starts no job.

Pinned by `ModelTest.driverChecks`.

## Prompts

A command asks for a string without waiting for it
(`docs/design/concurrency.md`, "Prompts").

- `prompt label continuation initial` opens a prompt and returns the
  minibuffer's view at once: a new text holding `initial`, empty by
  default, a buffer over it with the minibuffer's mode, and a window on
  it, with a scroll anchor at the start and one exclusive cursor after the
  initial value, which has the focus (`Editor/State.lean`, "Prompts"). The
  asking command runs to its end like any command.
- **The continuation is an invocation**: the name of the command that
  receives the answer, and plain arguments of the asker's own. When the
  prompt is accepted that command is run with the answer, a string, as its
  first argument and the continuation's own after it. The name is looked
  up then, not here.
- **One prompt at a time.** Asking while a prompt is open is refused, as a
  value, with `alreadyOpen` and the open prompt's view. The state is read
  first, so the refusal makes no text. A command run where no window is
  focused is refused with `noWindow`.
- **A prompt may be asked with candidates**, strings the answer may be
  chosen from: `prompt label continuation initial (candidates := …)`.
  - **They come from a function**: a program over the editor's port that
    answers the strings. It may ask what a command may: the state, a text.
    It has no `IO` and cannot wait. A list that needs the file system is
    made by a job, whose command asks with the result
    (`candidates := pure names`).
  - **It is run once, by `prompt`**, inside the asking command: after the
    two refusals above, which run nothing, and before the minibuffer's
    text is made. What it answers is kept by the open prompt, as plain
    data (`Editor/State.lean`, "Prompts"). If it is refused, the asking
    command is refused, like any command, and no prompt opens.
  - **The list is then fixed**, but for `setCandidates`, which replaces an
    open prompt's candidates and forgets what it has listed and chosen. It
    is refused, as a value, with `notOpen` when no prompt is open.
  - A prompt asked with none, the default, makes the requests it made
    before there were candidates.
  - **The loop lists them**, before each scene: the candidates the
    minibuffer's text matches, in the fuzzy matcher's order
    (`Editor/Loop.lean`, "Prompts"). `chooseCandidate step` moves a choice
    through that listing, one step forward or back, with "nothing chosen"
    as one stop of the round, and leaves the minibuffer's text as it is.
    With nothing listed it changes nothing; with no prompt open it is
    refused, as a value, with `notOpen`.
- `acceptPrompt` reads the minibuffer's text and makes one state request
  that closes the prompt with the answer
  (`StateRequest.closePrompt`): the minibuffer's window is closed, the
  focus goes back to the asking view, and the continuation is recorded
  with the answer. `cancelPrompt` makes that request with no answer, and
  nothing else: no request of the library, so it cannot be interrupted or
  refused by the store. With no prompt open each is refused, as a value,
  with `notOpen`.
- **The answer** is `Candidates.answer` of the text read
  (`Editor/State.lean`, "Prompts"):
  - **a candidate is chosen**, and the prompt's listing is for the text
    read: that candidate;
  - **nothing is chosen**, whatever is listed: the text. So a user who
    types and accepts gets what was typed, with or without candidates;
  - **nothing matches**: nothing can be chosen, so the text;
  - **a choice made for another text** than the one read is not taken:
    that can only be a command that changed the minibuffer and accepted in
    one step, and it gets the text.
- **The answer's command runs after the accepting command has ended**, as
  a step of its own (`Editor/Loop.lean`). The loop gives up the
  minibuffer's markers and releases its text then too, by its rule for
  any window that was closed and any buffer that was removed; a command
  that accepts and then fails is rolled back with the prompt open and its
  text as typed.
- **The minibuffer's window is not a window command's.** `ViewId.split`,
  `ViewId.close` and `ViewId.show` on it, and `ViewId.show` of the
  minibuffer's buffer in another view, are refused with `ofMinibuffer` and
  the minibuffer's view, with no marker made. `ViewId.focus` takes it, so
  the focus can leave the minibuffer and come back.

## Files

Opening a file and saving a buffer are not operations here: each is a
command that starts a job, in `Editor/Files.lean` (`Files.open`,
`Files.save`), written over this API. What they need of the editor state is
here:

- `BufferId.attachFile` has a buffer hold a file ("Buffers", above).
- `BufferId.beginSave id snapshot state` records a save of the buffer as
  in flight, with the snapshot it writes and the state the text was in,
  and `BufferId.endSave id snapshot stamp` ends it with what the save
  answered: with a stamp, the buffer's file has it and that state is the
  one marked as saved; with none, neither changes, and a quit that was
  asked is withdrawn (`Editor/State.lean`, "A buffer's file" and "Quit"). The loop releases the snapshot once the command that
  ended the save has run to its end. A command that is not a save has no
  use for either.
- `BufferId.isModified` ("Undo", above) and `insertLineBreak`
  ("Selections", above) read what a file left with its buffer: the saved
  state and the line ending.

The three state requests ask the library nothing, and are pinned once, on
the models (`ModelTest.stateRequestChecks`, `ModelTest.fileCommandChecks`).

Each operation that makes a text request has a case in
`Editor/Api/Cases.lean`, played on the editor's models and on the real
binding.
-/

namespace Editor

/-- Makes one request of the editor state and returns its reply. It is never
refused: a reply that can be is an `Except`, a value. -/
def EditorState.ask (request : StateRequest) : EditorM request.Reply :=
  ExceptT.lift (Program.request (port := editorPort) (.state request))

/-- The whole editor state, as it is now. -/
def editorState : EditorM EditorState :=
  EditorState.ask .read

/-- Puts `text` in the echo area, in place of what was there: it is in the
scene published after the command, until the next invocation. -/
def message (text : String) : EditorM Unit :=
  EditorState.ask (.message text)

/-- Ends the command here, with `reason` ("Giving up", in the module docs):
the loop that runs the command rolls it back and says `<name>: <reason>` in
the echo area, and nothing after this runs, a `catch` round it included.
Run where no loop dispatches the command it is refused with
`badSelection`. -/
def giveUp {α : Type} (reason : String) : EditorM α := do
  EditorState.ask (.giveUp reason)
  throw .badSelection

/-- Ends the command here, with `reason`, and keeps what it did ("Breaking
off", in the module docs): the loop that runs the command rolls nothing
back, says `<name>: <reason>` in the echo area and puts the input scheme
back in its state at rest, and nothing after this runs, a `catch` round it
included. Run where no loop dispatches the command it is refused with
`badSelection`. -/
def breakOff {α : Type} (reason : String) : EditorM α := do
  EditorState.ask (.breakOff reason)
  throw .badSelection

/-- Keeps `register` under `name`, in place of the register the name had
("Registers", in the module docs). It is never refused, and makes no
request of the library. -/
def setRegister (name : String) (register : Register) : EditorM Unit :=
  EditorState.ask (.setRegister name register)

/-- Keeps `find` as the last character find, which `;` and `,` repeat
(`Editor/State.lean`, "The last find"). It is never refused, and makes no
request of the library. -/
def setLastFind (find : Find) : EditorM Unit :=
  EditorState.ask (.setLastFind find)

/-- Keeps `search` as the last search, which `n` and `N` repeat
(`Editor/State.lean`, "The last search"). It is never refused, and makes no
request of the library. -/
def setLastSearch (search : Search) : EditorM Unit :=
  EditorState.ask (.setLastSearch search)

/-- Keeps `rows` rows between every view's cursor's row and the first and
the last row it shows, from the next scene on ("Scrolling", in the module
docs). It is never refused, and makes no request of the library. -/
def setScrollMargin (rows : Nat) : EditorM Unit :=
  EditorState.ask (.setScrollMargin rows)

/-- Asks for the job registered under `name` to be started with
`arguments`, once this command has run to its end. Its result comes back
later, as the command its handler makes. Refused with `noSuchJob` for a
name no job is registered under. -/
def startJob (name : String) (arguments : List Argument := []) : EditorM (Except JobRefusal Unit) :=
  EditorState.ask (.startJob name arguments)

/-- The ex binding of the ex name `name`: the command a line of that name
runs, and what the name takes (`Ex.Binding`, `Editor/Ex/Line.lean`). `none`
for a name nobody bound, and where no loop runs the command. -/
def exBinding (name : String) : EditorM (Option Ex.Binding) :=
  EditorState.ask (.ex name)

/-- The ex names that are bound, each once, in the order they were first
bound. None where no loop runs the command. -/
def exNames : EditorM (Array String) :=
  EditorState.ask .exNames

/-- The names themes are registered under, each once, in the order they
were first registered ("Themes", in the module docs). None where no loop
runs the command. -/
def themeNames : EditorM (Array String) :=
  EditorState.ask .themeNames

/-- Asks for the theme registered under `name` to be the theme in force,
once this command has run to its end ("Themes", in the module docs).
Refused with `noSuchTheme` for a name no theme is registered under. -/
def loadTheme (name : String) : EditorM (Except ThemeRefusal Unit) :=
  EditorState.ask (.loadTheme name)

/-- Has the command registered under `name` run inside this command, with
`call`, and answers whether there was one ("Running another command", in
the module docs): the command is the one a key's invocation of the name
runs, and it is part of this command. `false`, with nothing run, for a
name no command is registered under, and where no loop runs the
command. -/
def runCommand (name : String) (call : Call) : EditorM Bool :=
  EditorState.ask (.runCommand name call)

/-- Asks for `invocation` to be run once this command has run to its end, as
a step of its own, before the next event: the command is looked up then,
and is run as any command is, with the window that is then focused. A
command that does not run to its end has nothing run after it. -/
def invoke (invocation : Invocation) : EditorM Unit :=
  EditorState.ask (.invoke invocation)

/-- Whether the buffer `id` has unsaved changes (`Buffer.unsavedAt`): it
holds a file, and its text is in another state than the one last saved and
than the one a save in flight writes, by a copy of its undo tree told the
revision its text is at, so an edit made earlier in the same command
counts. A buffer with no file has none, and its text is not asked. Refused
with `noSuchBuffer` for a buffer there is none of. -/
def BufferId.hasUnsavedChanges (id : BufferId) : EditorM (Except BufferRefusal Bool) := do
  let some buffer := (← editorState).buffer? id | return .error (.noSuchBuffer id)
  -- A buffer with no file never has: it cannot be saved.
  if buffer.file.isNone then
    return .ok false
  return .ok (buffer.unsavedAt (← buffer.history.sync))

/-- Why the editor was not asked to quit. -/
inductive QuitRefusal where
  /-- The buffer called `name`, which holds a file, has unsaved changes. -/
  | unsaved (name : String)
  deriving DecidableEq, Repr

/-- Asks the editor to quit ("Quit", in the module docs). Refused, with
nothing asked, with `unsaved` and the name of the first buffer that holds a
file and has unsaved changes, by its history once told the revision its
text is at, so an edit made earlier in the same command counts. -/
def quit : EditorM (Except QuitRefusal Unit) := do
  let state ← editorState
  for index in List.range state.buffers.size do
    let some buffer := state.buffer? ⟨index⟩ | continue
    if let .ok true← (⟨index⟩ : BufferId).hasUnsavedChanges then
      return .error (.unsaved buffer.name)
  return .ok (← EditorState.ask .quit)

/-- Asks for the config to be reloaded, once this command has run to its
end ("Reload", in the module docs). The reload runs in the background and
is installed between two events; a command that does not run to its end
asks for none. -/
def reloadConfig : EditorM Unit :=
  EditorState.ask .reload

/-- Asks for a string: opens a prompt labelled `label`, whose minibuffer
holds `initial`, with the cursor after it, and returns the minibuffer's
view at once ("Prompts", in the module docs). When the prompt is accepted,
the command of `continuation` is run with the answer as its first
argument, before the continuation's own. Refused, with no text made, with
`alreadyOpen` while a prompt is open, and with `noWindow` where no window
is focused to ask from.

`candidates` answers the strings the answer may be chosen from, none by
default. It is run once, after those two refusals and before the
minibuffer's text is made, and what it answers is kept by the prompt; if it
is refused, so is this command, with no prompt open. -/
def prompt (label : String) (continuation : Invocation) (initial : String := "")
    (candidates : EditorM (Array String) := pure #[]) : EditorM (Except PromptRefusal ViewId) := do
  let state ← editorState
  if let some asked := state.prompt then
    return .error (.alreadyOpen asked.view)
  if state.focusedTarget?.isNone then
    return .error .noWindow
  let all ← candidates
  let text ← createText initial
  let scroll ← text.mark (.anchor { offset := 0, bias := .before })
  let cursor := initial.utf8ByteSize
  let selection ← text.mark (.selection { ranges := #[⟨cursor, cursor⟩], shape := .exclusive })
  let opened ←
    EditorState.ask (.openPrompt label continuation text (← UndoTree.over text) scroll selection)
  -- A prompt with no candidates makes no request for them.
  if opened.isOk && !all.isEmpty then
    discard <| EditorState.ask (.setCandidates all)
  return opened

/-- Replaces the open prompt's candidates with `all`, and forgets what it
has listed and chosen ("Prompts", in the module docs). Refused with
`notOpen` when no prompt is open. -/
def setCandidates (all : Array String) : EditorM (Except PromptRefusal Unit) :=
  EditorState.ask (.setCandidates all)

/-- Moves the open prompt's choice by `step` through the candidates it has
listed ("Prompts", in the module docs): from nothing chosen to the first or
the last, from the last onward and from the first backward to nothing
chosen, and otherwise by one. With nothing listed it changes nothing. The
minibuffer's text is not changed. Refused with `notOpen` when no prompt is
open. -/
def chooseCandidate (step : Candidates.Step) : EditorM (Except PromptRefusal Unit) :=
  EditorState.ask (.chooseCandidate step)

/-- Accepts the open prompt: it is closed, and its continuation's command is
run with the answer once this command has run to its end ("Prompts", in
the module docs). The answer is the chosen candidate, when one is chosen
and the prompt's listing is for the text of its minibuffer, and otherwise
that text (`Candidates.answer`). Refused with `notOpen` when no prompt is
open. -/
def acceptPrompt : EditorM (Except PromptRefusal Unit) := do
  let state ← editorState
  let some asked := state.prompt | return .error .notOpen
  let some minibuffer := state.target? asked.view | return .error .notOpen
  let text ← minibuffer.buffer.text.read
  EditorState.ask (.closePrompt (some (asked.candidates.answer text)))

/-- Cancels the open prompt: it is closed, and its continuation does not
run. It makes one request of the editor state and none of the library.
Refused with `notOpen` when no prompt is open. -/
def cancelPrompt : EditorM (Except PromptRefusal Unit) :=
  EditorState.ask (.closePrompt none)

/-- Replaces the bytes of `text` from `start` up to, not including, `stop`
with `s`, as one transaction made by the user. Refused, changing nothing,
with `badChange` unless both offsets are character boundaries within the
text and `start ≤ stop`. -/
def TextId.replaceRange (text : TextId) (start stop : Nat) (s : String) : TextM Unit := do
  let length ← text.byteLength
  let _ ← text.apply (Transaction.replacing length start stop s) Origin.user
  return ()

/-- Replaces `extent` of `text` with `s`, as one transaction made by the
user that carries `before`, a selection of the text as it is, and `after`,
one of the text the edit leaves. An undo of the edit hands `before` back,
and a redo `after`. Refused, changing nothing, as the store refuses the
transaction: with `badChange` unless the extent's ends are character
boundaries within the text, in order, and with `badSelection` for a
selection that is none of its text. -/
def TextId.replaceCarrying (text : TextId) (extent : Extent) (s : String)
    (before after : Selection) : TextM Unit := do
  let length ← text.byteLength
  let _ ←
    text.apply
        { Transaction.replacing length extent.start extent.stop s with
          before := some before, after := some after }
        Origin.user
  return ()

/-- The buffer called `name`, if there is one. -/
def findBuffer (name : String) : EditorM (Option BufferId) :=
  return (← editorState).findBuffer name

/-- Makes a buffer called `name` over `text`, a text the command already
has, with a new undo tree over it, and returns its id. Refused with
`nameTaken` for a name a buffer already has. -/
def addBuffer (name : String) (text : TextId) : EditorM (Except BufferRefusal BufferId) := do
  EditorState.ask (.addBuffer name text (← UndoTree.over text))

/-- Makes a buffer called `name` over a new text holding `contents`, and
returns its id. Refused with `nameTaken` for a name a buffer already has,
with no text made. -/
def createBuffer (name : String) (contents : String := "") :
    EditorM (Except BufferRefusal BufferId) := do
  if (← findBuffer name).isSome then
    return .error (.nameTaken name)
  addBuffer name (← createText contents)

namespace BufferId

/-- The text of the buffer `id`. Refused with `noSuchBuffer` for a buffer
there is none of. -/
def text (id : BufferId) : EditorM (Except BufferRefusal TextId) := do
  match (← editorState).buffer? id with
  | some buffer =>
    return .ok buffer.text
  | none =>
    return .error (.noSuchBuffer id)

/-- Removes the buffer `id`. Refused with `noSuchBuffer` for a buffer there
is none of, and with `shown` while a window shows it. -/
def remove (id : BufferId) : EditorM (Except BufferRefusal Unit) :=
  EditorState.ask (.removeBuffer id)

/-- Gives the buffer `id` the name `name`; its own name changes nothing.
Refused with `noSuchBuffer` for a buffer there is none of, and with
`nameTaken` for a name another buffer has. -/
def rename (id : BufferId) (name : String) : EditorM (Except BufferRefusal Unit) :=
  EditorState.ask (.renameBuffer id name)

/-- Has the buffer `id` hold the file at `path`, whose stamp is `stamp`,
with `ending` as the buffer's line ending. Refused with `noSuchBuffer` for a
buffer there is none of, and with `fileOpen` for a path another buffer
holds. -/
def attachFile (id : BufferId) (path : System.FilePath) (stamp : File.Stamp)
    (ending : File.LineEnding) : EditorM (Except BufferRefusal Unit) :=
  EditorState.ask (.attachFile id path stamp ending)

/-- Records a save of the buffer `id` as in flight: it writes `snapshot`,
which the command took with the buffer's text in the state `saved`. Refused
with `noSuchBuffer` for a buffer there is none of, with `noFile` for a
buffer that shows no file, and with `beingSaved` while a save of it is in
flight. -/
def beginSave (id : BufferId) (snapshot : SnapshotId) (saved : UndoTree.State) :
    EditorM (Except BufferRefusal Unit) :=
  EditorState.ask (.beginSave id snapshot saved)

/-- Ends the save of the buffer `id` that writes `snapshot`, with the stamp
of the file it wrote, or with `none` for a save that was refused: the save
is no longer in flight, and with a stamp the buffer's file has it and the
state the save kept is the one marked as saved, and with none the editor
is no longer asked to quit. The loop releases the
snapshot once this command has run to its end. Refused with `noSuchBuffer`
for a buffer there is none of, and with `notBeingSaved` unless a save of
the buffer that writes `snapshot` is in flight. -/
def endSave (id : BufferId) (snapshot : SnapshotId) (stamp : Option File.Stamp) :
    EditorM (Except BufferRefusal Unit) :=
  EditorState.ask (.endSave id snapshot stamp)

/-- Records what a check of the buffer `id`'s file found, if its stamp is
still `stamp` (`EditorState.markChanged`): the mark is cleared when `found` is
`stamp`, and otherwise holds `found`, `none` for a file that is gone, told
or not. Refused with `noSuchBuffer` for a buffer there is none of. -/
def markChanged (id : BufferId) (stamp : File.Stamp) (found : Option File.Stamp) (told : Bool) :
    EditorM (Except BufferRefusal Unit) :=
  EditorState.ask (.markChanged id stamp found told)

/-- Marks the change on disk of the buffer `id`'s file as told, so its next
edit lands. Refused with `noSuchBuffer` for a buffer there is none of. -/
def tellChanged (id : BufferId) : EditorM (Except BufferRefusal Unit) :=
  EditorState.ask (.tellChanged id)

/-- Replaces the bytes of the buffer `id`'s text from `start` up to, not
including, `stop` with `s` (`TextId.replaceRange`). Refused with
`noSuchBuffer` for a buffer there is none of; what the store refuses is
thrown. -/
def replaceRange (id : BufferId) (start stop : Nat) (s : String) :
    EditorM (Except BufferRefusal Unit) := do
  match ← id.text with
  | .ok text =>
    text.replaceRange start stop s
    return .ok ()
  | .error refusal =>
    return .error refusal

/-- Inserts `s` into the buffer `id`'s text at the byte offset `offset`.
Refused with `noSuchBuffer` for a buffer there is none of; the store
refuses, with `badChange`, an offset that is not a character boundary
within the text. -/
def insertAt (id : BufferId) (offset : Nat) (s : String) : EditorM (Except BufferRefusal Unit) :=
  id.replaceRange offset offset s

/-- Deletes the bytes of the buffer `id`'s text from `start` up to, not
including, `stop`. Refused with `noSuchBuffer` for a buffer there is none
of; the store refuses, with `badChange`, offsets that are not character
boundaries within the text and a range that ends before it starts. -/
def deleteRange (id : BufferId) (start stop : Nat) : EditorM (Except BufferRefusal Unit) :=
  id.replaceRange start stop ""

end BufferId

/-- What an undo or a redo hands back. -/
structure Undone where
  /-- The selection to place: the one before the step's first edit for an
  undo, and the one after its last for a redo. `none` when the step's edits
  carried none. -/
  selection : Option Selection
  deriving DecidableEq, Repr

namespace BufferId

/-- The buffer `id` with its undo tree told the revision its text is at.
Refused with `noSuchBuffer` for a buffer there is none of. -/
def synced (id : BufferId) : EditorM (Except BufferRefusal Buffer) := do
  match (← editorState).buffer? id with
  | some buffer =>
    return .ok { buffer with history := ← buffer.history.sync }
  | none =>
    return .error (.noSuchBuffer id)

/-- Whether the buffer `id` is modified: whether its text is in another
state than the one last saved, by its history once told the revision the
text is at, so an edit made earlier in the same command counts. Refused
with `noSuchBuffer` for a buffer there is none of. -/
def isModified (id : BufferId) : EditorM (Except BufferRefusal Bool) :=
  return (← id.synced).map (·.isModified)

/-- Sets the boundary in the buffer `id`'s history: the edits since the last
one become one step. With nothing pending it makes no node. A boundary set
by a command that then does not run to its end is taken back with the
command's edits (`Editor/Loop.lean`, "Rollback"). Refused with
`noSuchBuffer` for a buffer there is none of. -/
def closeGroup (id : BufferId) : EditorM (Except BufferRefusal Unit) := do
  match ← id.synced with
  | .ok buffer =>
    EditorState.ask (.setHistory id buffer.history.close)
  | .error refusal =>
    return .error refusal

/-- Makes `move` in the buffer `id`'s history, on its tree once told the
revision its text is at, and records the tree the move returns as the
buffer's: what the move handed back, or `none` when the tree had nothing
to do. Refused with `noSuchBuffer` for a buffer there is none of. -/
def moved (id : BufferId) (move : UndoTree → TextM (Option UndoTree.Moved)) :
    EditorM (Except BufferRefusal (Option Undone)) := do
  match ← id.synced with
  | .error refusal =>
    return .error refusal
  | .ok buffer =>
    let some moved ← move buffer.history | return .ok none
    match ← EditorState.ask (.setHistory id moved.tree) with
    | .ok () =>
      return .ok (some ⟨moved.selection⟩)
    | .error refusal =>
      return .error refusal

/-- Undoes one step of the buffer `id`'s history, with the user's origin,
and hands back the selection from before the step's first edit. The open
group is a step: it is closed first. `none`, with nothing done, when there
is no step to undo. Refused with `noSuchBuffer` for a buffer there is none
of. -/
def undo (id : BufferId) : EditorM (Except BufferRefusal (Option Undone)) :=
  id.moved (·.undo Origin.user)

/-- Redoes one step of the buffer `id`'s history, with the user's origin,
and hands back the selection from after the step's last edit. `none`, with
nothing done, when there is no step to redo, and whenever an edit is
pending. Refused with `noSuchBuffer` for a buffer there is none of. -/
def redo (id : BufferId) : EditorM (Except BufferRefusal (Option Undone)) :=
  id.moved (·.redo Origin.user)

/-- Has the buffer `id` keep `value` under `name`, in place of the value the
name had. Refused with `noSuchBuffer` for a buffer there is none of. -/
def setValue (id : BufferId) (name : String) (value : Value) :
    EditorM (Except BufferRefusal Unit) :=
  EditorState.ask (.setValue id name value)

/-- The value the buffer `id` keeps under `name`, if it keeps one. -/
def value? (id : BufferId) (name : String) : EditorM (Option Value) :=
  return (← editorState).value? id name

/-- Adds the minor mode called `name` to the buffer `id`, first; one it has
already changes nothing. Refused with `noSuchBuffer` for a buffer there is
none of. -/
def addMinorMode (id : BufferId) (name : String) : EditorM (Except BufferRefusal Unit) :=
  EditorState.ask (.addMinorMode id name)

/-- Removes the minor mode called `name` from the buffer `id`; one it does
not have changes nothing. Refused with `noSuchBuffer` for a buffer there is
none of. -/
def removeMinorMode (id : BufferId) (name : String) : EditorM (Except BufferRefusal Unit) :=
  EditorState.ask (.removeMinorMode id name)

end BufferId

/-- The changes that replace each of `extents`, sorted and apart, of a text
of `length` bytes, with `text`, and the cursor after each insertion. -/
def replacingEach (length : Nat) (extents : Array Extent) (text : String) :
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

namespace Target

/-- The selection of `target`'s window, in the form the store keeps one in.
Refused with `noSuchMarker` when the window's selection marker was given
up. -/
def selection (target : Target) : TextM Selection := do
  let .selection selection ← target.buffer.text.marker target.window.selection | throw .noSuchMarker
  return selection

/-- Places `selection` as the selection of `target`'s window. Refused as the
store refuses a selection: with `badSelection` for one that is none or has
an end that is not a position of the text. -/
def select (target : Target) (selection : Selection) : TextM Unit :=
  target.buffer.text.place target.window.selection (.selection selection)

/-- Replaces each of `extents`, sorted and apart, of `target`'s text with
`s`, as one transaction made by the user, which carries `before` and the
cursors after, one after each insertion, with `before`'s shape, and places
the window's selection at those cursors. -/
def replaceExtents (target : Target) (before : Selection) (extents : Array Extent) (s : String) :
    TextM Unit := do
  let text := target.buffer.text
  let (changes, cursors) := replacingEach (← text.byteLength) extents s
  let after : Selection :=
    { ranges := cursors, primary := min before.primary (cursors.size - 1), shape := before.shape }
  let _ ← text.apply { changes, before := some before, after := some after } Origin.user
  target.select after

/-- Replaces `extent` of `target`'s text with `s`, as one transaction made
by the user that carries `before` and `after` (`TextId.replaceCarrying`),
and places `after` as the window's selection. `before` is the caller's to
say: the selection from before its command, whatever the window's is by
now. -/
def replaceCarrying (target : Target) (extent : Extent) (s : String) (before after : Selection) :
    TextM Unit := do
  target.buffer.text.replaceCarrying extent s before after
  target.select after

/-- Replaces what each range of `target`'s selection covers with `s`, as one
transaction made by the user, and leaves a cursor after each insertion. -/
def replaceSelections (target : Target) (s : String) : TextM Unit := do
  let selection ← target.selection
  target.replaceExtents selection (← target.buffer.text.extents selection) s

/-- Inserts `s` at the head of each range of `target`'s selection, as one
transaction made by the user, and leaves a cursor just after each
insertion. -/
def insertAtSelections (target : Target) (s : String) : TextM Unit := do
  let selection ← target.selection
  target.replaceExtents selection (selection.ranges.map fun range => ⟨range.head, range.head⟩) s

/-- Deletes what each range of `target`'s selection covers, as one
transaction made by the user, and leaves a cursor where each started. -/
def deleteSelections (target : Target) : TextM Unit :=
  target.replaceSelections ""

/-- Breaks the line at the head of each range of `target`'s selection, with
its buffer's line ending (`Buffer.lineEnding`): a line feed, or a carriage
return and a line feed, inserted as `insertAtSelections` inserts. A command
that breaks a line at the cursors calls this, and none writes the line
feed itself. -/
def insertLineBreak (target : Target) : TextM Unit :=
  target.insertAtSelections target.buffer.lineEnding.text

/-- The scroll anchor of `target`'s window: where it is in the text as it is
now, and its bias ("Scrolling", in the module docs). Refused with
`noSuchMarker` when the window's scroll marker was given up, or is no
anchor. -/
def anchor (target : Target) : TextM Anchor := do
  let .anchor anchor ← target.buffer.text.marker target.window.scroll | throw .noSuchMarker
  return anchor

/-- Places the scroll anchor of `target`'s window at `offset`, with the bias
`before`: the view shows its text from the row that holds it. It is no
edit. Refused with `noSuchMarker` when the window's scroll marker was given
up, and with `badPosition` for an offset that is not a position of the
text. -/
def scrollTo (target : Target) (offset : Nat) : TextM Unit :=
  target.buffer.text.place target.window.scroll (.anchor { offset, bias := .before })

/-- Runs `run` with what the display is asked about `target`'s view with
(`Scroll.Area`): a snapshot of its buffer's text, taken here, and the
view's rectangle in the frame. The snapshot is released when `run` has
ended, also when it was refused, and its refusal is then thrown: that is
`TextId.withSnapshot` (`Editor/Command.lean`), and this is the rectangle's
lookup and it. `none`, with nothing taken and nothing run, for a view that
is not laid out (`EditorState.rect?`). -/
def onArea {α : Type} (target : Target) (run : Scroll.Area → EditorM α) : EditorM (Option α) := do
  let state ← editorState
  let some rect := state.rect? target.window.id | return none
  -- A window's bottom row is its status row, and the minibuffer's view's
  -- the frame's bottom row (`EditorState.bottomRow`).
  let bottom := state.bottomRow target.window.id
  -- Its padding is the one the scene showing it has (`EditorState.paddingOf`).
  let padding := state.paddingOf target.window.id
  some <$>
      target.buffer.text.withSnapshot fun snapshot => run (.ofRect snapshot rect bottom padding)

end Target

namespace ViewId

/-- The window of `view` and its buffer. Refused with `noSuchWindow` for a
view with no window. -/
def target (view : ViewId) : EditorM (Except LayoutRefusal Target) := do
  match (← editorState).target? view with
  | some target =>
    return .ok target
  | none =>
    return .error (.noSuchWindow view)

/-- Runs `run` on the window of `view` and its buffer. Refused with
`noSuchWindow` for a view with no window; what the store refuses is
thrown. -/
def onTarget {α : Type} (view : ViewId) (run : Target → TextM α) :
    EditorM (Except LayoutRefusal α) := do
  match ← view.target with
  | .ok target =>
    return .ok (← run target)
  | .error refusal =>
    return .error refusal

/-- The selection of the window of `view` (`Target.selection`). -/
def selection (view : ViewId) : EditorM (Except LayoutRefusal Selection) :=
  view.onTarget (·.selection)

/-- Places `selection` as the selection of the window of `view`
(`Target.select`). -/
def select (view : ViewId) (selection : Selection) : EditorM (Except LayoutRefusal Unit) :=
  view.onTarget (·.select selection)

/-- Inserts `s` at the head of each range of the selection of the window of
`view` (`Target.insertAtSelections`). -/
def insertAtSelections (view : ViewId) (s : String) : EditorM (Except LayoutRefusal Unit) :=
  view.onTarget (·.insertAtSelections s)

/-- Deletes what each range of the selection of the window of `view` covers
(`Target.deleteSelections`). -/
def deleteSelections (view : ViewId) : EditorM (Except LayoutRefusal Unit) :=
  view.onTarget (·.deleteSelections)

/-- Breaks the line at the head of each range of the selection of the window
of `view`, with its buffer's line ending (`Target.insertLineBreak`). -/
def insertLineBreak (view : ViewId) : EditorM (Except LayoutRefusal Unit) :=
  view.onTarget (·.insertLineBreak)

/-- Splits the window of `view` along `axis`: a new window on the same
buffer, below it for rows and to its right for columns, whose markers are
copies of the window's scroll anchor and selection as they are, and returns
the new view. The focus stays. Refused with `noSuchWindow` for a view with
no window, and with `ofMinibuffer` for the minibuffer's view, each with no
marker made. -/
def split (view : ViewId) (axis : Axis) : EditorM (Except LayoutRefusal ViewId) := do
  if (← editorState).minibufferView? == some view then
    return .error (.ofMinibuffer view)
  match ← view.target with
  | .error refusal =>
    return .error refusal
  | .ok target =>
    let text := target.buffer.text
    let scroll ← text.mark (← text.marker target.window.scroll)
    let selection ← text.mark (← text.marker target.window.selection)
    EditorState.ask (.split view axis scroll selection)

/-- Closes the window of `view`: its sibling takes the place of the split
that held both. Refused with `noSuchWindow` for a view with no window, with
`ofMinibuffer` for the minibuffer's view, and with `onlyWindow` for the
last window of the tree, which the minibuffer's window does not count
towards. -/
def close (view : ViewId) : EditorM (Except LayoutRefusal Unit) :=
  return (← EditorState.ask (.removeWindow view)).map fun _ => ()

/-- Focuses the window of `view`. Refused with `noSuchWindow` for a view
with no window. -/
def focus (view : ViewId) : EditorM (Except LayoutRefusal Unit) :=
  EditorState.ask (.focus view)

/-- Has the window of `view` show the buffer `buffer`, with a scroll anchor
at its start and one cursor at its start, of the shape the window's
selection had. Showing the buffer the window shows already changes nothing
and marks nothing. Refused with `ofMinibuffer`, and the minibuffer's view,
for the minibuffer's view and for the minibuffer's buffer in another view,
with `noSuchWindow` for a view with no window, and with `noSuchBuffer` for
a buffer there is none of, each with no marker made. -/
def «show» (view : ViewId) (buffer : BufferId) : EditorM (Except LayoutRefusal Unit) := do
  let state ← editorState
  if let some minibuffer := state.minibufferView? then
    if minibuffer == view || state.minibufferBuffer? == some buffer then
      return .error (.ofMinibuffer minibuffer)
  let some target := state.target? view | return .error (.noSuchWindow view)
  if target.window.buffer == buffer then
    return .ok ()
  let some shown := state.buffer? buffer | return .error (.noSuchBuffer buffer)
  let shape := (← target.selection).shape
  let scroll ← shown.text.mark (.anchor { offset := 0, bias := .before })
  let selection ← shown.text.mark (.selection { ranges := #[⟨0, 0⟩], shape })
  EditorState.ask (.show view buffer scroll selection)

/-- Has the window of `view` keep `wanted` as its wanted column, the column
its vertical motions aim for with the offset the cursor was left at, or
none (`Editor/State.lean`, "The wanted column"). It makes one request of
the editor state and none of the library. Refused with `noSuchWindow` for a
view with no window. -/
def setWanted (view : ViewId) (wanted : Option Window.Wanted) :
    EditorM (Except LayoutRefusal Unit) :=
  EditorState.ask (.setWanted view wanted)

/-- Makes the mode called `name` the major mode of the buffer the window of
`view` shows, and says whether it became the major mode: `false`, with
nothing run, when the buffer already had it. When it became it, the
on-enter actions of the mode's lineage have run, root first, before this
returns. Refused with `noSuchWindow` for a view with no window, and with
`noSuchMode` for a name no mode is registered under. -/
def setMajorMode (view : ViewId) (name : String) : EditorM (Except ModeRefusal Bool) :=
  EditorState.ask (.setMajorMode view name)

end ViewId

end Editor
