import Editor.Completion
import Editor.ExcerptView
import Editor.Scroll
import Editor.Store

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
- `createExcerptBuffer name list` makes an excerpt text of `list`, ranges
  of buffers each with a header (`BufferExcerpt`), and an excerpt buffer of
  that name over it (`Editor/State.lean`, "Excerpt buffers"), refused as
  `createBuffer` is and with `noSuchBuffer`. A window shows it like any
  buffer, each header drawn above its excerpt (`Editor/ExcerptView.lean`).
  `createExcerptBufferOf name list headers` makes one of ranges of texts,
  which a text no buffer holds may be among. `BufferId.setExcerpts id list`
  replaces its list and its headers, which is how an emptied excerpt
  goes.
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
  (`TextId.replaceCarrying`), and then places `after`.
  `Target.replaceEachCarrying edits before after` is the same for several
  extents, each with its own string, in one transaction: what `=` does.
  `Target.replaceEach before edits` is `replaceExtents` with a string per
  extent, leaving a cursor after each. The operations above
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
- **An excerpt buffer's undo is its sources'** (`Editor/State.lean`,
  "Excerpt buffers"). `closeGroup`, `undo` and `redo` of an excerpt buffer
  go to `excerptCloseGroup`, `excerptUndo` and `excerptRedo`.
  `excerptCloseGroup` closes the group of each source buffer it touched and
  then makes them one step of its own (`EditorState.closeExcerptGroup`).
  `excerptUndo` closes the group first, then takes the last step: with none
  it answers `none`; when a source buffer of the step was removed, it drops
  each such source from the step, and drops the step once none is left,
  does nothing more, and is refused with `sourceRemoved` and the source's
  name as the step recorded it, so a removed source never blocks the steps
  under it, and the next undo takes what is left; it tells every source
  buffer of the step the revision its text is at and is refused with
  `sourceMoved`, changing nothing, unless each is still in the state the
  step recorded; then it undoes one step in each, with the user's origin,
  and keeps the states each is left in as the step to redo. `excerptRedo`
  is the same over the steps to redo, with nothing pending. Neither hands a
  selection back: the sources' transactions carried none, and a source's
  selection is in its own offsets, so the caller rests the cursor where
  the window's marker moved (`Editor/Evil/Undo.lean`).
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

- `ViewId.split view placement` makes a new window on the same buffer and
  returns its view. Under manual splits the placement says whether it goes
  before the view or after it, and on which axis the view's tile is split;
  under the other layouts it goes right after the view in the frame's
  list, and the layout says where it goes. The new window has markers of
  its own: copies, marked on the buffer's text, of the source window's
  scroll anchor and selection as they are. The focus stays.
- `ViewId.arrange view change` makes a change of the window list or the
  layout's parameters on the view's window (`Arrange`): promote, demote,
  rotate, exchange, zoom, balance, resize and main's count
  (`Editor/State.lean`, "The window list, the layout and their
  invariants").
- `ViewId.close` removes a window: it leaves the list, and the layout gives
  its space to the rest. The last one is refused (`onlyWindow`). Closing
  the view a split made gives back the frame from before the split.
  The window's markers are given up by the loop once the command has run
  to its end (`Editor/Loop.lean`, "What a finished command gave up").
- `ViewId.focus` focuses a window. A window of a hidden tab brings its tab
  into view first (`Editor/State.lean`, "Tabs"), refused with `promptOpen`
  while a prompt is open.
- `ViewId.show view buffer` has the window show another buffer, with a
  scroll anchor at that buffer's start and one cursor at its start, of the
  shape the window's selection had. Showing the buffer the window already
  shows changes nothing and marks nothing. The markers the window had are
  given up by the loop, as a closed window's are. A window of a hidden tab
  shows it there, and the tab in view stays in view.
- `ViewId.newTab view` opens a new tab after the one in view, its one
  window on the view's buffer with markers that are copies of the view's,
  as `split` makes them, and returns its view; the tab in view and the
  focus stay. Focusing the new view brings its tab into view.
- `changeTab change` selects, closes, renames or moves a tab (`TabChange`),
  refused with `noSuchTab`, `onlyTab` (the last tab) and `promptOpen`
  (changing the tab in view while a prompt is open). Closing a tab closes
  every window of it, whose markers the loop gives up.
- `BufferId.display buffer asking opener` shows a buffer a command made
  where config's display rules say (`Editor/DisplayRules.lean`), and
  returns its view: a window that shows it already, else the target of
  the first rule that matches its modes, its name and `opener`, the
  command's name, else a new window at the end of the tiled list, the
  stack. A new window's markers are made as `show` makes them, and only for
  a new window. The window is focused when the rule says so; with no rule
  that matches, when the caller's `focus` says so, `true` unless it is
  given (the compile mode gives `false`, so the focus stays). It reads the
  rules with a state request the loop answers (`.displayRules`). A docked
  window, at an edge (`Frame.docked`), is a window like any other to every
  operation here, and so is a float (`Frame.floats`). A rule's float
  target opens a float centred in the frame; the spot is handed through.
- `BufferId.float buffer at share pinned focus` opens a buffer in a new
  float on top of the others (`Editor/Floating.lean`), placed against
  `at`: the frame, a window, or a byte offset of a window's buffer
  (`Floating.At`), of `share`, pinned or transient, and focused when
  `focus` says, and returns its view. The refusals that apply are checked
  first, so nothing is marked when one does: `ofMinibuffer` for the
  minibuffer's buffer, `noSuchBuffer`, `noSuchWindow` for an anchor
  window that is no tiled or docked window of the frame, and `floating`
  for a float as the anchor window. Then it marks the new window's scroll
  anchor and cursor at the buffer's start, of the shape the anchor
  window's selection has, or the focused window's for the frame, and for a
  position an anchor marker of the anchor window's buffer's text at the
  offset, with the bias `before`; an offset that is not a position is
  refused by the text store, as `Target.scrollTo` is. A transient float
  closes when the focus leaves it or the window it was opened from, or
  when its position scrolls out of its window (`Editor/State.lean`, "A
  floating window"). Completion in a float is to be built on it.

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
- `BufferId.setLanguage id name` records a buffer's language by name, and
  `languageOf path` is the name of the language the registry's table
  chooses for a path (`Editor/Language.lean`), which the loop answers.
  `indentUnitOf name` is the indent unit of the table's entry of a name,
  which the loop answers too, and `Target.indentUnit` the unit of a
  target's buffer's language, four spaces when it has none.
- `ViewId.setMajorMode view name` makes a mode the major mode of the buffer
  the view shows, and says whether it became it: `false`, with nothing
  run, when the buffer already had it. The loop that runs the command
  refuses a name no mode is registered under (`noSuchMode`) and runs the
  on-enter actions of the mode's lineage, root first, inside the command
  (`Editor/Command/Dispatch.lean`). `BufferId.setMajorMode id name` does
  the same for a buffer no window need show: the on-enter actions run
  once with each view that shows it, and with none when no window does.

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
- **A job may be started under a key** (`startJob name arguments (key :=
  some key)`): starting it cancels the running job of that key, so a key
  has at most one job. `cancelJob key` asks for the job of that key to be
  cancelled, once the command has run to its end: it never runs its
  command, even one that has finished and not been delivered. A command
  that is refused or interrupted after asking cancels nothing. It is how
  `:!` keeps one run a workspace and `C-g` ends it (`Editor/Shell.lean`).
- **A job may hand the editor a command while it runs** (`post`,
  `Editor/Job.lean`): an invocation, which its host runs on the editor
  thread with `runPosted`, as a delivery labelled `job <id> <name>`, before
  the job's own command. `runPosted` runs the command registered under the
  invocation's name inside itself, with the focused window and the
  invocation's arguments (`runCommand`), and says `<name>: no such command`
  for a name no command is registered under. It is how a compile streams
  its output into its buffer (`Editor/Compile.lean`).

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
- **A prompt may be asked with candidates**, records the answer may be
  chosen from, from completion sources:
  `prompt label continuation initial (sources := …)`.
  - **A source is a name, a category and a function from a query to
    candidates** (`Editor/Completion.lean`): a program over the editor's
    port, which may ask what a command may, the state, a text, has no
    `IO` and cannot wait. A list that needs the file system is made by a
    job, whose command asks with a source of the result
    (`.given (.ofTexts name category names)`).
  - **It is given as a value or named.** `.given source` is run by
    `prompt`; `.named name` is run by the loop, which looks the name up
    among the registered sources (`StateRequest.askSource`), and a name no
    source is registered under refuses the prompt with `noSuchSource`,
    with no text made.
  - **Each source is asked once, by `prompt`**, in order, inside the
    asking command: after the two refusals above, which run nothing, and
    before the minibuffer's text is made, with the initial text and the
    asking view. What they answer is kept by the open prompt, as plain
    data, each source's candidates in its group unless a candidate names
    its own (`Completion.Candidate.inGroup`; `Editor/State.lean`,
    "Prompts"). If a source is refused, the asking command is refused, like
    any command, and no prompt opens.
  - **A source that answers later** (`Completion.Source.later`) is not
    run: the prompt records it as asking, for the initial text, and starts
    nothing; the loop starts its job after the scene, and its batches come
    in as they are posted (`Editor/Completion/Later.lean`). Its category
    counts as any source's. The prompt is refused with `noSuchJob`, with
    no text made, when no job is registered under the name it gives.
  - **A source that has filtered already** (`Completion.Source.filtered`)
    has its candidates kept apart (`passed`): they are listed after the
    matches, in the order it gave, whatever is typed.
  - **A category may be asked for** (`.category category defaults`): the
    sources registered in it, by name (`StateRequest.categorySources`),
    with `defaults` first, each asked by name where one of its name is
    registered in the category and as itself otherwise, then the
    category's other sources, in registration order. A category with no
    source and no defaults lists nothing, and the prompt is not refused.
  - **The prompt's category is its first reference's**: the one a
    category reference names, or the first source's, as an Emacs
    completion table has one category. It chooses the style its candidates
    are matched with. A prompt with no source has none.
  - **The list is then fixed**, but for `setCandidates`, which replaces an
    open prompt's candidates and forgets what it has listed and chosen. It
    is refused, as a value, with `notOpen` when no prompt is open.
  - A prompt asked with no source, the default, or with sources that
    answer none, makes the requests it made before there were candidates.
  - **The loop lists them**, before each scene: the candidates the
    minibuffer's text matches, in the order of the style the prompt's
    category chooses (`Editor/Loop.lean`, "Prompts"), then the passed
    ones. `chooseCandidate step` moves a choice
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
    read: that candidate's text;
  - **nothing is chosen**, whatever is listed: the text. So a user who
    types and accepts gets what was typed, with or without candidates;
  - **nothing matches**: nothing can be chosen, so the text;
  - **a choice made for another text** than the one read is not taken:
    that can only be a command that changed the minibuffer and accepted in
    one step, and it gets the text.
- **A typed answer is resolved as it was listed.** A command whose answer
  is one of its candidates, and takes a typed text that is none of them
  as the best match, matches it with `matchByCategory`: the style the
  loop chooses for the prompt's category, the one the prompt was listed
  with, over the candidates in the order the prompt holds them. So
  accepting with nothing chosen gives what the first listed candidate
  gives, whichever style config chose, and the command never asks the
  matcher by another rule than the listing's.
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

## Completion at point

A command completes the text at the cursor from the sources a buffer's
at-point sources name (`docs/design/keymaps-and-modes.md`, "Completion at
point"; `Editor/Completion/AtPoint.lean`).

- `completeAtPoint occasion` asks the chain of the focused window's buffer
  for the sources that ask on the occasion (`StateRequest.atPointSources`),
  and asks each, in order, for its region at the cursor
  (`StateRequest.askAtPoint`), **stopping at the first that answers**. A
  region that does not hold the cursor, or whose ends are not positions of
  the text, is refused `outside`. The sources it names are asked with the
  region's text (`collectSources`, shared with `prompt`), the region's ends
  are marked, the start with the bias `before` and the end with `after`,
  and a session opens over them with nothing chosen. It is refused, as a
  value, while a prompt or a session is open.
- `previewAtPoint step` moves the session's choice and puts the chosen
  candidate's text, or with nothing chosen the text typed, in the region,
  as one transaction that carries the selection before it and leaves the
  cursor after it. The buffer's group is closed before the first preview,
  and the command says it typed backspaces for the region's characters and
  then the new text (`retype`), for the last change's recording.
- `acceptAtPoint` and `quitAtPoint` close the session (`endAtPoint`),
  leaving the region as it is, and close the buffer's group when it made a
  preview: the previews and the accept are one step of the history.
- `retype view text` records what a command typed in place of typed text
  (`EditorState.retyped`), which the loop tells the input scheme once the
  command has run to its end.

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

## Workspaces

Which workspace and which project a buffer belongs to, and the stores each
keeps (`Editor/Workspace.lean`, `docs/design/projects.md`). Each operation
is one read of the state or one state request (`Editor/State.lean`,
"Workspaces").

- `BufferId.workspace?` is the buffer's workspace and its project, read from
  its buffer-local value (`Workspace.bufferLocal`), or `none`.
- `BufferId.inheritWorkspace id source` gives a buffer the workspace of the
  buffer it was made from; a source with none gives none.
- `BufferId.workingDirectory` is where a command run for a buffer runs: its
  workspace's root on this machine, its workspace's location when that is
  elsewhere, the directory of its file when it has no workspace, or none.
- `Workspace.register` makes a workspace that is not on this machine, for
  a remote agent session or a later remote adapter; a local location is
  refused, since local workspaces are found.
- `Workspace.setValue` and `Project.setValue` set a value of a workspace's
  or a project's store by name; `Workspace.set` and `Project.set` set the
  value of a `Store` (`Editor/Store.lean`) there, by its encoding, and
  `Workspace.Table.get` and `getOfProject` read one back, its initial value
  where none was set. The typed operations are here, not beside the table,
  because the stores' module is downstream of the editor state.
- `Workspace.setUnscopedValue` and `Workspace.setUnscoped` set a value of
  the unscoped store, the one store of the buffers outside any workspace,
  which have no project either; `Workspace.Table.getUnscoped` reads one
  back. Neither is refused.
- The editor's working directory, where a command run for a buffer with
  neither a workspace nor a file runs, is the state's
  (`EditorState.workingDirectory`), read from `editorState`.

Pinned by `ModelTest.workspaceStateChecks`.

Each operation that makes a text request has a case in
`Editor/Api/Cases.lean`, played on the editor's models and on the real
binding.
-/

namespace Editor

/-- Makes one request of the editor state and returns its reply. It is never
refused: a reply that can be is an `Except`, a value. -/
def EditorState.ask (request : StateRequest) : EditorM request.Reply :=
  ExceptT.lift (Program.request (port := editorPort) (.state request))

/-- Asks the registry or config one question and returns its answer
("Asking the registry, and the loop's control", in the module docs). It is
never refused. -/
def RegistryRequest.ask (request : RegistryRequest) : EditorM request.Reply :=
  ExceptT.lift (Program.request (port := editorPort) (.registry request))

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
`arguments`, once this command has run to its end, under the key `key` if
it is given: the running job of that key is then cancelled first. Its
result comes back later, as the command its handler makes. Refused with
`noSuchJob` for a name no job is registered under. -/
def startJob (name : String) (arguments : List Argument := []) (key : Option String := none) :
    EditorM (Except JobRefusal Unit) :=
  EditorState.ask (.startJob name arguments key)

/-- Asks for the job of the key `key` to be cancelled, once this command has
run to its end: it is ended, even one that has finished and not been
delivered, so its command never runs. A key no job has cancels nothing. It
is never refused. -/
def cancelJob (key : String) : EditorM Unit :=
  EditorState.ask (.cancelJob key)

/-- The ex binding of the ex name `name`: the command a line of that name
runs, and what the name takes (`Ex.Binding`, `Editor/Ex/Line.lean`). `none`
for a name nobody bound, and where no loop runs the command. -/
def exBinding (name : String) : EditorM (Option Ex.Binding) :=
  RegistryRequest.ask (.ex name)

/-- The ex names that are bound, each once, in the order they were first
bound. None where no loop runs the command. -/
def exNames : EditorM (Array String) :=
  RegistryRequest.ask .exNames

/-- The names themes are registered under, each once, in the order they
were first registered ("Themes", in the module docs). None where no loop
runs the command. -/
def themeNames : EditorM (Array String) :=
  RegistryRequest.ask .themeNames

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

/-- Makes the buffer `id` read-only to editing commands, or not, as `on`
says (`Editor/State.lean`, "Buffers"). Refused with `noSuchBuffer` for a
buffer there is none of. -/
def BufferId.setReadOnly (id : BufferId) (on : Bool) : EditorM (Except BufferRefusal Unit) :=
  EditorState.ask (.setReadOnly id on)

/-- Records `name` as the language of the buffer `id`, or, with `none`,
that it has none (`Editor/Language.lean`): the `code` mode's text is then
parsed and drawn as that language says, from the next time a major mode is
set. Any name is taken. Refused with `noSuchBuffer` for a buffer there is
none of. -/
def BufferId.setLanguage (id : BufferId) (name : Option String) :
    EditorM (Except BufferRefusal Unit) :=
  EditorState.ask (.setLanguage id name)

/-- The name of the language the registry's table chooses for `path`
(`Language.forPath`), or none when no entry matches: what a file's open
records as its buffer's language. `none` where no loop runs the
command. -/
def languageOf (path : System.FilePath) : EditorM (Option String) :=
  EditorState.ask (.languageOf path)

/-- The indent unit of the language called `name`: the unit of the
registry's first entry of that name, or none when the table has none. `none`
where no loop runs the command. -/
def indentUnitOf (name : String) : EditorM (Option Language.IndentUnit) :=
  EditorState.ask (.indentUnitOf name)

/-- One level of indentation in `target`'s buffer: the unit of its
language's entry, or four spaces (`Language.IndentUnit.default`) for a
buffer with no language or one the table has no entry of. -/
def Target.indentUnit (target : Target) : EditorM Language.IndentUnit := do
  let some language := target.buffer.language | return Language.IndentUnit.default
  return (← indentUnitOf language).getD Language.IndentUnit.default

/-- Sets the spans of the buffer `id`, byte ranges of its text each with a
face, which every view of it draws under the last search's matches
(`Editor/State.lean`, "Buffers"). Refused with `noSuchBuffer` for a buffer
there is none of. -/
def BufferId.setSpans (id : BufferId) (spans : Array Decoration) :
    EditorM (Except BufferRefusal Unit) :=
  EditorState.ask (.setSpans id spans)

/-- Sets the gutter of the buffer `id`, marks at a revision of its text that
every window of it draws in a column before its text, carried through the
edits made since; or takes it away, and the column with it, with `none`
(`Editor/State.lean`, "Buffers"). Refused with `noSuchBuffer` for a buffer
there is none of. -/
def BufferId.setGutter (id : BufferId) (gutter : Option Buffer.Gutter) :
    EditorM (Except BufferRefusal Unit) :=
  EditorState.ask (.setGutter id gutter)

/-- Runs `action` with the buffer `id` writable, as Emacs's
`inhibit-read-only` does, for the command that owns a read-only buffer: a
buffer that is read-only is made writable, `action` runs, and the buffer is
made read-only again. A command that does not run to its end is rolled
back to the state from before it, the flag included. -/
def BufferId.writing {α : Type} (id : BufferId) (action : EditorM α) : EditorM α := do
  let was := ((← editorState).buffer? id).any (·.readOnly)
  if was then
    discard <| id.setReadOnly false
  let value ← action
  if was then
    discard <| id.setReadOnly true
  return value

/-- Runs `invocation`, which a job posted ("Jobs", in the module docs): the
command registered under its name, with the focused window and the
invocation's arguments, as part of this command (`runCommand`). A name no
command is registered under says `<name>: no such command`; with no window
focused nothing runs. -/
def runPosted (invocation : Invocation) : EditorM Unit := do
  let some target := (← editorState).focusedTarget? | return
  unless ← runCommand invocation.command { target, arguments := invocation.arguments } do
    message s!"{invocation.command}: no such command"

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

/-- Asks `sources` for `query` ("Prompts", in the module docs), as a prompt
and a session at point ask theirs: each source in order, as itself or by
name, a category for its sources' names once, a source that answers later
recorded as asking, for the query's text, and not run. The category is the
first reference's, or the first source's. Each job a source that answers
later names must be registered. When a source that answers later reads the
open buffers' texts (`Completion.Later.readsTexts`), a snapshot is taken of
the asking view's buffer and then of each other open buffer
(`EditorState.openBuffers`), and they are what was collected's texts. The
query's region is kept too. Refused, as a value, with `noSuchSource` for a
name no source is registered under, and `noSuchJob` for a job no job is
registered under, before any snapshot is taken. -/
def collectSources (sources : List Completion.SourceRef) (query : Completion.Query) :
    EditorM (Except SourceRefusal Completion.Collected) := do
  -- Each source to ask, as itself or by name. A category is asked for its
  -- sources' names once: a default is asked by name where a source of its
  -- name is registered in the category, and as itself otherwise, then the
  -- category's other sources, in registration order.
  let mut resolved : Array (Completion.Source ⊕ String) := #[]
  for source in sources do
    match source with
    | .given source =>
      resolved := resolved.push (.inl source)
    | .named name =>
      resolved := resolved.push (.inr name)
    | .category category defaults =>
      let names ← EditorState.ask (.categorySources category)
      resolved :=
        resolved ++
          defaults.toArray.map
            (fun default =>
              if names.contains default.name then .inr default.name else .inl default) ++
          (names.filter fun name => !defaults.any (·.name == name)).map .inr
  -- The category is the first reference's: the one a category reference
  -- names, or the first source's.
  let mut collected : Completion.Collected :=
    { category :=
        match sources.head? with
        | some (.category category _) => some category
        | _ => none
      region := query.region, place := query.place }
  for source in resolved do
    let (name, answer) : String × Completion.Answer ←
      match source with
      | .inl { name, category, filtered, later := some later, .. } =>
        -- A source that answers later is not run here: its job answers.
        pure (name, { category, filtered, candidates := #[], later := some later })
      | .inl source =>
        pure
            (source.name,
              { category := source.category, filtered := source.filtered
                candidates := (← source.candidates query).map (·.inGroup source.name) })
      | .inr name =>
        let some answered ←
          EditorState.ask (.askSource name query) | return .error (.noSuchSource name)
        pure (name, { answered with candidates := answered.candidates.map (·.inGroup name) })
    -- Failing that, the category is the first source's.
    let category := collected.category <|> some answer.category
    collected :=
      match answer.later with
      | some later =>
        { collected with
          asking :=
            collected.asking.push
              { source := name, filtered := answer.filtered, later, askedFor := query.text }
          category }
      | none =>
        if answer.filtered then
          { collected with
            passed := collected.passed ++ answer.candidates, category }
        else
          { collected with
            all := collected.all ++ answer.candidates, category }
  -- Each job a source that answers later names must be registered.
  for source in collected.asking do
    unless ← EditorState.ask (.hasJob source.later.job) do
      return .error (.noSuchJob source.later.job)
  -- A source that reads the open buffers' texts is handed a snapshot of
  -- each, the asking view's buffer's first: taken once, here.
  if collected.asking.any (·.later.readsTexts) then
    let state ← editorState
    let first := (state.target? query.view).map (·.window.buffer)
    let buffers := first.toArray ++ state.openBuffers.filter (some · != first)
    let mut texts := #[]
    for buffer in buffers do
      if let some held := state.buffer? buffer then
        texts := texts.push (← held.text.snapshot)
    collected := { collected with texts }
  return .ok collected

/-- Asks for a string: opens a prompt labelled `label`, whose minibuffer
holds `initial`, with the cursor after it, and returns the minibuffer's
view at once ("Prompts", in the module docs). When the prompt is accepted,
the command of `continuation` is run with the answer as its first
argument, before the continuation's own. Refused, with no text made, with
`alreadyOpen` while a prompt is open, and with `noWindow` where no window
is focused to ask from.

`sources` supply the candidates the answer may be chosen from, none by
default. Each is asked once, in order, after those two refusals and before
the minibuffer's text is made, with `initial` and the asking view; the
prompt keeps what they answered, each source's candidates in its group
(`Completion.Candidate.inGroup`), in the sources' order: a filtered
source's apart, to be listed as given, and every other's to be matched.
The prompt's category is its first reference's. A source given as
a value is run here; one named is run by the loop (`StateRequest.askSource`),
and refused, with no text made, with `noSuchSource` when no source is
registered under its name. A source that answers later
(`Completion.Source.later`), given or named, is not run: it is recorded as
asking, for `initial`, and the loop starts its job
(`Editor/Completion/Later.lean`); the prompt is refused, with no text made,
with `noSuchJob` when no job is registered under its job's name. A category (`.category category defaults`) is
asked for the names of its registered sources once
(`StateRequest.categorySources`): each default is asked by name where one
of its name is registered in the category and as itself otherwise, then
each other name in the category, in registration order. A category with
no source and no defaults asks nothing. If a source is refused, so is this
command, with no prompt open. -/
def prompt (label : String) (continuation : Invocation) (initial : String := "")
    (sources : List Completion.SourceRef := []) : EditorM (Except PromptRefusal ViewId) := do
  let state ← editorState
  if let some asked := state.prompt then
    return .error (.alreadyOpen asked.view)
  let some asker := state.focusedTarget? | return .error .noWindow
  let query : Completion.Query :=
    { text := initial, view := asker.window.id, place := state.placeOf asker.window.id }
  let collected ←
    match ← collectSources sources query with
    | .ok collected =>
      pure collected
    | .error (.noSuchSource name) =>
      return .error (.noSuchSource name)
    | .error (.noSuchJob name) =>
      return .error (.noSuchJob name)
  let text ← createText initial
  let scroll ← text.mark (.anchor { offset := 0, bias := .before })
  let cursor := initial.utf8ByteSize
  let selection ← text.mark (.selection { ranges := #[⟨cursor, cursor⟩], shape := .exclusive })
  let opened ←
    EditorState.ask (.openPrompt label continuation text (← UndoTree.over text) scroll selection)
  -- A prompt with no candidates makes no request for them.
  if
      opened.isOk &&
        !(collected.all.isEmpty && collected.passed.isEmpty && collected.asking.isEmpty) then
    discard <| EditorState.ask (.setCandidates collected)
  return opened

/-- Replaces the open prompt's candidates, the passed ones and its category
with `collected`, and forgets what it has listed and chosen ("Prompts", in
the module docs). Refused with `notOpen` when no prompt is open. -/
def setCandidates (collected : Completion.Collected) : EditorM (Except PromptRefusal Unit) :=
  EditorState.ask (.setCandidates collected)

/-- Which of `candidates` `text` matches, in order, each with the ranges
that matched: the hits of the completion style the loop chooses for
`category`, the one a prompt of that category is listed with ("Prompts", in
the module docs). It is run inside this command, over the fuzzy port, and
is not refused. -/
def matchByCategory (category : String) (text : String) (candidates : Array String) :
    EditorM (Array Completion.Hit) :=
  EditorState.ask (.matchCandidates (some category) text candidates)

/-- Moves the open prompt's choice by `step` through the candidates it has
listed ("Prompts", in the module docs): from nothing chosen to the first or
the last, from the last onward and from the first backward to nothing
chosen, and otherwise by one. With nothing listed it changes nothing. The
minibuffer's text is not changed. Refused with `notOpen` when no prompt is
open. -/
def chooseCandidate (step : Candidates.Step) : EditorM (Except PromptRefusal Unit) :=
  EditorState.ask (.chooseCandidate step)

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

/-- One excerpt of an excerpt buffer, as it is asked for: the bytes of the
buffer `buffer`'s text from `start` up to, not including, `stop`, as it is
now, and the header drawn above it (none when empty). -/
structure BufferExcerpt where
  /-- The buffer whose text it is a range of. -/
  buffer : BufferId
  /-- Where the range starts. -/
  start : Nat
  /-- Where it stops, not included. -/
  stop : Nat
  /-- The header drawn above it; none when empty. -/
  header : String := ""
  deriving DecidableEq, Repr

/-- The store's excerpts of `list`, each over its buffer's text, and the
entries the excerpt buffer keeps of them; `noSuchBuffer` and the first
buffer there is none of. -/
def excerptsOf (list : Array BufferExcerpt) :
    EditorM (Except BufferRefusal (Array Excerpt × Array Buffer.ExcerptEntry)) := do
  let state ← editorState
  let mut excerpts := #[]
  let mut entries := #[]
  for item in list do
    let some buffer := state.buffer? item.buffer | return .error (.noSuchBuffer item.buffer)
    excerpts := excerpts.push ⟨buffer.text, item.start, item.stop⟩
    entries := entries.push { source := buffer.text, header := item.header }
  return .ok (excerpts, entries)

/-- Makes an excerpt buffer called `name` over a new excerpt text of the
excerpts `list` (`createExcerpts`) of buffers' texts, each with its header,
and returns its id: what an edit typed in it reaches is its sources'
buffers, and a window over it draws each header above its excerpt
(`Editor/State.lean`, "Excerpt buffers"; `Editor/ExcerptView.lean`).
Refused, with no text made, with `nameTaken` for a name a buffer already
has, and with `noSuchBuffer` for an excerpt of a buffer there is none of;
what the store refuses of the list is thrown, as `createText` would. -/
def createExcerptBuffer (name : String) (list : Array BufferExcerpt) :
    EditorM (Except BufferRefusal BufferId) := do
  if (← findBuffer name).isSome then
    return .error (.nameTaken name)
  match ← excerptsOf list with
  | .error refusal =>
    return .error refusal
  | .ok (excerpts, entries) =>
    let text ← createExcerpts excerpts
    EditorState.ask (.addExcerptBuffer name text (← UndoTree.over text) entries)

/-- `createExcerptBuffer` of excerpts of texts, `list`, which a text no
buffer holds may be among, each with the header at its index of `headers`
(none past its end). Refused with `nameTaken`, with no text made. -/
def createExcerptBufferOf (name : String) (list : Array Excerpt) (headers : Array String := #[]) :
    EditorM (Except BufferRefusal BufferId) := do
  if (← findBuffer name).isSome then
    return .error (.nameTaken name)
  let text ← createExcerpts list
  let entries :=
    list.mapIdx fun index excerpt =>
      { source := excerpt.source, header := headers[index]?.getD "" : Buffer.ExcerptEntry }
  EditorState.ask (.addExcerptBuffer name text (← UndoTree.over text) entries)

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

/-- Replaces the list of the excerpt buffer `id`'s text with `list`, ranges
of buffers' texts (`TextId.setExcerpts`), and its headers with theirs: how
an emptied excerpt goes. Refused with `noSuchBuffer` for a buffer there is
none of, `id` or one `list` names; what the store refuses is thrown, a
buffer that is not an excerpt buffer as `notExcerpted`. -/
def setExcerpts (id : BufferId) (list : Array BufferExcerpt) :
    EditorM (Except BufferRefusal Unit) := do
  match ← id.text, ← excerptsOf list with
  | .error refusal, _ =>
    return .error refusal
  | _, .error refusal =>
    return .error refusal
  | .ok text, .ok (excerpts, entries) =>
    text.setExcerpts excerpts
    let some buffer := (← editorState).buffer? id | return .error (.noSuchBuffer id)
    let some kept := buffer.excerpts | return .error .notExcerpts
    EditorState.ask (.setExcerptHistory id { kept with entries })

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

/-- The boundary of a buffer's own undo tree: `closeGroup` of a buffer that
is not an excerpt buffer. -/
def closeOwnGroup (id : BufferId) : EditorM (Except BufferRefusal Unit) := do
  match ← id.synced with
  | .ok buffer =>
    EditorState.ask (.setHistory id buffer.history.close)
  | .error refusal =>
    return .error refusal

/-- Whether the buffer `id` is an excerpt buffer. -/
def isExcerpts (id : BufferId) : EditorM Bool :=
  return ((← editorState).buffer? id).any (·.excerpts.isSome)

/-- The boundary of the excerpt buffer `id` (the module docs, "Undo"): each
source buffer it touched since its last step has its group closed, and they
become one step of the excerpt buffer's, with the state each tree was left
in. Its own tree's group is closed too. Refused with `noSuchBuffer` for a
buffer there is none of. -/
def excerptCloseGroup (id : BufferId) : EditorM (Except BufferRefusal Unit) := do
  let some buffer := (← editorState).buffer? id | return .error (.noSuchBuffer id)
  for source in (buffer.excerpts.map (·.touched)).getD #[] do
    discard <| source.closeOwnGroup
  match ← id.closeOwnGroup with
  | .error refusal =>
    return .error refusal
  | .ok () =>
    let closed := (← editorState).closeExcerptGroup id
    let some excerpts := (closed.buffer? id).bind (·.excerpts) | return .ok ()
    EditorState.ask (.setExcerptHistory id excerpts)

/-- Sets the boundary in the buffer `id`'s history: the edits since the last
one become one step. With nothing pending it makes no node. A boundary set
by a command that then does not run to its end is taken back with the
command's edits (`Editor/Loop.lean`, "Rollback"). For an excerpt buffer it
is `excerptCloseGroup`. Refused with `noSuchBuffer` for a buffer there is
none of. -/
def closeGroup (id : BufferId) : EditorM (Except BufferRefusal Unit) := do
  if ← id.isExcerpts then
    id.excerptCloseGroup
  else
    id.closeOwnGroup

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

/-- The source buffers of `step`, none of them removed, each in the state
the step recorded, told the revisions their texts are at: the first that is
not as `sourceMoved`. -/
def stepHolds (step : Buffer.ExcerptStep) : EditorM (Except BufferRefusal Unit) := do
  for source in step.sources do
    match ← source.buffer.synced with
    | .ok buffer =>
      unless buffer.history.state == source.state do
        return .error (.sourceMoved source.buffer)
    | .error _ =>
      return .error (.sourceMoved source.buffer)
  return .ok ()

/-- Takes the excerpt buffer `id`'s step `step`, the last of its steps of
one kind, by `move` in each of its source buffers. `replaced` makes the
excerpt buffer's steps with that step in place of the last of that kind,
or with it taken off for `none`, and `kept` with it taken off and the
states each source is left in pushed as a step of the other kind. `none`,
with nothing done, when `step` is none. When a source buffer of the step
was removed, each such source is dropped from the step, and the step with
them once none is left (`replaced`), nothing else is done, and the move is
refused with `sourceRemoved` and the first such source's name as the step
recorded it. `sourceMoved`, with nothing done, when a source buffer moved
since the step (`stepHolds`). -/
def excerptMoved (id : BufferId) (step : Option Buffer.ExcerptStep)
    (move : BufferId → EditorM (Except BufferRefusal (Option Undone)))
    (replaced : Buffer.Excerpts → Option Buffer.ExcerptStep → Buffer.Excerpts)
    (kept : Buffer.Excerpts → Buffer.ExcerptStep → Buffer.Excerpts) :
    EditorM (Except BufferRefusal (Option Undone)) := do
  let some step := step | return .ok none
  let state ← editorState
  let some buffer := state.buffer? id | return .error (.noSuchBuffer id)
  let some excerpts := buffer.excerpts | return .error .notExcerpts
  let (live, removed) := step.sources.partition fun source => (state.buffer? source.buffer).isSome
  if let some first := removed[0]? then
    let left := if live.isEmpty then none else some { step with sources := live }
    if let .error refusal← EditorState.ask (.setExcerptHistory id (replaced excerpts left)) then
      return .error refusal
    return .error (.sourceRemoved first.name)
  if let .error refusal← stepHolds step then
    return .error refusal
  let mut states := #[]
  for source in step.sources do
    match ← move source.buffer with
    | .ok _ =>
      let moved := (← editorState).buffer? source.buffer
      states :=
        states.push
          { source with
            name := (moved.map (·.name)).getD source.name
            state := (moved.map (·.history.state)).getD ⟨0⟩ }
    | .error refusal =>
      return .error refusal
  let some buffer := (← editorState).buffer? id | return .error (.noSuchBuffer id)
  let some excerpts := buffer.excerpts | return .error .notExcerpts
  match ← EditorState.ask (.setExcerptHistory id (kept excerpts ⟨states⟩)) with
  | .ok () =>
    return .ok (some ⟨none⟩)
  | .error refusal =>
    return .error refusal

/-- Undoes the excerpt buffer `id`'s last step in each of its source
buffers, with the user's origin (the module docs, "Undo"): the group is
closed first; a step a source buffer of which was removed since loses that
source, or is dropped once it has none, and is refused with
`sourceRemoved`; and a step whose source moved since is refused with
`sourceMoved`, changing nothing. `none`, with nothing done, when there is no
step to undo. Nothing is handed back to place. -/
def excerptUndo (id : BufferId) : EditorM (Except BufferRefusal (Option Undone)) := do
  if let .error refusal← id.excerptCloseGroup then
    return .error refusal
  let some buffer := (← editorState).buffer? id | return .error (.noSuchBuffer id)
  let some excerpts := buffer.excerpts | return .error .notExcerpts
  id.excerptMoved excerpts.undos.back? (fun source => source.moved (·.undo Origin.user))
      (fun excerpts left => { excerpts with undos := excerpts.undos.pop ++ left.toArray })
      fun excerpts step =>
      { excerpts with
        undos := excerpts.undos.pop, redos := excerpts.redos.push step }

/-- Redoes the excerpt buffer `id`'s next step in each of its source
buffers, with the user's origin, as `excerptUndo` undoes one. `none`, with
nothing done, when there is no step to redo, and whenever an edit through
it is pending. -/
def excerptRedo (id : BufferId) : EditorM (Except BufferRefusal (Option Undone)) := do
  let some buffer := (← editorState).buffer? id | return .error (.noSuchBuffer id)
  let some excerpts := buffer.excerpts | return .error .notExcerpts
  if !excerpts.touched.isEmpty then
    return .ok none
  id.excerptMoved excerpts.redos.back? (fun source => source.moved (·.redo Origin.user))
      (fun excerpts left => { excerpts with redos := excerpts.redos.pop ++ left.toArray })
      fun excerpts step =>
      { excerpts with
        redos := excerpts.redos.pop, undos := excerpts.undos.push step }

/-- Undoes one step of the buffer `id`'s history, with the user's origin,
and hands back the selection from before the step's first edit. The open
group is a step: it is closed first. `none`, with nothing done, when there
is no step to undo. An excerpt buffer's is `excerptUndo`. Refused with
`noSuchBuffer` for a buffer there is none of. -/
def undo (id : BufferId) : EditorM (Except BufferRefusal (Option Undone)) := do
  if ← id.isExcerpts then
    id.excerptUndo
  else
    id.moved (·.undo Origin.user)

/-- Redoes one step of the buffer `id`'s history, with the user's origin,
and hands back the selection from after the step's last edit. `none`, with
nothing done, when there is no step to redo, and whenever an edit is
pending. An excerpt buffer's is `excerptRedo`. Refused with `noSuchBuffer`
for a buffer there is none of. -/
def redo (id : BufferId) : EditorM (Except BufferRefusal (Option Undone)) := do
  if ← id.isExcerpts then
    id.excerptRedo
  else
    id.moved (·.redo Origin.user)

/-- Has the buffer `id` keep `value` under `name`, in place of the value the
name had. Refused with `noSuchBuffer` for a buffer there is none of. -/
def setValue (id : BufferId) (name : String) (value : Value) :
    EditorM (Except BufferRefusal Unit) :=
  EditorState.ask (.setValue id name value)

/-- The value the buffer `id` keeps under `name`, if it keeps one. -/
def value? (id : BufferId) (name : String) : EditorM (Option Value) :=
  return (← editorState).value? id name

/-- Makes the mode called `name` the major mode of the buffer `id`, which
no window need show, and says whether it became the major mode: `false`,
with nothing run, when the buffer already had it. When it became it, the
text is highlighted as the mode says and the on-enter actions of the
mode's lineage have run, root first, once with each view that shows the
buffer, and with none when no window shows it, before this returns
(`Editor/Command/Dispatch.lean`). Refused with `noSuchBuffer` for a
buffer there is none of, and with `noSuchMode` for a name no mode is
registered under. -/
def setMajorMode (id : BufferId) (name : String) : EditorM (Except ModeRefusal Bool) :=
  EditorState.ask (.setBufferMajorMode id name)

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

/-- The changes that replace each extent of `edits`, sorted and apart, of a
text of `length` bytes, with its string, and the cursor after each
insertion. -/
def replacing (length : Nat) (edits : Array (Extent × String)) :
    Array Change × Array SelectionRange :=
  Id.run do
    let mut changes := #[]
    let mut cursors := #[]
    let mut walked := 0
    let mut shift : Int := 0
    for (extent, text) in edits do
      changes :=
        changes ++
          #[.retain (extent.start - walked), .delete (extent.stop - extent.start), .insert text]
      let after := (extent.start + shift + text.utf8ByteSize).toNat
      cursors := cursors.push ⟨after, after⟩
      shift := shift + text.utf8ByteSize - (extent.stop - extent.start)
      walked := extent.stop
    return (changes.push (.retain (length - walked)), cursors)

/-- The changes that replace each of `extents`, sorted and apart, of a text
of `length` bytes, with `text`, and the cursor after each insertion. -/
def replacingEach (length : Nat) (extents : Array Extent) (text : String) :
    Array Change × Array SelectionRange :=
  replacing length (extents.map (·, text))

/-- Replaces each extent of `edits`, sorted and apart, of `text` with its
string, as one transaction made by the user that carries `before`, a
selection of the text as it is, and `after`, one of the text the edits
leave. Refused, changing nothing, as the store refuses the transaction, as
`replaceCarrying` is. -/
def TextId.replaceEachCarrying (text : TextId) (edits : Array (Extent × String))
    (before after : Selection) : TextM Unit := do
  let (changes, _) := replacing (← text.byteLength) edits
  let _ ← text.apply { changes, before := some before, after := some after } Origin.user
  return ()

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

/-- Replaces each extent of `edits`, sorted and apart, of `target`'s text
with its string, as one transaction made by the user, which carries
`before` and the cursors after, one after each insertion, with `before`'s
shape, and places the window's selection at those cursors. -/
def replaceEach (target : Target) (before : Selection) (edits : Array (Extent × String)) :
    TextM Unit := do
  let text := target.buffer.text
  let (changes, cursors) := replacing (← text.byteLength) edits
  let after : Selection :=
    { ranges := cursors, primary := min before.primary (cursors.size - 1), shape := before.shape }
  let _ ← text.apply { changes, before := some before, after := some after } Origin.user
  target.select after

/-- Replaces each of `extents`, sorted and apart, of `target`'s text with
`s`, as one transaction made by the user, which carries `before` and the
cursors after, one after each insertion, with `before`'s shape, and places
the window's selection at those cursors. -/
def replaceExtents (target : Target) (before : Selection) (extents : Array Extent) (s : String) :
    TextM Unit :=
  target.replaceEach before (extents.map (·, s))

/-- Replaces `extent` of `target`'s text with `s`, as one transaction made
by the user that carries `before` and `after` (`TextId.replaceCarrying`),
and places `after` as the window's selection. `before` is the caller's to
say: the selection from before its command, whatever the window's is by
now. -/
def replaceCarrying (target : Target) (extent : Extent) (s : String) (before after : Selection) :
    TextM Unit := do
  target.buffer.text.replaceCarrying extent s before after
  target.select after

/-- Replaces each extent of `edits`, sorted and apart, of `target`'s text
with its string, as one transaction made by the user that carries `before`
and `after` (`TextId.replaceEachCarrying`), and places `after` as the
window's selection, as `replaceCarrying` does for one extent. -/
def replaceEachCarrying (target : Target) (edits : Array (Extent × String))
    (before after : Selection) : TextM Unit := do
  target.buffer.text.replaceEachCarrying edits before after
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
that breaks a line at the cursors calls this, or reads `Buffer.lineEnding`
as `Evil.newline` and `Evil.openLine` do, and none writes the line feed
itself. -/
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
(`Scroll.Area`): a snapshot of its buffer's text, taken here, the view's
rectangle in the frame, and its blocks, read of that snapshot, so a scroll
command asks the rows the view shows with its blocks counted. The snapshot is released when `run` has
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
  -- Its blocks are those the scene showing it has: an excerpt buffer's
  -- headers (`ExcerptView.blocksOf`), placed by the snapshot taken here.
  some <$>
      target.buffer.text.withSnapshot fun snapshot => do
        let blocks ← ExcerptView.blocksOf target.buffer snapshot
        run (.ofRect snapshot rect bottom padding blocks)

end Target

/-- Replaces the whole of `minibuffer`'s text, which is `text`, with
`replacement`, as one transaction made by the user, the bar left at its
end. -/
private def replaceMinibuffer (minibuffer : Target) (text replacement : String) : EditorM Unit := do
  let selection ← minibuffer.selection
  minibuffer.replaceExtents selection #[⟨0, text.utf8ByteSize⟩] replacement

/-- Accepts the open prompt: it is closed, and its continuation's command is
run with the answer once this command has run to its end ("Prompts", in
the module docs). The answer is the chosen candidate, when one is chosen
and the prompt's listing is for the text of its minibuffer, and otherwise
that text (`Candidates.answer`). A chosen candidate that is partial
(`Completion.Candidate.isPartial`, `Candidates.entered?`) is gone into
instead: its text replaces the minibuffer's, as `insertCandidate` puts it,
and the prompt stays open. Refused with `notOpen` when no prompt is
open. -/
def acceptPrompt : EditorM (Except PromptRefusal Unit) := do
  let state ← editorState
  let some asked := state.prompt | return .error .notOpen
  let some minibuffer := state.target? asked.view | return .error .notOpen
  let text ← minibuffer.buffer.text.read
  -- A chosen partial candidate is gone into, not answered.
  if let some entered := asked.candidates.entered? text then
    replaceMinibuffer minibuffer text entered.text
    return .ok ()
  EditorState.ask (.closePrompt (some (asked.candidates.answer text)))

/-- Puts the candidate the open prompt would insert (`Candidates.toInsert`)
in its minibuffer ("Prompts", in the module docs): the chosen one, or the
first listed when nothing is chosen, when the listing is for the
minibuffer's text. The whole text is replaced with the candidate's, as one
transaction made by the user, with the bar left at the end, and the prompt
stays open. The loop then lists again for the new text, which forgets the
choice. With nothing to insert it changes nothing. Refused with `notOpen`
when no prompt is open. -/
def insertCandidate : EditorM (Except PromptRefusal Unit) := do
  let state ← editorState
  let some asked := state.prompt | return .error .notOpen
  let some minibuffer := state.target? asked.view | return .error .notOpen
  let text ← minibuffer.buffer.text.read
  if let some candidate := asked.candidates.toInsert text then
    replaceMinibuffer minibuffer text candidate.text
  return .ok ()

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

/-- Splits the window of `view`: a new window on the same buffer, whose
markers are copies of the window's scroll anchor and selection as they
are, and returns the new view. It goes in the frame's list as `placement`
says under manual splits, and right after the window under the other
layouts (`EditorState.splitWindow`). The focus stays. Refused with `noSuchWindow` for a view with
no window, and with `ofMinibuffer` for the minibuffer's view, each with no
marker made. -/
def split (view : ViewId) (placement : Placement := {}) : EditorM (Except LayoutRefusal ViewId) :=
  do
  if (← editorState).minibufferView? == some view then
    return .error (.ofMinibuffer view)
  match ← view.target with
  | .error refusal =>
    return .error refusal
  | .ok target =>
    let text := target.buffer.text
    let scroll ← text.mark (← text.marker target.window.scroll)
    let selection ← text.mark (← text.marker target.window.selection)
    EditorState.ask (.split view scroll selection placement)

/-- Makes `change` on the window of `view` (`Arrange`, `EditorState.arrange`):
a reorder of the frame's list, a zoom, or a change of its layout's
parameters. Refused with `noSuchWindow` for a view not in the list, with
`ofMinibuffer` for the minibuffer's view, and with what the change itself
refuses. -/
def arrange (view : ViewId) (change : Arrange) : EditorM (Except LayoutRefusal Unit) :=
  EditorState.ask (.arrange view change)

/-- Closes the window of `view`: it leaves the list, and the layout gives
its space to the rest. Refused with `noSuchWindow` for a view with no
window, with `ofMinibuffer` for the minibuffer's view, and with
`onlyWindow` for the last window of the list, which the minibuffer's
window does not count towards. -/
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

/-- Opens a new tab after the one in view, its one window on the buffer of
`view`'s window, with markers that are copies of the window's scroll
anchor and selection as they are, and returns the new view
(`EditorState.openWindow`, `WindowSpot.tab`), as `split` makes a window.
The tab in view stays in view, and the focus stays. Refused with
`noSuchWindow` for a view with no window, and with `ofMinibuffer` for the
minibuffer's view, each with no marker made. -/
def newTab (view : ViewId) : EditorM (Except LayoutRefusal ViewId) := do
  if (← editorState).minibufferView? == some view then
    return .error (.ofMinibuffer view)
  match ← view.target with
  | .error refusal =>
    return .error refusal
  | .ok target =>
    let text := target.buffer.text
    let scroll ← text.mark (← text.marker target.window.scroll)
    let selection ← text.mark (← text.marker target.window.selection)
    EditorState.ask (.openWindow target.window.buffer scroll selection .tab)

end ViewId

/-- Makes `change` on the frame's tabs (`TabChange`, `EditorState.changeTab`):
selects, closes, renames or moves one, its index from 0. Refused with
`noSuchTab`, `onlyTab` and `promptOpen` as the change says. -/
def changeTab (change : TabChange) : EditorM (Except LayoutRefusal Unit) :=
  EditorState.ask (.tab change)

/-- Displays the buffer `buffer` where config's display rules say, for the
command `opener` acting on the view `asking`, and returns the view it is
shown in (`EditorState.displaying`, `Editor/DisplayRules.lean`). A window
that shows it already is used, and makes no marker; otherwise the first
rule that matches decides, or a new window in the stack: an existing
window shows it as `ViewId.show` does, and a new window gets a scroll
anchor at the buffer's start and one cursor at its start, of the shape the
asking view's selection has, marked on its text, and is opened
(`EditorState.openWindow`). The window is focused when the rule that
matched says so, and, when none matched, when `focus` does: the caller's
default, the fallback's focus. Refused with `ofMinibuffer`, and the
minibuffer's view, for the minibuffer's buffer, and with `noSuchBuffer`
for a buffer there is none of, each with no marker made. -/
def BufferId.display (buffer : BufferId) (asking : ViewId) (opener : String)
    (focus : Bool := true) : EditorM (Except LayoutRefusal ViewId) := do
  let state ← editorState
  if let some minibuffer := state.minibufferView? then
    if state.minibufferBuffer? == some buffer then
      return .error (.ofMinibuffer minibuffer)
  let some shown := state.buffer? buffer | return .error (.noSuchBuffer buffer)
  let rules ← RegistryRequest.ask .displayRules
  let (decided, focus) := state.displaying rules buffer asking opener focus
  let placed : Except LayoutRefusal ViewId ←
    match decided with
    | .shown view =>
      pure (.ok view)
    | .showIn view =>
      pure ((← view.show buffer).map fun () => view)
    | .opened spot =>
      let shape ←
        match state.target? (state.shownIn asking) with
        | some target =>
          pure (← target.selection).shape
        | none =>
          pure Shape.exclusive
      let scroll ← shown.text.mark (.anchor { offset := 0, bias := .before })
      let selection ← shown.text.mark (.selection { ranges := #[⟨0, 0⟩], shape })
      EditorState.ask (.openWindow buffer scroll selection spot)
  match placed with
  | .ok view =>
    if focus then
      if let .error refusal← view.focus then
        return .error refusal
    return .ok view
  | .error refusal =>
    return .error refusal

/-- What a float a command opens is placed against (`BufferId.float`): the
frame, the window `view`, or the byte offset `offset` of the buffer the
window `view` shows, which is marked as the float's anchor. -/
inductive Floating.At where
  /-- Centred in the tiled area. -/
  | frame
  /-- Centred in the window's rectangle. -/
  | window (view : ViewId)
  /-- Beside the position `offset` of the window's buffer. -/
  | position (view : ViewId) (offset : Nat)
  deriving DecidableEq, Repr

/-- The window a float placed against `at_` is anchored to, if it is one. -/
def Floating.At.view? : Floating.At → Option ViewId
  | .frame => none
  | .window view => some view
  | .position view _ => some view

/-- Opens the buffer `buffer` in a new float on top of the others, placed
against `at_`, of `share`, pinned or transient, and returns its view; the
float is focused when `focus` says (the module docs, "Windows"). The new
window gets a scroll anchor at the buffer's start and one cursor at its
start, of the shape the anchor window's selection has, or the focused
window's for the frame, and a position its anchor marker on the anchor
window's buffer's text, with the bias `before`. Refused, with no marker
made, with `ofMinibuffer` for the minibuffer's buffer, with
`noSuchBuffer` for a buffer there is none of, with `noSuchWindow` for an
anchor window that is no tiled or docked window of the frame, and with
`floating` for a float as the anchor window; an offset that is not a
position of the text is refused by the text store. -/
def BufferId.float (buffer : BufferId) (at_ : Floating.At) (share : Floating.Share := {})
    (pinned : Bool := false) (focus : Bool := true) : EditorM (Except LayoutRefusal ViewId) := do
  let state ← editorState
  if let some minibuffer := state.minibufferView? then
    if state.minibufferBuffer? == some buffer then
      return .error (.ofMinibuffer minibuffer)
  let some shown := state.buffer? buffer | return .error (.noSuchBuffer buffer)
  if let some view := at_.view? then
    if (state.frame.floating? view).isSome then
      return .error (.floating view)
    unless state.frame.anchors view do
      return .error (.noSuchWindow view)
  let shape ←
    match state.target? (at_.view?.getD state.frame.focused) with
    | some target =>
      pure (← target.selection).shape
    | none =>
      pure Shape.exclusive
  let scroll ← shown.text.mark (.anchor { offset := 0, bias := .before })
  let selection ← shown.text.mark (.selection { ranges := #[⟨0, 0⟩], shape })
  let anchor : Floating.Anchor ←
    match at_ with
    | .frame =>
      pure .frame
    | .window view =>
      pure (.window view)
    | .position view offset =>
      let some target := state.target? view | return .error (.noSuchWindow view)
      pure (.position view (← target.buffer.text.mark (.anchor { offset, bias := .before })))
  match ← EditorState.ask (.openWindow buffer scroll selection (.float anchor share pinned)) with
  | .ok view =>
    if focus then
      if let .error refusal← view.focus then
        return .error refusal
    return .ok view
  | .error refusal =>
    return .error refusal

/-! ## Workspaces -/

namespace BufferId

/-- The workspace of the buffer `id` and its project, or `none` when it has
none ("Workspaces", in the module docs). -/
def workspace? (id : BufferId) : EditorM (Option (Workspace × Project)) :=
  return (← editorState).workspaceOf? id

/-- Gives the buffer `id` the workspace of the buffer `source`, the one it
was made from: its buffer-local value. A source with none gives none, and
changes nothing. Refused with `noSuchBuffer` for a buffer `id` there is none
of. -/
def inheritWorkspace (id source : BufferId) : EditorM (Except BufferRefusal Unit) := do
  match (← editorState).value? source Workspace.bufferLocal with
  | some value =>
    id.setValue Workspace.bufferLocal value
  | none =>
    return .ok ()

/-- Where a command run for the buffer `id` runs: its workspace's root on
this machine, its workspace's location when that is elsewhere, the
directory of its file when it has no workspace, or none. -/
def workingDirectory (id : BufferId) : EditorM Workspace.WorkingDirectory := do
  let state ← editorState
  match state.workspaceOf? id with
  | some (workspace, _) =>
    match workspace.location with
    | .local root =>
      return .workspace root
    | location =>
      return .elsewhere location
  | none =>
    match ((state.buffer? id).bind (·.file)).bind (·.path.parent) with
    | some directory =>
      return .fileDirectory directory
    | none =>
      return .none

end BufferId

namespace Workspace

/-- Registers a workspace at `location`, not on this machine, of the project
of `remote`, with `branch` checked out if it is given. Refused with `local`
for a local location: those are found. -/
def register (location : Location) (remote : String) (branch : Option String := none) :
    EditorM (Except WorkspaceRefusal Unit) :=
  EditorState.ask (.registerWorkspace location remote branch)

/-- Has the workspace at `location` keep `value` under `name`. Refused with
`noSuchWorkspace` when there is none. -/
def setValue (location : Location) (name : String) (value : Value) :
    EditorM (Except WorkspaceRefusal Unit) :=
  EditorState.ask (.setWorkspaceValue location name value)

/-- Has the workspace at `location` keep `value` as the value of `store`, by
the store's encoding. Refused with `noSuchWorkspace` when there is none. -/
def set {α : Type} (store : Store α) (location : Location) (value : α) :
    EditorM (Except WorkspaceRefusal Unit) :=
  setValue location store.name (store.encode value)

/-- The value of `store` in the workspace at `location`: what its cell
decodes to, or the store's initial value when it has no cell or one the
store does not decode. -/
def Table.get {α : Type} (table : Table) (store : Store α) (location : Location) : α :=
  ((table.workspaceValue? location store.name).bind store.decode).getD store.initial

/-- The value of `store` in the project of `identity`: what its cell
decodes to, or the store's initial value when it has no cell or one the
store does not decode. -/
def Table.getOfProject {α : Type} (table : Table) (store : Store α) (identity : Project.Identity) :
    α :=
  ((table.projectValue? identity store.name).bind store.decode).getD store.initial

/-- Has the unscoped store, of the buffers outside any workspace, keep
`value` under `name`. Never refused. -/
def setUnscopedValue (name : String) (value : Value) : EditorM Unit :=
  EditorState.ask (.setUnscopedValue name value)

/-- Has the unscoped store keep `value` as the value of `store`, by the
store's encoding. Never refused. -/
def setUnscoped {α : Type} (store : Store α) (value : α) : EditorM Unit :=
  setUnscopedValue store.name (store.encode value)

/-- The value of `store` in the unscoped store: what its cell decodes to, or
the store's initial value when it has no cell or one the store does not
decode. -/
def Table.getUnscoped {α : Type} (table : Table) (store : Store α) : α :=
  ((table.unscopedValue? store.name).bind store.decode).getD store.initial

end Workspace

namespace Project

/-- Has the project of `identity` keep `value` under `name`. Refused with
`noSuchProject` when there is none. -/
def setValue (identity : Project.Identity) (name : String) (value : Value) :
    EditorM (Except WorkspaceRefusal Unit) :=
  EditorState.ask (.setProjectValue identity name value)

/-- Has the project of `identity` keep `value` as the value of `store`, by
the store's encoding. Refused with `noSuchProject` when there is none. -/
def set {α : Type} (store : Store α) (identity : Project.Identity) (value : α) :
    EditorM (Except WorkspaceRefusal Unit) :=
  setValue identity store.name (store.encode value)

end Project

/-- `count` backspace characters (U+0008): what a command that removed
`count` cells says it typed, as an input scheme records a backspace
(`EditorState.retyped`). -/
def backspaces (count : Nat) : String :=
  String.ofList (List.replicate count '\x08')

/-- Records that this command typed `text` in `view` in place of typed text
(`EditorState.retyped`): the loop tells the input scheme once the command
has run to its end, so the last change's recording gets it ("Completion at
point", in the module docs). -/
def retype (view : ViewId) (text : String) : EditorM Unit :=
  EditorState.ask (.retype view text)

/-- Asks the at-point sources of the chain of the focused window's buffer
that ask on `occasion`, in order, for the region at the cursor, stopping at
the first that answers ("Completion at point", in the module docs); asks
the sources it names (`collectSources`) with the region's text; marks the
region's ends, the start with the bias `before` and the end with `after`;
and opens a session over them with nothing chosen, asked silently when
`silent` (`AtPointSession.silent`). Says whether one answered. Refused, as a value, with `promptOpen` while a prompt is open,
`alreadyOpen` while a session is, `noWindow` where no window is focused,
`outside` for a region that does not hold the cursor or whose ends are not
positions of the text, and `source` when the sources cannot be asked. -/
def completeAtPoint (occasion : Completion.Occasion) (silent : Bool := false) :
    EditorM (Except AtPointRefusal Bool) := do
  let state ← editorState
  if state.prompt.isSome then
    return .error .promptOpen
  if state.atPoint.isSome then
    return .error .alreadyOpen
  let some target := state.focusedTarget? | return .error .noWindow
  let view := target.window.id
  let selection ← target.selection
  let some range := selection.ranges[selection.primary]? | return .ok false
  let head := range.head
  let spot : Completion.Spot := { view, offset := head, occasion }
  let mut answered : Option (String × Completion.Region) := none
  for name in ← EditorState.ask (.atPointSources view occasion) do
    if let some region← EditorState.ask (.askAtPoint name spot) then
      answered := some (name, region)
      break
  let some (name, region) := answered | return .ok false
  let text := target.buffer.text
  unless region.start ≤ head && head ≤ region.stop do
    return .error (.outside name)
  -- The text port refuses a range whose ends are not positions, and reads
  -- the region and no more of the text.
  let typed ←
    try
      text.slice region.start region.stop
    catch
    | .badRange =>
      return .error (.outside name)
    | refusal =>
      throw refusal
  let query : Completion.Query :=
    { text := typed, view, region := some { start := region.start, stop := region.stop }
      place := (← editorState).placeOf view }
  match ← collectSources (region.sources.map Completion.Named.ref) query with
  | .error refusal =>
    return .error (.source refusal)
  | .ok collected =>
    let start ← text.mark (.anchor { offset := region.start, bias := .before })
    let stop ← text.mark (.anchor { offset := region.stop, bias := .after })
    let session : AtPointSession :=
      { view, buffer := target.window.buffer, source := name, start, stop, typed, shown := typed,
        silent }
    match ← EditorState.ask (.openAtPoint session collected) with
    | .ok () =>
      return .ok true
    | .error refusal =>
      text.unmark start
      text.unmark stop
      for snapshot in collected.texts do
        snapshot.release
      return .error refusal

/-- The offsets of the open session's region as its markers now hold them,
and the region's text. Refused as the store refuses reading a marker. -/
def AtPointSession.region (session : AtPointSession) : TextM (Nat × Nat × String) := do
  let .anchor start ← session.start.text.marker session.start | throw .noSuchMarker
  let .anchor stop ← session.stop.text.marker session.stop | throw .noSuchMarker
  let stop := max start.offset stop.offset
  return (start.offset, stop, ← session.start.text.slice start.offset stop)

/-- The text the open session's region is to hold once its choice is what
it is: the chosen candidate's text, when one is chosen and the listing is
for the text typed, and otherwise the text typed. -/
def AtPointSession.wanted (session : AtPointSession) : String :=
  match session.candidates.chosen with
  | some index =>
    if session.candidates.listedFor == some session.typed then
      (session.candidates.listed[index]?.map (·.text)).getD session.typed
    else session.typed
  | none => session.typed

/-- Moves the open session's choice by `step` and previews it
("Completion at point", in the module docs): when the region's text is not
what the choice wants (`AtPointSession.wanted`), the buffer's group is closed
before the session's first preview, the region is replaced with it as one
transaction that carries the selection before it and leaves the cursor
after it, and the command says it typed backspaces for the region's
characters and then the new text (`retype`). Refused with `notOpen` when no
session is open, and `noWindow` when its view has no window. -/
def previewAtPoint (step : Candidates.Step) : EditorM (Except AtPointRefusal Unit) := do
  if let .error refusal← EditorState.ask (.chooseAtPoint step) then
    return .error refusal
  let some session := (← editorState).atPoint | return .error .notOpen
  let .ok target ← session.view.target | return .error .noWindow
  let (start, stop, old) ← session.region
  let wanted := session.wanted
  if old != wanted then
    unless session.previewed do
      discard <| session.buffer.closeGroup
    target.replaceExtents (← target.selection) #[{ start, stop }] wanted
    retype session.view (backspaces old.length ++ wanted)
    return ← EditorState.ask (.retypeAtPoint wanted true)
  return .ok ()

/-- Closes the open session ("Completion at point", in the module docs),
leaving the region as it is, and closes its buffer's group when it made a
preview: the previews, the accept and what was typed after them are one
step of the history. Its markers and snapshots are given up by the loop once
this command has run to its end. Refused with `notOpen` when no session is
open. -/
def endAtPoint : EditorM (Except AtPointRefusal Unit) := do
  match ← EditorState.ask .closeAtPoint with
  | .error refusal =>
    return .error refusal
  | .ok session =>
    if session.previewed then
      discard <| session.buffer.closeGroup
    return .ok ()

/-- Accepts the open session's chosen candidate: the region already holds it,
by the preview, so the session closes (`endAtPoint`). Refused with
`notOpen` when no session is open. -/
def acceptAtPoint : EditorM (Except AtPointRefusal Unit) :=
  endAtPoint

/-- Quits the open session, leaving the region as it is, as Doom's `C-g`
does (`endAtPoint`). Refused with `notOpen` when no session is open. -/
def quitAtPoint : EditorM (Except AtPointRefusal Unit) :=
  endAtPoint

end Editor
