# Concurrency

Emacs Lisp runs on one thread, so a slow command, a blocking prompt or a
subprocess call freezes the editor. The `edmacs` record has the consequences:
a blocked minibuffer read wedged the whole process, hooks fired during
redisplay, and a suite of workarounds existed only to keep work off the
redraw path. This document says how editor code gets real concurrency
without the window ever waiting on it.

Lean makes this practical: its task system runs on OS threads, and its
values are immutable and reference-counted, so data can be shared between
threads safely. There is no global interpreter lock. Because Lean owns the
process, its runtime is the only one that schedules editor code.

## Threads

| Thread | Language | Owns | Never does |
|---|---|---|---|
| **Main** | Rust | The window, the OS event loop, IME. It makes the renderer and its surface when the window opens, and drops them when it closes; in between it only leaves word with the render thread | Draw or present; wait on anything, but for the render thread to end as the window closes; run Lean code |
| **Editor** | Lean, a dedicated task | All mutable editor state. The single writer. Pulls events and runs commands and handlers one at a time. In a test whose host is stepped ("Stepped hosts in tests"), the editor thread is the check's own, which takes the same turns of the loop | Block on I/O or long computation |
| **Lean pool** | Lean | Background jobs that compute or await | Mutate editor state; block |
| **Dedicated job threads** | Lean | Work that blocks in a system call: the reload job today | Mutate editor state |
| **Completion pump** | Lean, a dedicated task | Pulling the completion queue and ending the wait each completion names | Run a job; mutate editor state |
| **Render** | Rust | Turning the published scene into frames and drawing them. Shares the layout cache with the editor thread's layout queries (the design; what is built, and the decision it awaits, are under "Sharing state"). As built it owns the renderer alone (the device, the surface, the glyph atlas, the quads kept per row), takes frames from a mailbox, and never lays out. `editor-ffi` starts it when a window opens and ends it when the window closes; idle, it is blocked with no deadline. A headless render session's thread is joined by the session's `stop`, or by its drop | Run Lean code; call layout or a shaper; hold a lock while it draws; touch the window's loop |
| **Services** | Rust | Timers, loading and saving files, child-process pipes, pseudo-terminals, file watches. Each takes a flush, a wait completed behind the work handed to it before (`rust-library.md`). The process's services are statics that live for the process, and their threads end with it. A service a test starts is owned by an `editor_service::Worker`, whose drop stops and joins its thread; the watch service joins its timer thread when its last handle is dropped | Hold editor state; call Lean |
| **Workers** | Rust | Tree-sitter parsing, diff, fuzzy matching over long lists. The syntax worker is built: one thread named `syntax`, started by `editor-ffi` at the first attach, parked while it has nothing to parse, with no deadline when no refresh is scheduled and until the next refresh's deadline on the job clock otherwise, which reparses each attached document from snapshots and the edit log's patches, and parses its injected layers, each whole in its ranges, and holds no editor state. A result is tagged with the revision it parsed and handed out only if no newer revision has been told by then; a stale one is never delivered, and is only the base of the next reparse (`rust-library.md`, "Syntax, as built"). A round takes the session's state lock briefly at its start, to read the injections, and never the other way round, so an edit's touch and a change of injections never wait for a parse; when only the injections changed and they find new layers, the round delivers again at the same revision (`rust-library.md`, "Injections, indentation and text objects, as built"). Once a text has gone the idle interval unchanged after an edit, the worker parses it whole and delivers again at the same revision only when that tree differs from the one delivered; an edit's touch sets the deadline under the worker's queue lock, which no parse holds (`rust-library.md`, "Syntax, as built"). Highlight queries do not run on the worker: they run at frame time, on the thread that lays the frame out (the editor thread, in Lean's publish), over the rows shown only, from the tree delivered last, carried through the edits since; no lock is nested on that path, and none of it waits for a parse (`rust-library.md`, "Highlights, as built"). The diff is built: the diff service, `editor-diff-imara`'s line diff of two snapshots on a thread of its own (`editor-diffs`), answering a job's `diff` request through the completion queue, with an edit script or with hunks of whole lines, so a long diff holds up neither a load nor the editor thread, which only applies the script it answers or draws the hunks as gutter marks. Fuzzy matching over long lists is built, not as a Rust worker but as a job of the loop's own on Lean's task pool: a prompt with more than `Loop.inlineMatches` (250) candidates to match is matched by a match job that runs the prompt's style there, its fuzzy requests answered by the same stateless call as a request of the job port (`JobRequest.fuzzy`); nucleo's own worker was considered and rejected ("Prompts", below; `rust-library.md`, "Fuzzy matching, as built"). The matcher answers in the call, on the thread that asked: the editor thread for a short list, a pool thread for a long one | Hold editor state |

Rust never calls Lean. The main thread and the services push events onto a
queue, and the editor thread pulls them with a blocking call. Measured in
the spike, a key takes 6 to 12 µs (median) from arrival in Rust to the edit
being applied, most of it the thread wake-up.

On macOS the process's real main thread must run the window. Lean runs its
`main` on a thread it creates, so a small C entry point keeps the real main
thread for Rust and starts Lean on a second one. Linux has the same entry
point, reached another way: there the linker gives it `main`'s place
(`--wrap=main`), because an ELF entry symbol would skip the C library's
start-up ([lean-runtime.md](lean-runtime.md), "Build"). The window's loop
runs on that main thread on both.

### Sharing state

Editor state is an immutable Lean value held by the editor thread
(`EditorState`, `lean/Editor/State.lean`: buffers, windows, the frame, the
echo area), which the command loop takes from one event to the next
(`lean/Editor/Loop.lean`). Handing a job a snapshot is handing it that
value. Text lives in Rust ropes, whose
snapshots are cheap; a job or the renderer holds a snapshot handle.

The text snapshot is built: taking one copies none of the text, it never
changes, and the library's object is safe to read from any thread
([text-and-display.md](text-and-display.md), "Text", as built). The hand-off
is built too, in both directions, for the first job that needs it, which
loads and saves files. The rule of the table above is kept: **only the
editor thread writes the text port's tables**. Every text and every snapshot
enters them, and leaves them, in a command.

- **A job reads a snapshot a command took, by the id the command got.** The
  text port's real binding keeps its snapshots in a table behind a
  reference, which it *publishes* and which only its handler writes, in a
  command (`lean/Editor/Text/Real.lean`). What the job runner's file service
  is given is the read half of that table and nothing else, so nothing off
  the editor thread holds anything it could write the table with. A read
  sees the table as it is at that instant: an id a command has released by
  then names nothing, and a save of it is refused as a value. This is how
  the scene crosses to the renderer too, and a snapshot never changes, so a
  reader shares nothing that moves. Documents are not published: a text has
  one writer and no reader but a command. **A job reads a published
  snapshot's text** with one request, `JobRequest.snapshot`, answered at
  once from that read half (`Job.realSnapshots`, over `Ffi.Snapshot.read`):
  the text, or `none` for an id released by then. It waits for nothing and
  moves no clock. This is how completion at point's `words` gathers the
  open buffers' words off the editor thread, from snapshots the asking
  command took (completion's phase 5).
- **What a job makes is the job's until a command takes it.** A load's reply
  names its snapshot by a second kind of id (`JobSnapshotId`), which is not
  an id of the store. The runner holds the library's snapshot for the job
  (`Job.HeldSnapshots`, the runner's own state, as the table of waits is),
  and the job's handle lists what the job holds. The id names a snapshot
  for the job that loaded it and for that job's command, and for nothing
  else: the runner refuses a save of an id the job does not hold, another
  job's included.
- **The job's command takes it into the store, on the editor thread**, with
  a request of the text port, `adopt`. When the editor thread runs a
  finished job's command it hands that run what the job held; `adopt` is
  answered from that, and an id the run was not handed is refused. `adopt`
  is a command and, offered as a job, a type error, checked when
  `lean/Editor/Job.lean` is compiled: the one request that writes the store
  from what a job made cannot be written in a job.
- **The runtime releases what a job held** once the job's command has run,
  or when the job fails, is cancelled or loses its owner. What the command
  adopted is the store's and outlives that.

The judgement in this is that a job's thread may *read* the published
table. The table above forbids a job to mutate editor state, and a job reads
snapshots "requested later" below; reading a value that never changes is
not a write. The stricter alternative, in which a job is lent its snapshots
when it is started and reads no table, needs a way to start a job with
arguments, which the command loop adds; it can be added beside this.

After each command the editor thread publishes the scene (which views show
which text snapshots, with which decorations) to the Rust library. Rendering
reads the last published scene. Layout queries from a command are
synchronous calls answered in the same call (see
[text-and-display.md](text-and-display.md)); the layout cache is the one
structure both threads touch, so its locking is kept per line.

**Who writes the layout cache is awaiting the owner's decision.** The
paragraph above, and the Render row of the table, are the design. The
display pipeline's phase 1 built something else, and the owner has not
chosen between them (plan review of that phase, 2026-11-13):

- **As built: the editor thread is the cache's one writer.** Every write to
  layout's state happens in a call Lean makes from a command: a publish,
  which also builds the frame, and the two queries (`crates/editor-ffi`,
  `display.rs`). The frame is an `Arc` of plain data whose rows share the
  cache's entries, which are immutable, so the render thread (phase 4) is
  to read frames and never write. The display handle keeps its layout
  behind one lock only because a handle is `Send + Sync`; with one writer it
  is never contended. The cost: a resize shows nothing new until Lean
  publishes again, which sits badly with "nothing blocks the window".
- **The design above: two writers, locked per line.** The render thread
  turns the last scene into frames itself, laying out on resize, and the
  editor thread's queries use the same entries.
- **A middle way, compatible with what is built:** the render thread
  breaks the latest frame's kept shaped lines again at the new width,
  writing nothing to the cache, until Lean publishes. An entry keeps its
  shaped line as an `Arc` of a value that is `Send + Sync` and breaks with
  `&self` (`ShapedLine::break_lines`), so the frame would carry it as one
  more field. This is not built.

Phase 4, which builds the render thread, was to have the answer first.
It did not: the owner has not chosen, and the decision above stays open.
Phase 4 (2026-11-14) built on what phase 1 built, the first of the three,
and built it so that the other two need no change to the renderer's port
or to its loop (`crates/editor-render`):

| Thing | Written by | Read by |
|---|---|---|
| The renderer: the device, the glyph atlas and cache, the quads kept per row | The render thread alone, with no lock | Nothing else |
| The mailbox: one slot for a frame and the stamp of its input, behind a lock | Whoever publishes frames: the editor thread, as built | The render thread, which takes what is there |
| The demands: the dirty mark, the animation deadline, the refresh interval and whether the target is hidden (atomics), and the target's size and scale (a small lock) | Any thread, through the loop's handle. As built the main thread leaves word of the size, of damage, of the refresh interval and of hiding, as the window says them, and whoever publishes frames leaves the rest | The render thread |
| The frame journal and the counters | The render thread alone | Any thread, as a copy |

- The render thread never calls layout, a shaper or Lean, and holds no
  lock while it draws: the mailbox's and the target's locks are held only
  to take a value out.
- A frame is an `Arc` of plain data, so handing one over copies nothing
  and the render thread reads it with no lock.
- A resize is a demand. The frame last shown is drawn again on the new
  target at once, so painting never waits on Lean; the new layout appears
  when Lean publishes a frame for the new size. Until then the old frame
  is shown at its old layout, which is the cost named above and is not
  removed.
- A scale goes to two threads, and neither hands it to the other. The
  main thread leaves it with the render loop as part of the target, with
  the size; the renderer sizes its own lines and chooses its masks by
  it. Layout is told it (`Layout::set_scale`) by the thread that lays
  out, which is whoever publishes frames: it reads the scale off the
  resize it pulled from the editor queue and sets it before it lays out
  for that resize's size, under whatever guards the layout. As built
  only the window example's editor thread does (the display pipeline's
  phase 5); the display handle Lean publishes to is never told a scale
  ([text-and-display.md](text-and-display.md), open questions, "A scene
  published from Lean at its window's scale"). The render thread still
  never lays out: a frame laid out at the old scale is drawn once on the
  target at the new one, and the frame laid out for it follows, as with
  a size.
- Under the second answer the render thread would lay out and post to
  the same mailbox itself; under the third it would break the frame's
  kept lines again before it draws. Neither changes the port, the
  mailbox, the scheduler or the journal.

**The thread is started by `editor-ffi`** (the display pipeline's phase 5,
2026-11-14; `crates/editor-ffi/src/render.rs`), for the life of one
window, by a session the window is run with:

- **The window tells; the session leaves word.** The window port has a
  second listener, the drawer, which the window's thread calls with what
  whatever draws in the window needs to know. The session turns each into
  a call on the loop's handle. A call on the handle sets an atomic or
  takes a small lock, and wakes the render thread: the main thread never
  waits for a draw.
- **The main thread makes the renderer and drops it.** A surface on macOS
  is made on the main thread and nowhere else, and whatever was made on
  the window must be gone before the window is. So the renderer is made
  as the window opens, on the window's thread, and sent to the render
  thread inside the loop; and as the window closes, the session stops the
  loop, joins the render thread and drops the renderer on the window's
  thread. That join is the one wait the main thread makes: for at most
  the draw in progress, once, as the window closes.
- **The render thread presents.** Presenting waits for the display's
  refresh. On the main thread that wait would hold up the window's loop:
  input would be stamped late, and the journal's latency flattered.
- **The two loops do not meet.** The render thread waits on the render
  loop's own park, a lock and a condition variable; the window's loop
  waits on the system. Nothing the render thread does has to wake the
  window's loop, and the window's loop is never made to turn: the adapter
  asks for no redraw, and what draws is woken by what the drawer is told.
- **A hidden window is not drawn on.** A window that is occluded refuses a
  draw, and a refused draw is tried again every refresh, which would be a
  timer for as long as the window stayed hidden. The loop is told the
  window is hidden, keeps what is asked, and draws once when it is shown.
  A window is not always said to be hidden: on macOS one that opens is
  not on the screen for its first tenth of a second, and says only that
  it is shown, once it is (seen: nine draws refused meanwhile, one each
  refresh). So a renderer that finds its target hidden says so in what
  it answers, and the loop tries that draw again when it is next told
  anything, which being shown is, and not a refresh later.
- **The journal reads the clock that stamps input**: `editor-ffi`'s input
  clock is the loop's clock too, so a frame's latency is a subtraction on
  one clock.

That the render thread draws, and not the main thread from the window's
own redraw event, **awaits the owner**. The other way needs no second
thread and no join, and blocks the window on every present.

Since the display pipeline's last phase, frames published from Lean reach
the session inside the library: a display bound to the process's presenter
submits each frame it lays out to the loop the presenter targets, from
the editor thread, which is the one thread that publishes. So the editor
thread never waits on the render thread: a submit only leaves word in the
mailbox. The window mode runs the window on Lean's main thread
(`Ffi.windowRun`) and the editor loop on a dedicated task, which asks the
window to close when it ends; the headless mode's `--render` runs a render
session on a thread of the library's with no window. Dropping a headless
session ends it as its `stop` does: its loop is stopped and its thread
joined before the drop returns. In a real window the
session has run with the wgpu renderer under Xvfb (`mise run
linux-window`); on a desktop it is `mise run edit`
(`docs/dev-practices/on-demand-checks.md`, "The editor on a file, on
demand").

## Foreground: commands

A command is Lean code that may change editor state. Commands run one at a
time, in order, on the editor thread.

- **Ordering.** While a command runs, later input queues behind it, so keys
  typed during a slow command are not reordered. Painting continues from the
  last published scene.
- **Interrupt.** An interrupt key (Emacs's `C-g`) raises a flag in the Rust
  library as the key arrives, before the key is queued. Built: the flag in
  `crates/editor-ffi/src/interrupt.rs` ([rust-library.md](rust-library.md),
  "Platform"), what the loop does with it in `lean/Editor/Loop.lean` ("The
  interrupt") and `lean/Editor/Command/Dispatch.lean` ("The guard"), and the
  loop reaches the flag through the watch port (`lean/Editor/Watch.lean`,
  [lean-runtime.md](lean-runtime.md), "The editor's port is a composite").
  - **The primitive is the library's, the policy Lean's.** The library
    raises the flag on the arrival path of the editor queue
    (`window::arrive`, which every window event and every posted one goes
    through), and answers whether it is up. Which key raises it, when it is
    asked and when it is lowered are Lean's.
  - **Which key.** Lean tells the library, when the loop starts: `C-g`.
    What "the same key" means is the chord's rule
    ([keymaps-and-modes.md](keymaps-and-modes.md), "A key as a binding
    names it") and stays in Lean: the library is given the key with a mask
    of the modifiers to compare, and compares words. So shift is not
    compared on a character and is on a named key. Changing the key from
    config is not built.
  - **The flag is a count.** It is up while an interrupt key that arrived
    has not been taken off the queue, and the library counts them. With
    `A`, `C-g`, `B`, `C-g` queued, taking the first `C-g` must not lower
    the flag for `B`, which is still ahead of an interrupt key.
  - **When it is lowered.** The library decides once, at arrival, which
    event is an interrupt key, and marks that event. The loop lowers the
    flag when it takes a marked event off the queue, and for no other
    event, so the two cannot disagree after the key is changed. The key is
    then stepped through the scheme like any other, so a scheme can bind
    it. The lowering is a request of the editor's port, so it is in the
    pure loop, where the model tests see it. A marked event no loop steps,
    one that cannot be read or one that arrives before there is a loop, has
    been taken off the queue all the same: the host lowers for it by the
    loop's rule, and reads the mark of an event it cannot read with the
    decoder's, so the mark's encoding and the rule each have one home.
  - **When it is asked.** Before each request of a command the loop
    dispatched that reaches the library: a text request, a display request
    and a watch request (`EditorM.dispatched`,
    `lean/Editor/Command/Dispatch.lean`, a pure transformation of the
    command's program, so it runs on the models). That transformation is
    the guard's one definition, and its checks run it
    (`ModelTest.guardChecks`): a guard of its own for a program with no
    state request was removed on 2026-11-14, since no host ran it and its
    checks then pinned a rule nothing used. Once the flag is up the
    command's continuation is dropped: the command makes no further
    request, it is rolled back, and the echo area reads
    `<name>: interrupted`. This is the job runner's rule for cancellation
    ("Cancellation"): it is not a reply and nothing is thrown, so a
    `try`/`catch` in a command cannot swallow an interrupt. Asking costs
    one call into the library and one program step for each such request.
  - **A state request is answered without asking.** A request about the
    editor state is pure Lean, answered by the loop from the state it
    holds, not a call into the library, and what the guard bounds is the
    calls into the library. So is a question to the registry or config,
    answered from what the loop was told of them, and a control request,
    which ends the command or runs a registered program inside it
    (`lean/Editor/Command/Registry.lean`, `Control.lean`); the program a
    control request runs is guarded, as the command's own requests are.
    A state request also keeps a move in the history whole
    towards the guard: the last text request of an undo drops the inverses
    it crossed, and the request after it records the moved tree in the
    buffer. A check between the two could stop a command with the inverses
    dropped and the move unrecorded, which no rollback could take back. A
    check before the drop stops it with nothing dropped. So a command that
    makes state requests alone is not interruptible, as one that makes no
    request is not.
  - **Every command is guarded.** A key's command, the driver's
    `run <name>` and a finished job's command all go through the loop's
    dispatch (`lean/Editor/Loop.lean`, "Every command goes through the
    loop"): each is checked, rolled back if it does not run to its end,
    and followed by a scene. So is a major mode's on-enter action, which
    runs inside the command that set the mode. Built by the command loop's
    phase 8; before it the driver's run and a job's command were run bare.
  - **A job is cancelled by a command, not by the flag.** No job reads
    the flag. Under the Vim scheme `C-g` is bound in normal state to
    `keyboard-quit` (`packages/shell/Shell.lean`), which the key runs once it
    has lowered the flag: it cancels the `:!` or filter running in the
    focused buffer's workspace by that workspace's job key (`cancelJob`,
    "Getting results back"), which kills its child, and says
    `<line>: interrupted`, or `Quit` with nothing running. It is made of
    state requests alone, so the flag it lowered cannot stop it.
  - **Only the command is checked.** The loop's own requests (keeping what
    it rolls back to, rolling back, publishing) are not, so a flag that is
    up never stops a rollback or a scene. **The follow is one of them**
    (the command loop's phase 15): before each scene the loop asks the
    display which rows each view shows and places a scroll anchor where
    the cursor is not among them (`lean/Editor/Loop.lean`, "Following the
    cursor"). It is part of the publish, so it is not guarded, and a view
    follows its cursor after a command that was interrupted too, from the
    cursor the rollback put back. A scroll command is a command: it is
    guarded, and one that is interrupted leaves its view's scroll anchor
    and its selection as they were, since the loop keeps and restores
    both markers.
  - **Consequences.** A command for a key queued ahead of the interrupt key
    finds the flag up at its first check and makes no request. An
    interrupt key that arrives while nothing runs interrupts nothing: the
    flag is down again before the next key's command starts. A command
    that makes no request is not interruptible ("Runaway code is not a
    design driver").
- **Rollback.** A failed or interrupted command's edits are reverted as a
  unit. The mechanism is built, in the undo tree
  (`lean/Editor/UndoTree.lean`): the loop keeps the tree's state before a
  command and reverts to it if the command fails, by one inverse of the run
  of revisions the command made. That state may be a point inside an insert
  session's open group, so a command's edits need no group of their own.
  Since the command loop's phase 11 that is the common case for a typed
  key: the loop leaves a buffer's group open while a view of it is in an
  insert session ([keymaps-and-modes.md](keymaps-and-modes.md), "Insert
  sessions"), so a command that fails inside one is rolled back to the
  point of the open group it began at, the session's earlier text stays
  pending, and it is one step with what follows (pinned by
  `ModelTest.dispatchUndoChecks`, with a scheme written in the test whose
  keys begin and end a session). A view's wanted column is editor state,
  so it is rolled back with everything else, and so are the registers.
  - **A command gives up, with its reason** (the command loop's phase 13;
    `giveUp reason` in `lean/Editor/Api.lean`, `ControlRequest.giveUp`,
    `Guarded.gaveUp`, `Loop.Ending.gaveUp`). It is the third way a command
    ends without having run to its end, beside a refusal by the store and
    an interrupt, and the one a command chooses: evil's operator whose
    motion fails is cancelled as Vim cancels it. The dispatcher ends the
    program at that request, with the state the command had reached, and
    applies no continuation; nothing is thrown, so a `try` round the call
    does not go on. The loop rolls it back by the rule below, says
    `<name>: <reason>` in the echo area with no `refused:`, and puts the
    scheme back in its state at rest. The headless host prints
    `gave up: <reason>` for a command run by name. Run where no loop
    dispatches the command, the request changes nothing and the operation
    is refused.
    - *Why not a refusal.* Throwing a `TextError` gives the same rollback,
      and the echo then reads `<name>: refused: bad position`: the store's
      words for something the store did not refuse. A message and a normal
      return would leave the view in insert state after a failed `cj`, and
      make the failed edit the last change.
  - **A command breaks off, with its reason** (`breakOff reason`,
    `ControlRequest.breakOff`, `Guarded.brokeOff`, `Loop.Ending.brokeOff`).
    It ends itself as one that gives up does, at one control request the
    dispatcher finishes the program at, and differs in what the loop then
    keeps: nothing is rolled back. The texts, the markers and the editor
    state the command reached are the loop's, as a finished command's
    are, and the jobs and invocations it asked for are handed to the
    host. The echo area reads `<name>: <reason>`, and the scheme goes back
    to its state at rest, as after a give-up. The headless host prints
    `broke off: <reason>` for a command run by name.
    - *What it is for.* Vim cancels an operator whose motion fails and
      leaves the cursor where the motion got to. Where the motion moved
      before it failed (a counted `b` that reaches an empty first line
      with steps left over), a give-up would put the cursor back, and a
      normal return would leave the view in insert state after `c3b` and
      make the cancelled edit the last change. Evil's operate command
      places the cursor and breaks off
      ([keymaps-and-modes.md](keymaps-and-modes.md), "Operators as
      built").
    - *The command leaves a state that fits the scheme at rest.* The
      scheme forgets the key, so a command that breaks off leaves the
      selection in the shape it found it, and not in the shape of a state
      its key entered.
    - Pinned by `ModelTest.dispatchCommandBreaksOffChecks`, and through
      the headless host by `ConfigTest.hostLoopChecks`.
  - **What is outside the editor is not rolled back: the clipboard.** The
    clipboard is a port (`lean/Editor/Clipboard.lean`), and what a command
    writes there stays when the command is rolled back. The guard stops a
    command before a request it makes of a port, never after its last. So
    a command that writes the clipboard does so as its last request: one
    that wrote it ran to its end. Evil's yank and deletion that name the
    clipboard register edit, place the cursor, and then store, the write
    last ([keymaps-and-modes.md](keymaps-and-modes.md), "Registers"). A
    command that goes on after such a store, which dot repeat's replay of
    a change with an insert session is, has the store keep what it would
    write in the editor state, and writes it itself once everything else
    is done.
  What the loop does with it is built (`lean/Editor/Loop.lean`, "Rollback":
  `Loop.keep` and `Loop.Kept.restore`), as follows.
  - **Before a command** the loop keeps, for each buffer, the state of its
    undo tree once told the text's revision, and, for each window, its
    selection marker and its scroll marker as read.
  - **After a command that was refused or interrupted, or that gave up,**
    each kept buffer's
    tree is told the revision and reverted to the kept state, with the
    user's origin, and each kept marker is placed back. The editor state is
    the one before the command: whatever the command's state requests
    changed (a window split or closed, a buffer added or removed, a mode,
    the echo, a job asked for, a prompt opened or closed) is as it was. An
    open prompt is editor state, so the rollback returns it with
    everything else: a command that asked and then failed leaves no
    prompt, and one that accepted and then failed leaves the prompt open,
    with its text as typed ("Prompts").
  - **The tree that is reverted is the one the command left**, when the
    kept state is a state of its open group. A command can move in a
    buffer's history and record the moved tree. The tree from before the
    command does not know of the move, and the move dropped the inverses
    that tree's edges cross: reverting it would be refused, or would leave
    a tree out of step with the store. So each kept buffer is reverted from
    the tree it has in the state the command left, when that state still
    has the buffer over the same text, and the buffer of the state the loop
    keeps gets the tree that comes back.
  - **A boundary the command set is taken back with its edits** (decided
    2026-11-14). A command can close the open group
    (`BufferId.closeGroup`); the kept state is then no state of the open
    group of the tree it left, though nothing moved. The tree from before
    the command knows of no boundary set since: told the text's revision,
    its open group is everything the command did. So that tree is the one
    reverted, by one inverse of the whole run, and it is the buffer's
    afterwards: the steps the command closed go with the tree the command
    left, the history has no step for the command and nothing to redo, and
    the markers are placed back. Pinned on a command that edits, sets a
    boundary, edits again and is then refused or interrupted
    (`ModelTest.dispatchChecks`).
    - *When the tree from before is good.* Only while none of its edges was
      crossed since: a crossing drops the run the edge held. The loop asks
      the tree the command left whether it still has each of them as the
      tree from before has them (`UndoTree.keepsEdgesOf`), which a move
      over one of them ends for good, there and back or not. A command
      that moved that way is one that moved in the history (below).
    - *A move over a step the command closed itself* leaves those edges
      alone and drops inverses of the command's own run. The store then
      refuses the one inverse, with nothing changed, and the command is
      again one that moved in the history: the tree the command left is
      the one in step with the store.
    - *Why not undo back, step by step.* Moving up the steps the command
      closed (`UndoTree.goTo`) would also restore the text, and would keep
      those steps in the tree as a branch a redo goes to: a redo after a
      failed command would then make part of it again, and in place of
      what the user had undone before it. A command that does not run to
      its end leaves no step.
  - **Nothing is given up until a command has ended.** A request that
    closes a window, removes a buffer or ends a save changes the editor
    state alone. The loop gives up the window's markers, releases the
    buffer's text and releases the snapshot of a save that is no longer in
    flight once the command has run to its end, by comparing the state
    before with the state after. So a command that fails after closing a
    window is rolled back to a window whose markers still answer, and one
    that fails after ending a save to a save in flight whose snapshot
    still reads.
  - **A mark of the saved state is taken back** (decided 2026-11-14, with
    the file commands). A command can mark a state of a buffer's history
    as saved, by recording a tree it marked or by ending a save. The tree
    the command left carries the mark, and it may be the one reverted, so
    the tree that comes back is given the saved state of the tree from
    before the command. Otherwise a command that ended a save and then
    failed would leave a buffer that says "not modified" beside a stamp
    from before the save. The file commands cannot reach this, since a
    save's result is delivered by a command of state requests alone
    ("Getting results back"); any command can make the request, and the
    rule keeps a rollback whole.
  - **Markers are placed back, not left to the inverse.** A marker moves
    with every transaction: a deletion and its inverse do not return a
    marker inside the deleted range to where it was, and a command can
    place a marker with no edit. A revert hands back only the selection a
    transaction carried.
  - **What is not undone**: the texts, snapshots and markers the command
    made, and the scenes it published. The loop publishes the true scene
    right after.
  - **A rollback that is refused is said.** A command that released a
    buffer's text, gave up a window's marker or dropped the inverses of its
    own edits cannot be rolled back. The rest is still rolled back, and the
    echo area ends `; not rolled back: ` and the first refusal.
  - **A command that moved in the history** (an undo, a redo) is not taken
    back: the move stays. The move closed the group, so the kept state is
    no longer a state of the open group, and the tree from before the
    command cannot be reverted to it (above). The loop then reverts the
    group that is open when the command ends, which takes back the edits
    the command made after its last move and leaves the text at the node
    that move reached. The echo area ends `; the command moved in the
    history`, and the windows' markers are left where the store moved
    them. Pinned on a command that undoes, records the move and is then
    refused, on one that sets a boundary and moves over the step it closed,
    and on a state whose history was moved by hand
    (`ModelTest.dispatchChecks`).
    - *Why not move back.* The kept state can be one no move returns to.
      With edits pending, a command that edits and then undoes closes the
      group as one node, whose state is the one after the command's edit.
      The kept state is then a point inside a closed group, and the run's
      inverses are dropped once the edge is crossed, so no request reaches
      it. A rule that works only sometimes is worse than one that always
      does.
    - *Why this is sound.* Every move is whole: one inverse an edge, and a
      move that throws has dropped nothing. The tree keeps every node, so
      what the command undid can be redone and what it redid undone. The
      text is at a state of the history, never between two.
- **Slow commands are logged**, with their duration, so a command that
  should have been a job is easy to find. Built: the loop reads the job
  port's clock, through the watch port, just before a command a key runs
  and just after it, however it ended. When it took longer than the
  threshold (100 ms by default, `Loop.slowAfter`) the step hands back one
  entry, `slow command: <name> took <n> ms`, and the host writes it to its
  log: stderr in the executable, so a fixture's output does not depend on
  how loaded the machine is. Pinned on the models' clock and, through the
  headless host, on the job port's fake clock.

The type of a command is `EditorM α`. It offers no blocking operations: no
"run this process and wait", no "read this file", no "wait for this job".
Long work belongs in a job.

### Quit

Status: decided 2026-11-14 and built, by the command loop's phase 12
(`lean/Editor/State.lean`, "Quit"; `lean/Editor/Api.lean`, `quit`;
`lean/Editor/Loop.lean`, "Quit"; `packages/ex/Ex.lean` for the commands
`quit` and `save-and-quit`; `lean/Editor/Headless.lean` for the host).

A command asks the editor to quit, and the editor quits once it can. A
command cannot end the process.

**Quit reaches the host as editor state that the step turns into
"stop".**

- **Asked to quit is a flag of the editor state**
  (`EditorState.quitting`), set by one state request. It is editor state,
  so a command that asks and then does not run to its end is rolled back
  to a state that was not asked.
- **The editor leaves** when it was asked to quit, no buffer has unsaved
  changes, and no save is in flight (`EditorState.leaves`).
- **The step says stop.** Every step that publishes a scene says stop
  when the state it left leaves, and to go on otherwise. The scene is
  published first, so a quitting command's scene is the last one. A step
  that says stop already ends a host's loop: nothing new crosses to the
  host. The executable's `main` then
  quits the queues and exits, as it does at the end of a script.
- **A quit that cannot go ahead is withdrawn when the scene is made.**
  After the histories were told their texts' revisions, so that "unsaved"
  is right, a state asked to quit in which a buffer has unsaved changes is
  no longer asked. This is where a waiting quit ends without quitting
  because the buffer was edited while it waited.
- **A save that is refused withdraws the quit.** The state request that
  ends a save with no stamp clears the flag, whether or not the buffer is
  modified. A buffer that was not modified has no unsaved changes after
  its save was refused, so the rule above alone would let the editor
  leave, with the refusal unseen and an exit status that says the file
  was written. The state does not keep which save a quit waits for: any
  save that is refused withdraws it.
- **Set aside: a one-shot output of the step**, like the jobs to start. A
  quit that waits for a save must outlive the command that asked, so it
  is state.
- **A window's close request is a quit by `q`'s rule.** The loop runs the
  quit rule itself for it (`Ex.closeRequested`), as it runs a delivered
  command: guarded, rolled back, and followed by a scene, with the echo
  area not cleared first. So it is refused, with `quit: <name> has unsaved
  changes` in the bottom row and the loop running, while a buffer that
  holds a file has unsaved changes; it waits for a save in flight; and it
  is withdrawn by a save that is refused. With nothing unsaved its step
  publishes one scene, the last, and says stop, and the host closes the
  window once that scene is drawn. Command-Q is the key `s-q`, bound to
  the command `quit`, so it follows the same rule; on macOS the
  application menu's Quit takes the chord first, and it reaches the loop
  as the system's quit (below), which runs `quit` too. The loop runs the
  rule and not the command registered as `quit`, so a host handed no ex
  command still closes its window.

**The system's quit is put through `quit`** (decided and built
2026-11-15, the macOS integration roadmap's phase 3:
`lean/Editor/Loop.lean`, "Quit"; `lean/Editor/State.lean`, "Quit";
`crates/editor-platform-winit/src/terminate.rs`).

- **It reaches the loop as an event** (`Event.quitRequested`): Command-Q,
  Quit from the Dock's menu, a logout, restart or shutdown. It is not the
  queue's `quit`, nor the window's close request.
- **The step runs `quit` as an invocation no key yielded**, after it has
  remembered the system's quit (`EditorState.systemQuit`). So it is
  guarded, rolled back and published as every command is, config's
  command named `quit` runs in its place, and the rules above hold of it:
  with nothing unsaved the step says stop, as for `:q`; with unsaved
  changes it is refused and says why; with a save in flight it waits.
- **When the editor does not quit, the system is told once.** When the
  state is not asked to quit after the publish's `settleQuit`, the quit
  was refused, did not ask, or was withdrawn (an edit while it waited, a
  refused save), and the publish asks the frame `keepRunning`
  (`EditorState.answerSystemQuit`) and forgets the system's quit. On macOS
  that replies `NO` to AppKit's wait, which also cancels a logout, as
  TextEdit's unsaved document does. A quit typed in the editor asks the
  frame nothing.
- **A close with the system's quit pending may end the process inside the
  window's run.** This is the window port's rule (`Platform::run`,
  `Platform::close` and `Input::QuitRequested`, in
  `crates/editor-platform/src/lib.rs`), so everything that must happen
  before the program ends happens before the close. A `KeepRunning` asked
  just before the close refuses the quit instead, and the run returns. The
  port's fake models it: it returns all the same and says whether its close
  let a quit go (`ScriptedPlatform::quit_let_go`). On macOS it is AppKit's
  terminate: AppKit waits inside `terminate:`, under winit's run, so the run
  cannot return while one is pending, and once answered `YES` AppKit ends
  the process with status 0.
- **When the editor leaves, its own shutdown runs, and then the system's
  quit goes ahead.** The step says stop; the window mode's closer
  (`Editor.Window.closeOnceEnded`, `lean/Editor/Window/Real.lean`) shuts
  down (the library's children killed and reaped, its watches ended, the
  queues quit: `Editor.Window.shutdown`) and only then closes the window.
  With a terminate pending, the window adapter tells the drawer the window
  is closing and then replies `YES` (`terminate.rs`), so a logout the
  editor goes along with goes on, and nothing that follows the run is
  reached: the exit status is 0, and `--report` and the "nothing could
  draw" line are not printed. With none pending the run returns and `main`
  exits with its status. An ask the editor never heard of (held before the
  window opened, or still on its channel at the close) is answered `YES`
  too, since the editor was leaving anyway.
- **When the editor loop fails, the system's quit is refused.** The closer
  reads the loop's result first, and on an error says `editor: the editor
  loop ended with an error: <error>` on stderr, shuts down, and asks the
  window to keep running just before the close. The adapter finds that
  keep running with the close (`wake`) and replies `NO` to a terminate
  pending, held or waiting (`terminate.rs`), so the run returns, `main`
  exits with status 1, and a logout is not carried out over a crash.

**`quit` refuses while a buffer that holds a file has unsaved changes, and
waits for a save in flight.**

- **A buffer has unsaved changes** when it holds a file, is modified, and
  its text is in another state than the one a save in flight is writing.
- **The API's `quit` checks before it asks.** It tells a copy of each
  file-holding buffer's undo tree the text's revision, as a save does, so
  an edit made earlier in the same command counts. If a buffer has unsaved
  changes it refuses, as a value that names the buffer, and asks nothing.
  The command `quit` says the refusal in the echo area:
  `quit: <name> has unsaved changes`.
- **A save in flight is waited for, not refused and not cancelled.** A
  save is a job, and a buffer is still modified while its save runs: the
  saved mark is set when the save's result is delivered. So a buffer whose
  text is in the state its save in flight is writing has no unsaved
  changes; the quit is asked, and the editor does not leave until that
  result is delivered. The delivery finds the buffer saved and the step
  says stop; or the save was refused, and the quit is withdrawn, with the
  save's refusal in the echo area, whether or not the buffer is modified.
  So `w` then `q`, typed as fast as you like, writes the file and quits,
  and does not quit when the file was not written.
- **A buffer edited after its save began has unsaved changes**, and `quit`
  refuses.
- **A buffer with no file never blocks.** The scratch buffer cannot be
  saved, and `!` is not built, so a rule that counted it would leave no
  way to quit once anything was typed there. This departs from Vim, which
  refuses.
- **Other jobs do not block.** A load in flight and config's jobs are
  cancelled when the loop ends. A reload that is running is abandoned.
- **Set aside: refusing while a save is in flight.** `w` then `q` would
  then fail or pass by timing.
- **Set aside: quitting at once.** The host cancels its jobs when its
  loop ends, the save among them.
- **A quit that waits can wait for ever**, if a save's job never ends.
  The editor goes on answering, and a window's close request waits as `q`
  does, so the close button no longer ends it either: the way out is the
  system's force quit. That is the price of the close button following
  the rule.

**`save-and-quit` is one command: it starts the save, and asks to quit
only if the save started.**

- It saves its target's buffer, reads the state again, and, when that
  buffer has a save in flight, asks to quit. The quit then waits for the
  save by the rule above: the file is written, the result is delivered,
  and that step says stop. The order is fixed by the wait, not by timing.
- **When the save did not start, it does not quit.** A buffer with no file
  says so, and the editor goes on, as Vim's `wq` does with no file name.
- **When the save is refused**, the file having changed on disk, the quit
  is withdrawn and the refusal is in the echo area, for a buffer that is
  not modified too.
- **When another buffer has unsaved changes**, the save starts and the
  quit is refused with that buffer's name: the file is written and the
  editor goes on. Vim does the same.
- It saves a buffer that is not modified too, as Vim's `wq` does.
- **Set aside: a save order that carries what to run next.** An order
  crosses as arguments, and the wait already gives the order.

**What a driver of the editor must do.** A quit that is waiting for a save
has not ended the loop. A script that posts more after `wq`, or reaches
its end, before the save's result is delivered has those lines handled
while the save runs, and the end of a script stops the loop, which cancels
the save. So a script waits for the job after `wq`
([headless-mode.md](../dev-practices/headless-mode.md)). The run then
returns only once the loop has ended (`Headless.withHost`, "Structured
lifetimes"): a driver never has a live loop beside it after its run.

Pinned by `ModelTest.stateChecks`, `stateRequestChecks` and
`apiStateChecks` (the state's rules and the API's `quit`, which also has a
case on the real binding), `dispatchQuitChecks` (the loop: stop, the wait
and the withdrawn quit, with commands written in the test), `exChecks`
(the commands and the ex names `q` and `wq`), `ExTest.Linked.exScriptChecks`
(through the host, on real files), and the two process checks of the
`ffi-test` task, which read the executable's exit status and the file's
bytes.

### Runaway code is not a design driver

A command stuck in a pure loop that never makes an API call cannot be
interrupted, and it holds the editor thread. The window stays alive and
keeps painting, but editing stops until the process is restarted. This is
accepted: decades of Emacs use show it happens rarely and only through
obviously wrong code, and the type split already keeps blocking work out of
commands. There are no hard deadlines and no watchdog.

One emergency measure exists if it ever matters: lowering Lean's
process-wide memory limit makes interpreted code throw at its next
allocation (measured at about 0.1 ms). It fails every interpreted job
running at that moment and relies on an internal function, so it is not
built on.

## Background: jobs

A job is Lean code that may take as long as it likes. Jobs run in parallel
with each other and with commands. The type is `JobM α`.

A job can:
- compute anything pure;
- read immutable snapshots of editor state and text (taken when it starts,
  or requested later);
- await services: run a process, read or write a file, make a request,
  sleep;
- check for cancellation, and is cancelled at every await;
- send results to the foreground.

A job cannot change editor state. There is no `JobM` operation that does.

Interpreted jobs run in parallel: in the experiments, 16 CPU-bound
interpreted jobs finished in 2.3 s where one takes 1.2 s.

**A job running at a restart is not restarted** (session-restore phase 2,
decision 5, as amended in its review). Every job running when the process
ends uncleanly is said stopped by the next start's restore, except one its
owner starts again anyway. A job is one of three kinds, as its owner says
when it registers it:

- **Reported** (`workJob … (reported := true)`): a job a person waits on,
  named. The shell's run, the compile run, project search, and version
  control's apply, hunk apply and commit. The host hands the loop the
  reported jobs running each step (`Loop.Keys.running`), the index lists
  them (`jobs`), and the restore names each in `*restore*`.
- **Restarted** (`workJob … (restarted := true)`): a job its owner starts
  again after the restart anyway, never said. `follow-file`, which
  auto-reload's reconciler arms for each file buffer open, and
  `check-files`, since the restore stats each file it puts back and the
  loop checks every file buffer when the frame gains the focus; the
  workspace's `find-workspace`, `find-mode-markers` and `compile-list`,
  which a file's open starts, as the restore's open of each file it puts
  back does; the gutter's `vc-gutter-head`, `vc-gutter-diff` and
  `vc-gutter-refs`, which its reconciler starts for each buffer it tracks;
  and the restore's own four, since the next start runs its own restore
  and writes its own index. These run whenever a buffer opens, or for as
  long as one is open, so counting them would say something stopped at
  every restart, which is noise, not news.
- **Every other job**, a package's or config's: counted. A Files save, a
  working-set write, version control's reads and shows, a completion
  source's job, config's own jobs. Nothing starts one of them again, so
  its work was lost, and the person is told how much: the host hands the
  count (`Loop.Keys.otherJobs`, `Restore.otherJobs`), the index records it
  alone (`otherJobs`), and the restore says `and M other jobs were
  running: the restart stopped them` in `*restore*`.

The summary's `; N jobs stopped` counts the reported and the other jobs
together. A change of the count alone starts no write of the index
(`Document.compared`): the count is recorded by the next write another
change starts. Otherwise each job's start and its end would start a
write, so a run of short jobs would keep the index writing, and a job that
ends after the write its start caused would start one more; in the
headless fixtures, that write waits on a clock the script no longer
moves. So the count is as current as the index's last write: a job that
starts and the process aborts before the next write, or within the
write's 500 ms debounce, is not said, and one that ended since is still
counted.

As built (`lean/Editor/Job.lean`), a job reaches time, files, processes
and changes on disk:

- **`JobM` is a program over the job port** that may fail with a message,
  so it has `throw`, `try` and `catch`. It is plain data and holds no `IO`.
- **The port's requests are a clock, a wait, a file request and a process
  request**: `now`
  reads the job clock, in milliseconds, and `waitUntil` returns once the
  clock reads a deadline or later. `sleep` is written with the two, and so
  is a `Timer`, which is plain data: the instant of its next tick and its
  period, so its ticks do not drift with the work between them.
- **Loading and saving a file are requests a job awaits**
  (`lean/Editor/File.lean`): `File.load` and `File.save`, each a wait like a
  timer's, completed by the library's file service. **Errors are values**:
  a reply is a result or a refusal, which the job matches on, and nothing
  about a file ends a job or cancels it. A load takes a limit, which is the
  editor's policy and has no default, and replies with the snapshot the job
  then holds, the file's stamp and its line endings. A save names a
  snapshot, one a command took or one the job loaded, and what it expects
  on disk; one that finds another file is refused with what is there. A
  path is a Lean string and must be absolute: the editor has no working
  directory.
- **Running a program is a request a job awaits**
  (`lean/Editor/Process.lean`): `Process.run` runs a command to its end, a
  wait completed by the library's process service, and replies with how the
  child ended and both its streams as bytes, or a refusal as a value: a
  relative directory or program, a program that is not there or not
  allowed, or a stream past the run's limit, which has no default. A
  cancelled job's child is killed with its process group.
- **A child's environment, as built** (`lean/Editor/Process/Environment.lean`,
  `Process.prepared` in `lean/Editor/Job.lean`). The question is "what
  environment does a child started in this directory get?", and the answer
  is the editor's own, then the variables its directory's lookup returns set
  over it, then the command's own `Environment`. The editor's own process
  environment is never changed. `Process.run`, `Process.runWithin` and
  `Process.start` each prepare their command first, as a job program, so the
  model and the runner run the same code; the lookup itself is a raw
  request, so it never looks itself up.
  - *Sources.* Config's setting (`processEnvironment`, the setup port's
    first option): `inherited`, no lookup, children exactly as before;
    `mise` with an absolute path, or with none; and the default `auto`.
  - *Resolution.* `mise` with no path, and `auto` in the window mode, take
    the first of `~/.local/bin/mise` (from `HOME`), `/opt/homebrew/bin/mise`
    and `/usr/local/bin/mise` whose stamp a file request answers; with none,
    `mise` reports "mise is not at …" once for each directory and `auto` is
    `inherited`. `auto` in the headless mode and the checks is `inherited`.
    The first job to resolve the setting keeps the answer in the shared
    state until a reload.
  - *The lookup* runs `<mise> env --json` in the child's directory through
    the process service, with a mebibyte of output and a time limit, 5 s by
    default (`ProcessRequest.runWithin`, a run killed with its group once
    its limit has passed: the runner arms an alarm on the clock and cancels
    the run at the library when the alarm comes first). The JSON object of
    strings is read in Lean, outside `Lean.Data.Json`, which config's
    closure leaves out.
  - *The cache* is one entry for each directory in the state every job of a
    host shares (`JobRequest.environment`, answered at once, as `now` is,
    and as the fuzzy matcher is, `JobRequest.fuzzy`, whose reply is an
    `Except String` since the runner's service may throw;
    `Job.sharedEnvironments` behind a reference). An entry is kept while the
    stamps of `mise.toml`, `.mise.toml`, `.tool-versions` and
    `mise.local.toml` in the directory and each ancestor, read through the
    file port's stamp request before the lookup ran, are unchanged. A
    reload that installs drops every entry. mise's global config and
    environment variables are not stamped: a change there is picked up
    after a reload.
  - *Ordering.* A start in a directory with no entry waits for the lookup
    and then starts its child, in the job; the loop never waits for either.
  - *Failures* (a status other than 0, a signal, output that is not a JSON
    object of strings, a run past its limit, a refusal, no mise) start the
    child with the inherited environment and are reported once for the
    directory until its entry is dropped: the host posts the message to the
    editor queue and says it in the echo area. In an untrusted directory
    `mise env` exits non-zero, which is this path.
- **A streaming child is requests a job awaits, one at a time**:
  `Process.start` starts it with its input, how each output stream is
  framed (lines or bytes) and its bound, and names it for the job;
  `Process.read` waits for the next delivery, every frame read and not yet
  taken, the last saying how the child ended; `Process.write` waits until
  its bytes are in the child's input, or is `inputClosed`; and
  `Process.closeInput` closes the input. A read, a write or a close of a
  child the job does not hold is `noSuchProcess`, answered at once.
- **Watching a file or a directory is requests a job awaits**
  (`lean/Editor/FileWatch.lean`): `FileWatch.start` watches a file, a
  directory's entries or a directory's tree, with the job's window and
  bound, and names the watch for the job; `FileWatch.next` waits for the
  next delivery, every change recorded and not yet taken, once the window
  from its first change has passed. A `next` of a watch the job does not
  hold is `noSuchWatch`, answered at once. A watch does not outlive its
  job.
- **A line diff is a request a job awaits** (`lean/Editor/Diff.lean`):
  `Diff.lines` diffs two snapshots, named as a save names its source, under
  a line limit that is the editor's policy, a wait like a load's completed
  by the library's diff service, and replies with an edit script, byte
  counts and ranges and never text, or a refusal as a value. A command
  applies the script (`TextId.applyScript`) in time linear in its steps and
  the bytes it puts in, refused if the text has moved past the revision the
  script was made for. `Diff.hunks` asks the same service for the hunks of
  whole lines instead, which the version-control gutter turns into marks
  (`packages/version-control/VersionControl/Gutter.lean`).
- **A project search is a request a job awaits** (`lean/Editor/Grep.lean`):
  `Grep.start` names a root, a pattern, open buffers' snapshots as overlays
  (named as a save names its source), limits and a bound, and replies with
  the search, named for the job; `Grep.next` waits for the next delivery,
  the files found and not yet taken with their matches' rows and offsets,
  and, in the last, how the search ended. The library's grep service walks
  and reads on a thread of its own and holds a search back while its reader
  takes nothing, so memory is bounded. A `next` of a search the job does
  not hold is `noSuchSearch`, answered at once, and a search does not
  outlive its job. `project-search` posts each delivery to the editor as a
  command of its own (`packages/project-search/ProjectSearch/Run.lean`).
- **A package's service is a request a job awaits** (`lean/Editor/PackageService.lean`):
  `PackageService.ask` names a service a package brought
  (`Package.services`), an operation and plain arguments, and waits for
  the service's reply, a `Dynamic` the package's typed wrapper reads back
  (`askAs`), or a refusal as a value. The program's edge hands the runner
  every package's services by name (`Headless.shipped`,
  `Headless.packageServices`, `Job.Services.packages`); a service it was not given is `noSuchService`
  at once, with no wait. The wait is a service wait: it keeps the job's
  unit, the service completes it through the completion queue as the
  core's do, and a cancel withdraws it at every package service
  (`Handle.drop`), so the service keeps nothing of it and posts no
  completion for it. The fixture `echo`'s crate is the proof
  ([packages.md](packages.md), "Behind a port, so it stays replaceable").
- **No request carries a promise.** A request is plain data; how a wait is
  completed is the runner's business. A snapshot of editor state arrives as
  a further request of this port, each with a reply type, a
  clause in the model, an answer in the runner and a property in the
  contract.
- **Cancellation is not a reply.** No reply says "cancelled" and nothing is
  thrown into a job; see below.
- **A wait is not a command**, checked when `lean/Editor/Job.lean` is
  compiled: a wait offered at `EditorM Unit` is a type error, alone and
  after a text request in a `do` block, and so are a file request and a
  process request. So "a
  command may not block" is pinned beyond `IO`.

The port has a pure model (`lean/Editor/Job/Model.lean`: a clock, the
instant at which the job is cancelled, and the files the job reaches,
`lean/Editor/File/Model.lean`) and a contract
(`lean/Editor/Job/Contract.lean`). Its list of the clock's properties is
inequalities, run three ways: against the model and against the runner over
a fake clock by `lake test`, and against the runner over the Rust timer
service by `contract-test`. Its list of the file requests' properties is
run three ways too: against the model, against the runner over a fake of
the file service, and against the runner over the library's file service on
real files in a temporary directory. A file loaded and saved without edits
is byte for byte what it was, in all three, for LF, CRLF and bytes that are
not UTF-8.

### Getting results back

- **Message.** The job finishes with a value, and a foreground handler
  receives it: `spawn job (fun result => …)`. The handler runs as a command.
- **Proposed edit.** The job builds a transaction against the text revision
  it read and submits it. The foreground maps it through any edits made
  since (the same position mapping anchors use) and applies it, or rejects
  it as stale if the text it touched has changed. A formatter, a rename, or
  an agent's edit all take this route.

As built, the message route, and not yet the proposed edit. What the
proposed edit has to build on (2026-11-13,
[text-and-display.md](text-and-display.md)): a transaction is plain data
that a job can build and a command can apply; one built for another length
of text is refused; and the foreground can ask what changed since the
revision the job read, as one patch of ranges. What it does not have: the
log keeps no text, so it cannot supply the change sets to map a stale
transaction through. Where those come from is open.

- **The loop spawns work of its own beside the starts** (completion's
  phase 3): a step hands back `Loop.Stepped.spawns`, work it made (a
  prompt's match job, which no registered name and no plain arguments can
  carry), each with its key, its label and its owner, and the host starts
  each after the step's cancels and starts, as a job of that owner under
  that key (`Headless.Running.launch`). Its result comes back as any job's
  does.
- **A job finishes with a command.** What is spawned is a `Work`, a job
  whose value is an `EditorM Unit`: the handler applied to the job's
  result. The handler is applied where the job ends, on the job's thread,
  which only builds the command. So the type of a job's result never leaves
  the job, and no port refers to itself: this settles the question the
  program type left open ([lean-runtime.md](lean-runtime.md)).
- **The wake-up.** When a job has ended, however it ended, the runner calls
  what the runtime gave it, which posts an event to the editor queue from a
  Lean source, with the job's id. The outcome (finished with a command,
  failed with a message, or cancelled) stays in the job's handle.
- **The handler runs as a command.** The editor thread meets the wake-up in
  its turn, takes the result from the job table, and has the command loop
  run the command as it runs any command (`Loop.deliver`): guarded, rolled
  back if it does not run to its end, and followed by a scene. It does not
  clear the echo area, as an invocation does: a result that arrives in the
  background should not wipe what the user is reading. `config-test`
  records the thread each line of output comes from and requires a job's
  line to come from the thread that prints a command's.
- **Config registers a job by name** in `setup`:
  `job "count" count fun n => …`, where `count : Unit → JobM Nat`, or, for
  a job that takes arguments, `jobWith "double" double fun n => …`, where
  `double : List Argument → JobM Nat`. `setup` starts nothing. The runtime
  that owns the job table starts a registered job when it is asked to: for
  the headless driver's `spawn <name>`, and for a command.
- **A command starts a job by its name, with arguments** (`startJob`,
  `lean/Editor/Api.lean`; built by the command loop's phase 8). The
  request is plain data, a name and arguments: it cannot carry the job,
  which ends in a program over the port the request belongs to. So:
  - the loop refuses, as a value the command sees, a name no job is
    registered under (`noSuchJob`);
  - the start is kept in the editor state until the command ends, and the
    loop then hands the starts of a command that ran to its end back to
    its host with the step (`Loop.Stepped.starts`). A command that is
    refused or interrupted starts no job;
  - the host starts each, for the owner that registered it, and the result
    comes back as above, through the queue's wake-up. Events queued before
    the wake-up are handled before it, by the queue's order, so a job's
    result never lands in the middle of what the user typed meanwhile;
  - **the loop starts jobs of its own** too, handed back with the step's
    the same way: after each publish it starts one `check-files` for the
    file buffers that are due a check for a change on disk, as the frame
    gains the focus, as a buffer is switched to and at a buffer's first edit
    (`lean/Editor/Loop.lean`, "Files that changed on disk"), where that job
    is registered. It is one stat a file, and no watch. Under auto-reload,
    which is off by default, it also starts a `follow-file` job for each
    file buffer, keyed by the buffer (`JobStart.key`), and hands back the
    keys of follows to end (`Loop.Stepped.cancels`);
  - **a keyed job is cancelled by its key**: the host keeps a map from key
    to job id, starting a job of a key cancels the running one of that key,
    and a cancel ends the job, finished and not delivered or not, by
    `Jobs.cancel`, which takes it out of the table, so its command never
    runs. Before this only removing an owner or shutdown cancelled a job.
- **A job posts a command while it runs** (`post`, `lean/Editor/Job.lean`;
  2026-11-16): a request of the job port that holds an invocation, a
  registered command's name and plain arguments, as a command starts a job
  by name. It is answered at once, as a request for the shared
  environments is, waits for nothing and moves no clock: there is no
  back-pressure through it, so a job that posts often batches by itself.
  The runner hands the invocation, on the job's thread, to what its host
  gave it, unless the job was cancelled. The headless host keeps it in a
  mailbox, with the job's id, and posts an event to the editor queue under
  a source of its own (`Collaborators.posts`); the editor thread takes the
  job's oldest post for each such event and, while the job is still in the
  table, runs it as a delivery labelled `job <id> <name>` (`runPosted`,
  `lean/Editor/Api.lean`). So a job's posts run in the order it made them,
  each between two events, and all before its own command, whose wake-up
  is posted after its last post. A cancelled or removed job's posts are
  dropped, as its result is. The loop's driver on the models holds a job
  at each post until the test says it arrives (`Loop.Driver.posted`,
  `lean/Editor/Loop/Driver.lean`).
  - **a command may key a job and cancel one** too: `startJob name
    arguments (key := some key)` starts the job under a key, so it ends the
    running job of that key first, and `cancelJob key` asks for the job of
    a key to be ended. The cancels are kept in the state with the starts
    (`EditorState.Outbox.cancels`) and handed back in `Loop.Stepped.cancels`,
    ahead of the loop's own; a command that is refused or interrupted
    cancels nothing. `:!` runs its child under one key a workspace, and
    `C-g` cancels it by that key ([keymaps-and-modes.md](keymaps-and-modes.md),
    "The ex command line");
  
  An owner other than the registering one (a buffer or a view, whose jobs
  end with it) is not built. On the models the loop's driver
  (`lean/Editor/Loop/Driver.lean`) is the host: it runs each job on the job
  model and delivers its command when the test says the job is finished
  (`ModelTest.driverChecks`). It hands snapshots across as the runtime
  does: a job reads the snapshots commands took, its command is handed
  what the job loaded and nothing else, and what a job held is released
  once its command has run, or when the job fails.
- **Opening a file is a command, a job and the job's command**
  (`packages/files/Files.lean`, built by the command loop's phase 9), the
  first use of this route by compiled code:
  - the command (`Files.open`) shows the buffer that holds the path, if
    one does, and starts nothing. Otherwise it starts the job `load-file`
    with an order, plain arguments: the path and the view it was called
    in. It makes nothing and judges nothing;
  - the job loads the file, under the editor's limit of 1 GiB, and
    finishes with the order and the reply. A refusal is a value in the
    reply;
  - the job's command makes the buffer when the result is delivered: a
    text of the snapshot the job loaded, a buffer over it called by the
    path's base name (or that name and `<2>`, `<3>`, when a buffer has
    it), the file attached, and the buffer shown. On a refusal it says
    `cannot open <path>: ` and the refusal's sentence in the echo area,
    and the window still shows what it showed;
  - the path is matched to an open buffer twice, when the command runs and
    again when the result is delivered, so two opens of one path in flight
    make one buffer: the second delivery shows it and takes nothing in;
  - the buffer is shown in the view the command was called in, or in the
    focused view if that view was closed while the file loaded. When the
    view so chosen is the minibuffer's, which shows no other buffer, it is
    shown in the window the open prompt was asked from, and the prompt
    stays open ("Prompts");
  - the command as it is registered (`open-file`) opens the path that is
    its first argument, and with no path asks for one with a prompt
    ("Prompts"), naming itself as the command that receives the answer;
  - several paths open one after another, each after the last's result is
    delivered, so the last is shown last: the order carries the paths still
    to open, and the job's command opens them whatever became of its own
    file. One load per path at once would show whichever finished last,
    since jobs run in parallel. An interrupted delivery is rolled back with
    what it started, so the paths after it are not opened; and two opens of
    several paths in flight at once load beside each other. The files
    Finder and the Dock open the app with take this route
    ([lean-runtime.md](lean-runtime.md), "The window, as built").

  An empty buffer made when the command runs and filled later was set
  aside: the window would change before the file is known to exist, and a
  refusal would have to undo it. So what the user types while a load is in
  flight goes to the buffer the window still shows, and is handled before
  the load's result, by the queue's order. Every refusal of the file port
  takes that one route to the echo area. A start that is refused, where no
  job is registered under the name, is said there too.
- **Saving a buffer takes the same route** (`Files.save`), with one thing
  more, a record in the editor state:
  - the command takes a snapshot of the buffer's text, keeps the state its
    undo tree is in, starts the job `save-file` with an order (the buffer,
    the snapshot, the path, and the stamp the buffer holds as what the
    save expects), and records the save as in flight on the buffer;
  - the job saves the snapshot and finishes with the order and the reply;
  - the job's command makes one state request, which ends the save in
    flight: given the stamp the save answered, it records the stamp and
    marks the kept state as saved; given a refusal, neither. It then says
    `wrote <path>`, or `cannot save <path>: ` and the refusal's sentence.

  **A save's result cannot be interrupted.** The job's command makes state
  requests alone, which are answered without asking the flag ("A state
  request is answered without asking"), so the interrupt key arriving as
  the result is delivered cannot leave a file written and a buffer that
  does not know it. That is why the snapshot is released by the loop,
  after the command, and not by the command: a release is a request of
  the text store, where a command can be stopped. The record also refuses
  a second save of the buffer while one is in flight, when it is asked: it
  would expect the stamp from before the first and be refused as changed
  on disk though nothing but the editor wrote the file.

  **A save that is not started records nothing.** The command asks for the
  job before it records the save, and records it only when the job will be
  started; where no job is registered under the name it releases its
  snapshot and says so. A buffer is never left "being saved" with no job
  to end the save. A compiled job is not cancelled by a reload and returns
  every refusal as a value, so a save that was started is ended unless the
  loop itself ends first.

### The idle signal

Status: built by deterministic-test-concurrency phase 4. A check that
something did not happen, or a driver's wait that something cannot end,
answers at idle instead of after a deadline.

The count and its idle are the subject of the hosts' and the runner's
waits, and a stand-in for one piece of work anywhere else: a test that
waits for idle to know that its own load has ended infers it from
something shared. So the reads of the count and the waits built on it are
marked inferred waits (`lean/Editor/InferredWait.lean`), and
`linter.inferredWait` (`lean/Lint/Wait.lean`, a Lean plugin the build loads,
which no module of the editor imports) refuses them outside the modules
whose subject they are and the tests that mirror those; each site that remains is listed,
with the phase that removes it, in `docs/dev-practices/inferred-waits.md`.

**What idle is.** A host is idle when all three hold:

1. **Up to date.** The editor thread has handled every event posted before
   the driver's marker.
2. **Nothing can run.** The host's activity count is 0, and it was 0 with
   the same epoch when that marker was posted.
3. **Nothing due.** The fake clock, if the host has one, holds no wait that
   is due.

**The activity count** (`lean/Editor/Job/Activity.lean`) is the number of
units held, each a piece of work that can still end by itself, and its
epoch moves at every change of it. A unit is taken before what it covers can
run or post, and given back after:

| Unit | Taken | Given back |
|---|---|---|
| A job while it can run | `Job.spawn`'s `start` section, before its task; and a parking wait's end, in the `wake` section of `Completions.finish`, on the thread that ends it | In the `park` section that records a wait only a test ends as the job's (`Handle.enter`), or in the `done` section after its `finished` (`Handle.retire`). Each is one critical section of the table of waits ("The runner's protocol, modelled") |
| A wait on a service that ends it by itself (the real file, process, diff and grep services, real timers and watches) | Nothing of its own: the job keeps its unit through the wait | |
| A handle's request (`Services.fileWorked`) | Before the port's start | In the wait's action, after `noted` and the resolve |
| The reload job | `reduce`'s `.start`, before its task | `reloadJob`'s `finally`, after its counted post |
| An event the reload, a job, a pause or a hint delay posted | `Collaborators.postCounted`, before the post | The loop, once it has handled the event (`Collaborators.counts`), or at once when the queue refuses it |
| A pause's or a hint delay's wait in flight on a clock that ends it by itself | At its arm | When it fires or is withdrawn |

A wait that only a test can end holds no unit: the fake clock's
(`Timers.outside`) and the fake watches' (`FileWatches.outside`). That is
why a job asleep on a clock nobody moves is idle, and one asleep on a real
timer is not. A flush (`Services.flushed`) holds none either: it is its
observer's, not the program's.

**A parked job's wait can be withdrawn.** A job gives its unit back for
such a wait in the same critical section that records the wait as the
job's (its `park`, `Handle.enter`), and a job cancelled on its way in
withdraws the wait in that section instead and keeps its unit. So idle
means more than that nothing can run: every parked job is in a wait a
cancel withdraws (`Handle.cancel`), which is what the loop's end and an
owner's removal rely on, and a job cancelled on its way into a wait holds
its own unit until it has ended. The order the other way round, the unit
first, let a host read idle and end its loop while the job's thread was
between the two steps: the cancel found no wait, and the job withdrew its
own after the host's bracket had returned. With the two in one section
there is no such place to be, and the model's counterexample shows the old
order breaks `cancel_finds_running_or_recorded` ("The runner's protocol,
modelled"). Pinned, on one thread's order, by the protocol contract's park
property (`ModelTest.protocolContractChecks`, `ConfigTest.protocolContractChecks`):
a job held just after it gave its unit back, a cancel made there withdraws
its sleep; and by `ModelTest.activityRunnerChecks`: a job cancelled while
the clock is asked for its sleep never lets the count read 0 before its
end. A
test that needs the event itself, the wait recorded, waits on that `done`,
never on the fake clock's arrival, which comes inside the clock's `start`,
before the runner has its answer (`withdrawingHeld`,
`lean/ConfigTest/Editor/Headless.lean`).

**A cancelled job's last step can be waited for.** The loop's end cancels
its jobs and does not wait for them: a cancelled job ends on a pool thread,
and the runner then calls its `finished`, which posts its wake-up, and
gives its unit back. In the editor that wake-up goes to a queue that has
been quit and is refused. A test's real host posts to the library's queue,
which the next host of the process shares, so there the wake-up arrived
during a later check, where it was handled and published a scene: seen on
`ubuntu-24.04` under the stress loop, in "a wait's later rounds publish
nothing" (stress run 45095260790) and, in the Linux container, in the
stepped check after a real host's. So a job's handle carries a promise the
runner resolves as its last step for the job (`Job.Handle.finishedRan`),
and the loop's end hands a task for every job cancelled and not yet done
(`Job.Services.unsettled`), those it has just cancelled and those an
owner's removal or a keyed cancel cancelled before it, to
`Collaborators.endCancelled`, which does nothing in the editor; a test
stage's waits on them (`Editor.Test.Linked.Stage`), so nothing of a test
host's jobs comes after its bracket has returned. Pinned by
`ModelTest.activityRunnerChecks` (the promise, with the job's `finished`
held) and by `ConfigTest.scriptChecks`' "a run that reaches its script's
end disposes only after its loop has ended…", whose job's wake-up is held
until the loop's end has handed over what it waits on.

**Why the epoch.** The count alone can be 0 at the marker's post, go to 1
when an earlier event's handler starts a job, and be 0 again when that job
has ended and posted after the marker. Every unit is taken before the post
it covers and given back after it, so a post made while its poster holds a
unit is either handled before a marker posted after the unit's end, or seen
as a moved epoch. A post made while its poster holds another unit needs
none of its own: an environment's report is posted from a job's thread
inside a job request, or from the editor thread while it handles the
reload's wake-up, a counted event.

**What is outside idle**: Rust's own posters (the FfiTest feeders, the
window), the syntax worker, which `Ffi.syntaxSettle` covers, and the
journal's unobserved writes, which `journalled` waits for by a flush.

**The readouts a test waits on outside idle** (deterministic-test-concurrency
phase 6). Each is a test readout, not a path the editor takes: a wait on an
event its owner signals as the thing happens, bounded only by a hang guard,
never a poll. Each takes the guard as a `HangGuard` (`Editor.Bound` in Lean,
`editor_wait` in Rust), and none takes a number of milliseconds; the C
functions Lean calls take a guard's milliseconds and build the guard at
the edge. In Rust they are banned by clippy outside their own tests, their
adapters' contracts and the C functions (the root `clippy.toml`), and so are the
syntax session's `wait_for` and `wait_exact` with the bindings'
`Syntaxes::settle` and `settle_exact`, the grep service's
`until_held_back`, the live-handle wait and the script feeds' join. In
Lean the ones that infer done from something shared are marked
inferred waits (`Ffi.awaitWaiting`; `lean/Editor/InferredWait.lean`).

- **A render loop's rest** (`RenderHandle::wait_resting`, for C
  `editor_ffi_render_await_rest`): the step that records rest signals it,
  under the lock the wait reads the rest under.
- **The render park's wait** (`CondvarPark::when_waits`, a `#[cfg(test)]`
  hook of `editor-render`'s own tests): it fires under the park's lock
  just before a wait goes into its wait, so a test knows the wait found no
  notification and is waiting, on the hook and not on a window of time.
- **A live count coming down** (`editor_ffi_live_await(kind, target,
  bound_ms)`, `crates/editor-ffi/src/live.rs`; kinds 1 snapshots, 2
  documents, 3 counters): each free signals a wait under way, so a test
  whose handle a finaliser frees on another thread waits on the free; a
  free with no wait under way takes no lock.
- **A script feed's end** (`editor_ffi_events_script_join(feed,
  bound_ms)`): `editor_ffi_events_script_feed` returns the feed's id (0
  when refused) and keeps the feeder's thread in a process-wide table,
  and the join waits for the feeder to end and joins it, so a Rust poster
  a test starts never outlives the test.
- **A pull parked** (`Queue::await_waiting`, C `editor_ffi_events_await_waiting`,
  `Ffi.awaitWaiting`), **a streaming child held** (`Service::wait_held`,
  `editor_ffi_processes_await_held`, `Ffi.processesAwaitHeld`) and **the
  scripted window's run parked** (`ScriptedPlatform::wait_parked`,
  `editor_ffi_window_await_parked`, `Ffi.windowAwaitParked`): the pull, the
  reader or the run notifies a Condvar of its own as it parks, under the lock
  its wait then releases, so a test that has seen it knows the thing is in its
  wait. The scripted window's record keeps the close in its place
  (`WindowAsked.close`), so a check asserts an order instead of sleeping to
  make one.
- **A fake reaching a state** (`FakeClock.arrivedAt`, `FakeFiles.takesArrivedAt`,
  ConfigTest's `Gate.arrived`, the fake process service's `reads_waiting` and
  its ground's `ends`): resolved in the same step that makes the state, or at
  once if it already holds.
- **The winit loop's requests carried out** (`probe::await_requests_handled`),
  counted on the main thread.
- **The pool held** (`Pool.holdAll expected guard`, `Pool.expected`): each
  task's start resolves a counter; nothing is decided by a task that does
  not start.

**What a test may still wait on time for.** Three things, each a value of
its own type, so a bound says which it is and a bare number of
milliseconds does not compile (AGENTS.md, "Deterministic concurrency in
tests"; `lean/Editor/Bound.lean`, and `crates/editor-wait` in Rust): a
**hang guard** (`HangGuard.on <event> <ms>`), the bound on a wait for an
event that must come, which only a hang reaches (`Editor.Test.Linked.hangGuard`
and the other guards, set to ten times the slowest the event was seen to
take under the stress loop's load: 260 000 ms for `hangGuard`, from a
config check of 13.2 s on macOS, 10.4 s in the Linux container and 25.1 s
on `ubuntu-24.04`, and 120 000 ms for the guards of events nothing slower
was measured for); a **hang guard run out on purpose**
(`HangGuard.held <what> <ms>`), where a check holds something for good and
pins the hang; and **real time under test** (`RealTime.under <timing> <ms>`),
where the timing is the subject: a lower bound ("not before the limit"),
which load only makes pass more surely, or a real clock's deadline being
waited out. Every bounded wait takes a `HangGuard` (`Job.awaitWithin`, the
hosts' waits, the bindings' readouts, and in Rust the readout waits and
`editor_wait::recv`/`wait_while`), and the one sleep is `RealTime.sleep`.
`Editor.Bound` owns the clock reads a bound needs; anywhere else a raw
`IO.sleep`, `IO.monoMsNow` or `IO.monoNanosNow` fails `lake build`
(`linter.rawClock`), and in Rust a raw sleep, timed receive, timed
condition wait, `Instant::now` or poll fails `mise run lint` (clippy's
`disallowed-methods`). A measurement of real time, a bench or
`config-test --timings`, says so with `set_option linter.rawClock false`
and its reason. A negative decided by a window ("nothing happened within N
ms") is none of these: it is decided at idle, after a flush or another
barrier, or by a forced order. An upper bound on latency is never a
result: the auto-reload's one second is a measurement (`config-bench`'s
`bench-auto-reload` row), not a check.

**Per host, never per stage.** A host whose collaborators track it
(`Collaborators.tracksIdle`: a test stage's and the headless mode's) starts
with a count of its own (`Headless.start`), so a late step of an earlier
host's job on a shared stage cannot reach a later host's. The window mode
tracks nothing: it carries `Activity.untracked`, whose steps do nothing, and
its waits look at the progress again as it changes, as they always did.

**The driver's wait** (`Host.waitWhile`, `lean/Editor/Headless.lean`) goes in
rounds. A round reads the count, posts a marker and waits on the marker's
promise, which the loop resolves once it has published its progress after
it. Only the first round's marker publishes a scene, as a settle's and a
join's always did (an `advance`'s posts none that shows); every later round
posts a `Signal.probe`, which publishes nothing, so how many rounds a wait
took changes no scene count. The wait then answers `settled` when what it
is for is over; at idle it answers its idle outcome, `working` for a join
and a stall for an advance; when the count moved during the round it goes
round again; and otherwise it blocks on the count's next change
(`Activity.changedSince`) or the loop's end.

**One verdict, one set of kinds.** That judgement of a round is one pure
function, `Round.judge` (`lean/Editor/Headless/Wait.lean`, beside `Wait`),
read through `Wait.Kind.judge` (`lean/Editor/Headless.lean`) by both
drivers' waits, the real host's and a stepped host's ("Stepped hosts in
tests", below), which differ only in how a round reaches the loop and what
a block waits on. What each kind of wait waits for is one value too,
`Wait.Kind`: `settle`, `join`, `idle`, `quiet`, `indexed`, `advance clock
ms` and `handled`, each carrying what is busy, the idle outcome, the hang
outcome, its name and whether its marker publishes. `Host` and `Stepped`
forward a kind to `waitWhile`, and the script runner and the config tests
reach it through `Driven` (`lean/Editor/Headless.lean`, the runner's port
both hosts implement), so a change to what a settle means, or to the idle
rule, reaches every wait at once. The kinds that infer "done" from the idle, the
job counts or the fake clock (`join`, `idle`, `quiet`, `indexed`,
`advance`) are marked inferred waits, and so are a kind's constructor
and its `busy` and `still`, so no check builds such a wait from the parts
outside the modules whose subject it is; `Driven` keeps its `waitWhile`
private to `Editor.Headless` and hands out only its named waits. The verdict
is pinned by `ModelTest.waitRoundChecks`, on the model alone.

**Wait guards.** The bound of a driver's wait is a wait guard (`waitGuard`
and `answer`), named apart from the loop's end's (`guard`, `hung`, `grace`,
`abandoned`), so the two cannot be wired together by mistake. A wait that
reaches its guard says the hang once through `waitHung`
(`Headless.waitHangLine`, in the guard's own words, `HangGuard.hang`:
`editor: a hang: <the guard's event> had not come within M ms: the <wait>
on line N`) and fails the run as a hang (`Failure.reloading`,
`unanswered` or `busy`, each described as `a hang: …`). `working` and
`stalled` are never a guard's outcome. A check's waits pass
`Editor.Test.Linked.hangGuard`, long enough that only a real hang trips it.
`waitBlocked` is the wait's hook for a test: it is called each time the
wait is about to block, with `"answer"` before the editor thread's answer
and `"running work"` before a block on work still running, and a check
lets a held step go on it, never on a guard. It is to the wait what the
Rust `when_shutdown_waits` hook is to a teardown.

**Cost.** The editor thread pays one comparison of an event's source
against four ids per event, and one step of a reference only for the
counted events; a job's start, park, wake and end each pay one such step;
a marker one look at the armed marker and one resolve. The window mode's
steps are closure calls that do nothing. Measured on an 18-core Mac, the
medians and 99th percentiles of `mise run job-bench` and `mise run
journal-bench`, two runs each, before and after the count, are below.

**Measured cost** (2026-11-21, an 18-core Mac, idle; before: 7996fa6f, after:
the count in the runner and the host; `bench-jobs`' hosts keep the count,
`tracksIdle`). Median / 99th percentile, µs, of each run:

| `job-bench` row | Before, run 1 | Before, run 2 | After, run 1 | After, run 2 |
|---|---|---|---|---|
| idle | 21.6 / 64.7 | 21.1 / 45.6 | 20.5 / 31.2 | 18.5 / 34.9 |
| 64 jobs each sleeping 1 ms | 31.6 / 105.2 | 24.8 / 89.0 | 24.0 / 85.0 | 24.0 / 90.6 |
| 18 interpreted jobs computing | 23.9 / 397.3 | 21.3 / 35.0 | 21.6 / 473.4 | 21.9 / 645.5 |
| 36 interpreted jobs computing | 26.5 / 82.6 | 21.8 / 42.0 | 24.8 / 720.8 | 22.0 / 36.7 |
| idle again | 22.4 / 68.7 | 21.1 / 36.9 | 21.5 / 35.2 | 21.1 / 28.4 |

`journal-bench`'s nine rows (µs per insert) had medians of 3.4 to 3.9 and
3.3 to 3.7 before, and 3.4 to 4.7 and 3.3 to 3.7 after, with 99th
percentiles of 4.3 to 14.2 before and 4.1 to 20.3 after. It runs the
reconciler and the journal's hand-off with no host, so the count is not on
its path, and its spread is the machine's. Every median after is within the
spread of the two runs before; the 99th percentiles of the computing rows
move by hundreds of microseconds between runs of either, which is the pool
under load, not the count.

**Pinned by** `ModelTest.activityChecks` (the count alone),
`ModelTest.activityRunnerChecks` (the runner's accounting, forced at a
wait's end, a wait due at once, a cancel in a park and a real-service
wait), the handle's contract on both file ports
(`Editor/Job/HandleContract.lean`, `handleCounts` and `jobLoadCounts`),
`ConfigTest.idleChecks` (what holds a unit through a host, that a
wait's later rounds publish nothing, and that a late event just before
idle, a job's start of its sleep held or its result on its way, does not
make idle early), and the forced settles of `ConfigTest.moduleHostChecks`
and `scriptChecks` ("a settle after a reload whose root first imports Lean
waits for the reload's end", "a run's settle waits for the reload's end"),
whose reload is held at a gate only the wait's `waitBlocked` opens. The
loop's end waiting for its reload, and a check's bracket's grace, are in
"Structured lifetimes".

### Stepped hosts in tests

Status: built by deterministic-test-concurrency phase 5. Most of
`config-test`'s host checks run with no loop thread: the host's loop is
stepped on the check's own thread. The checks that still start a loop
thread or a real service live in the wiring set's modules, each of which
states the adapter its checks cover, and `lake build`'s `linter.realHost`
confines them there (`docs/dev-practices/real-thread-checks.md`).

**One turn, two drivers.** The headless loop is one turn per event
(`Running.turn`: handle the event, then give back the unit of the activity
count it came under), the progress it publishes (`Running.progress`) and its
end (`Running.wind`: cancel the jobs, withdraw the pauses and the hint
delay, wait for the reload after `endWaits`), over collaborators prepared
as a host's start prepares them (`Collaborators.prepared`). The real loop
(`Headless.loop`) takes the turns on its dedicated task, pulling the
library's editor queue. A stepped host (`Headless.withStepped`,
`lean/Editor/Headless/Stepped.lean`) takes the same turns on its caller's
thread. What a check runs is the host's own logic: the reload reducer, the
registry, the journal and the restore, with the stage's fakes and the real
elaborator. Only the transport and the thread change, so a mutation of the
host kills a stepped check as it killed the real one (the phase's mutation
tables).

**The queue is a port.** The core posts to the editor queue through
`Collaborators.queue` (`lean/Editor/Headless/Queue.lean`): the library's
(`Queue.library`, `Queue/Real.lean`, the only queue module that imports the
library) for every real host, or an in-memory FIFO (`Queue.Memory`) that a
stepped host drains. Its contract (`Queue/Contract.lean`) runs against both,
in `model-test` and `contract-test`. The stepped bracket installs its own
memory queue whatever the collaborators carried, and a real host refuses
collaborators whose queue a stepper drains (`Queue.Puller`), so a host's
posts and its pulls are never on two queues.

**The wait's rounds, and the lost wake-up.** `Stepped.waitWhile` has
`Host.waitWhile`'s signature, outcomes and kinds (`Wait.Kind`). A round
takes the queue's next-push task (`Queue.Memory.arrived`) and the count's
reading, drains the queue through the turn, then is judged by the verdict
the real wait takes (`Round.judge`, above); its block is on the first of
the next push and the count's next change. The push matters: an event
posted after the round's drain found the queue empty, under no unit of its
own (a request, an environment's report), with the count unchanged, would
be missed by a wait on the count alone, or by one that armed the next-push
task only as it blocked. Pinned by `ConfigTest.steppedChecks`' forced
interleaving, a push from the busy of a settle with no marker, after the
drain: shown failing on a variant that blocks on the count alone and on one
that arms the next-push task at the block.

**The stepped bracket's end.** Its wait for a reload still running is
guarded as a real host's loop's end is: past `guard` the hang is said once
through `hung`; with `grace` the bracket then gives up as a hang, handing
the reload's task to `abandoned`, and with none it waits on. Pinned by a
`ConfigTest.steppedChecks` check that holds the reload at a gate `endWaits`
does not open, with a guard and grace of 0.

**Scene counts match.** The first round enqueues the wait's marker, which
publishes the scene a real host's marker does; later rounds enqueue nothing,
as a real host's probes publish nothing. Pinned by a check that runs the
same requests on both hosts and compares the published counts.

**The runner's protocol on a stepped host.** A stage's services take the
fake recorder (`Job.Services.recorder`), so a stepped check reads the trace
of the runner's transitions and holds a job's thread at one, and its loop's
end records `loopEnd` once every job cancelled is done, those cancelled
before it by a keyed cancel or an owner's removal included. Pinned by
`ConfigTest.protocolContractChecks`: the trace replays on the model, a
loop's end after a keyed cancel and a reload's removal of config's jobs,
each job held at its resume until the end hands it over, records `loopEnd`
after both are done, and a job held just after it gave its unit back is in
a wait the loop's end withdraws ("The runner's protocol, modelled").

**A wait over the fakes.** Status: built by host-tests-on-fakes phase 5. A
driver whose collaborators are the fakes it steps (the job services'
fakes, the session journal's and the syntax service's) hands the stepped
bracket their work (`Stepped.Work`, one piece of it on the caller's
thread, `false` when none can run; the kit's `SteppedFakes.work`,
`lean/Editor/Test/Linked/Stepping.lean`), and its waits are then judged at
the rest of the fakes, never by the activity count. Each time round the
queue's next push is armed and the first round posts the kind's marker, as
before; then rounds drain the queue through the turn and step the fakes
until one moves nothing, which is the **rest** (`Stepped.toRest`, phase 4's
`Session.round` order); and the rest is judged by `Rest.judge`
(`lean/Editor/Headless/Wait.lean`), a verdict with no field for the count:
settled once the wait is no longer busy; with a reload in flight
(`Progress.reloading`), a block on the queue's next push, the reload's own
wake-up, and the hang once its guard has run out; and otherwise the kind's
idle outcome at once, `working` for a kind with none, never a hang. The
reload is the one wait off the thread: over the fakes every job's code,
completion, delivery and journal order runs on a step on the caller's
thread, the fake clock moves only on an `advance`, and a wait due when it
starts completes at once (`FakeClock.start`); the reload's task runs the
real elaborator. A `restarted`'s wait (`Stepped.awaitEnd`) is the loop
brought to rest, ended or `none` at once, and a turn that ends the loop for
a restart publishes the plan in the progress, as the real loop does. With
no work handed (every phase 1 to 4 stepped check), the wait is the round
above. Pinned by `ModelTest.restVerdictChecks` (each branch of the
verdict) and `ConfigTest.steppedRunChecks`, whose first check runs a
spawn, an advance and a join on a host that keeps no count, so a wait that
read the count would block until its guard.

**The runner on either host.** The script runner (`Headless.runOn`) is
written on the port both hosts implement, `Headless.Driven`
(`lean/Editor/Headless.lean`): its requests, the window's input, its waits
(private to `Editor.Headless`, reached through the named waits), its
progress, how its loop ended, its fake clock and what a `restarted` waits
on (`awaitEnd`). A real host's is `Driven.ofHost`, a stepped one's
`Driven.ofStepped`. A run's host comes from a `Hosting` value, a bracket
that hands its body the host's `Driven`: `Hosting.real`, under the real
entry points (`Headless.run`, `runFrom`, `runAndDispose`, whose signatures
are unchanged), and `Stepped.hosting`, under `Stepped.run` and
`Stepped.runFrom`. A script's `abort` calls the run's `onAbort`: the CLI's
ends the process with status 134 (`abortProcess`), a stepped run's throws.
Pinned by a `ConfigTest.scriptChecks` check that runs a script through
`runOn` over a hand-written `Hosting` and `Driven` and requires every
directive at the port in order and `abort` at `onAbort`.

**Limits.** A stepped host cannot bound a turn: a turn held inside an event
holds the check's thread, so a check that holds the editor thread inside an
event, or whose subject is the loop thread or the library's queue, stays on
a real loop (A1 to A7 in the page above). A check that holds something a
turn waits on drives that one drain from a dedicated task it joins, and
lets every hold go in a `finally`.

### Recording fakes for the host's background collaborators

Each collaborator that does background work a host check would otherwise
wait on has a recording fake a check hands the host (host-tests-on-fakes
phase 3). The rules every one keeps:

- **It records each order it receives, with the thread that handed it,
  and that thread is the check's own.** An order from the host arrives on
  the editor thread, which on a stepped host is the check's. A job's
  request arrives on the job's thread, and a stepped run gives the runner
  the fake scheduler (`Job.FakeScheduler`, through `Services.scheduler`),
  which runs a job's code only when the check steps it, on the check's
  thread: so the request is made, and recorded, there, and its reply taken
  there on the step that finished its wait. `ModelTest.runStepped` asserts
  that every order its fakes recorded, every piece of the job and every
  completion was on the check's thread.
- **It answers only in `step`**, on the thread that calls it: every
  completion, delivery and drain. Nothing is worked, and no drain ends,
  before the check steps.
- **It starts no thread** and calls nothing that does: its state is a
  reference and the promises it hands out.
- **It is quiescent once stepped to its end**: nothing is left unworked and
  no drain waits, so a check that ends there leaves nothing to drain.

**One step point.** The job services' fakes do not each step: in their
step mode (`FakeAnswer.onStep`) each hands its completions to one fake pump,
as the real services hand theirs to the library's one completion queue, and
the check steps that pump. So the fakes' answers come in one due order, as
the real wiring's do, and a host check has one call to step.

Each fake and its real adapter run one shared contract: over the fake in
`model-test`, and over the real adapter in `contract-test`, where the real
run waits on its own flush, handle or wait, never on a count or the idle.

| Port (today's type) | The fake a host check gets, and how | How a host check gets it | Contract module | Fake's run | Real adapter pinned in |
|---|---|---|---|---|---|
| Session journal, `Headless.Journal` (`Editor/Headless/Journal.lean`) | `RecordingJournal` (`Editor/Headless/Journal/Fake.lean`), through `Collaborators.journal`, made over a stage by `Stage.recordingJournal` | `Stage.recordingJournal`, recorded with a stepped stage's fakes | `Editor/Headless/Journal/Contract.lean` | `ModelTest.journalContractChecks` | `ContractTest.journalContractChecks` (`Journal.real`, held by `FileHold`, its own flush) |
| Completion pump, `Job.CompletionSource` (`Editor/Job/Pump.lean`) | `Job.FakePump` (`Editor/Job/Fake.lean`), handed to the stepped fakes of the job services (`FakeAnswer.onStep`); a check steps it, or runs `pumpFrom` over its `source` | `Stage.stepped` (`SteppedServices.pump`) | `Editor/Job/PumpContract.lean` | `ModelTest.pumpContractChecks` | `ContractTest.pumpContractChecks` (the library's queue, each completion a file-service flush, each property on its own wait); Rust `completer_contract` (its `EACH_REPORTED`, over `RecordingCompleter` and a real `Service`), a test waiting on its own request (`RecordingCompleter::wait_reported`) |
| Scheduler, `Job.Scheduler` (`Editor/Job/Runner.lean`): where a job's code runs | `Job.FakeScheduler` (`Editor/Job/Fake.lean`), through `Services.scheduler`; a check steps it, or hands it to `FakePump.runToEnd` beside the pump | `Stage.stepped` (`SteppedServices.scheduler`) | `Editor/Job/SchedulerContract.lean` | `ModelTest.schedulerContractChecks` | `ModelTest.schedulerContractChecks` (`Scheduler.pool`, Lean's task pool, each property on its own task) |
| Files, `Job.Files` | `FakeFiles` with `answer := .onStep pump`, through `Services.files`; run to its job's end by `FakePump.runToEnd` with a fake scheduler | `Stage.stepped`, over the check's `FileModel`, learning published snapshots from the stage's table | `Editor/Job/Contract.lean` (`fileProperties`), `FlushContract`, `HandleContract` (H-order among them) | `ModelTest.fileFailures` (its stepped run), `flushContractChecks` (the stepped rigs), `handleContractChecks` (the stepped H-order) | `ContractTest.fileFailures`, `flushContractChecks`, `handleContractChecks` (`realFiles`, held by `FileHold`, each property on its job's outcome, its handles or its flush) |
| Diff, `Job.Diffs` | `FakeFiles`' diff side, in the same step mode, through `Services.diffs` | `Stage.stepped` | `Editor/Job/Contract.lean` (`diffProperties`), `FlushContract` | `ModelTest.fileFailures` (stepped), `flushContractChecks` (the stepped diff rig) | `ContractTest.fileFailures`, `flushContractChecks` (`realDiffs`, the diff flush) |
| Grep, `Job.Greps` | `FakeFiles`' grep side, in the same step mode, through `Services.greps` | `Stage.stepped` | `Editor/Job/Contract.lean` (`grepProperties`), `FlushContract` | `ModelTest.fileFailures` (stepped), `flushContractChecks` (the stepped grep rig) | `ContractTest.fileFailures`, `flushContractChecks` (`realGreps`, the grep flush) |
| Processes, `Job.Processes` | `FakeProcesses` with `answer := .onStep pump`, through `Services.processes` | `Stage.stepped`, over the check's `ProcessModel` | `Editor/Job/Contract.lean` (`processProperties`, the stream properties among them), `FlushContract` | `ModelTest.processFailures` (its stepped run), `flushContractChecks` (the stepped process rig) | `ContractTest.processFailures`, `flushContractChecks` (`realProcesses`, each job's outcome; the held child only a cancel ends) |
| File watches, `Job.FileWatches` | `FakeFileWatches` with `answer := .onStep pump`, through `Services.fileWatches` (still `outside`: a job in a parked `next` holds no unit) | the stage's own (`Stage.new`), answering on the check's `change` | `Editor/Job/Contract.lean` (`fileWatchProperties`), `FlushContract` | `ModelTest.fileWatchFailures` (its stepped run, the processes stepped beside it), `flushContractChecks` (the stepped watch rig) | `ContractTest.fileWatchFailures`, `flushContractChecks` (`realFileWatches`, each job's outcome, the watch flush) |
| A package's service, `PackageService` (`Editor/PackageService.lean`) | `Job.FakePackageService` (`Editor/Job/Fake.lean`) over the package's pure model, `answer := .onStep pump`, through `Services.packages`; a hand-off of a child to the crate (`Spec.handOff`) taken from the process fake (`FakeProcesses.handOff`) | `Stage.stepped`'s `packages`, over each spec handed (`SteppedServices.packages`) | `Editor/Job/Contract.lean` (`packageProperties`, on a `PackageRig`) | `ModelTest.packageServiceChecks` (the model and the stepped fake), `fakeHandOffChecks` (the hand-off's refusals and end, after `editor_service::stream`'s contract) | echo's `EchoTest/Linked/Echo/Real/Job.lean` (`Echo.Real.service`, each job's outcome, the flush) |
| A package's service with state of its own, `PackageService` | a package's own fake (`Job.PackageFake`, `Editor/Job/Fake.lean`), made over the stepped services' table and pump (`FakeAnswer.onStep`), which may hold a request until an order of the check's, or of another job, makes its reply, as a session's long-poll `next` does (`agents-api`'s `AgentsApiTest.Fake.packageFake`) | `Stage.stepped`'s `packageFakes` (`SteppedServices.packageFakes`), whose `quiescent` the stage's own joins | the package's own (`agents-api`'s `AgentsApiTest/Contract.lean`) | `ConfigTest.packageFakeChecks` (a counter written in the check); `agents-api`'s `AgentsApiTest/Linked/AgentsApi/Session.lean` (AC3) | `acp`'s `AcpTest/Linked/Acp/Real/Contract.lean` and `Real/Session.lean` |
| Syntax service (its deliveries), behind `Collaborators.syntaxTree` | `FakeSyntaxService` (`Editor/SyntaxTree/Fake.lean`), its handler the stage's syntax tree, made over a stage by `Stage.fakeSyntaxService`, each step posting `parsed` to the stage's memory queue; the questions' answers stay the model's | `Stage.fakeSyntaxService`, recorded with a stepped stage's fakes | `Editor/SyntaxTree/DeliveryContract.lean` | `ModelTest.syntaxDeliveryChecks`; the fake's `learn`, highlight, injection and detach by `ModelTest.syntaxFakeChecks`; the maker on a stepped host, its step's `parsed` taken by the loop, by `ConfigTest.stageMakerChecks` | `ContractTest.syntaxDeliveryChecks` (`RealSyntaxTree`, `Ffi.syntaxSettle` of its own snapshot); the `parsed` event on the library's queue by `FfiTest.syntaxChecks` |

A host check gets every one of them in one call: `Stage.stepped`
(`Editor/Test/Linked/Host.lean`) gives a stage's host the job services'
fakes (`SteppedServices`, `Editor/Test/Linked/Services.lean`), and the
journal's and the syntax service's makers record theirs with them. The
session's steps (`Session.step`, `stepUntil`, `ranStepped`) run them on the
check's thread, in one fixed order, after draining the host's queue, until
nothing moves, and wait for nothing; the loop's end steps the jobs it
cancels; and the bracket (`onStage`) fails a check that left any of them
holding work. A stepped stage refuses the library's services
(`Stage.overFiles`), and a real host refuses a stepped stage
(`onRealStage`, `withRealShippedHost`): a real thread's answer beside a
stepped fake would make "nothing can run" racy again. The makers are
pinned by `ConfigTest.stageMakerChecks`.

The host's own use of each is pinned over the fake: the journal's by
`ConfigTest.journalOrderChecks`, which drives a stepped host and asserts
the base, edit-record and remove orders it hands, in order, on the check's
thread, and that the drain ends only on the check's step.

### Prompts

Status: decided 2026-11-14 and built, by the command loop's phase 10; a
prompt's candidates by its phase 14 ("Candidates", below), the
sources they come from by completion's phase 1, sources that answer
later and matching off the editor thread by completion's phase 3, and
sources a command filters by project navigation's phase 1.

| Built | Where |
|---|---|
| The open prompt, the minibuffer's buffer and window, opening and closing | `lean/Editor/State.lean` ("Prompts"), `lean/Editor/State/Request.lean` |
| `prompt`, `acceptPrompt`, `cancelPrompt` | `lean/Editor/Api.lean` ("Prompts") |
| The answer handed back with the step; an invocation no key yielded | `lean/Editor/Loop.lean` ("Prompts": `Loop.Stepped.answered`, `Loop.invoke`) |
| The hosts that run the answer's command before the next event | `lean/Editor/Loop/Driver.lean` (`Loop.Driver.took`), `lean/Editor/Headless.lean` (`Running.took`) |
| `minibuffer-accept`, `minibuffer-cancel` and the minibuffer's mode | `packages/minibuffer/Minibuffer.lean`, `packages/minibuffer/Minibuffer/Compiled.lean` |
| `open-file` asking for its path | `packages/files/Files.lean` (`openCommand`) |
| An invocation a command asks to be run after it, with no prompt | `lean/Editor/State/Request.lean` (`StateRequest.invoke`), `lean/Editor/Api.lean` (`invoke`) |
| `ex` asking for its line, and running the answer's command | `packages/ex/Ex.lean` (`exCommand`, `run`) |
| A prompt's candidates, records, their listing and the choice; setting them and choosing | `lean/Editor/State.lean` ("Prompts": `Candidates`), `lean/Editor/State/Request.lean` |
| Completion sources, the query and the candidate record; their model, fake and contract | `lean/Editor/Completion.lean`, `lean/Editor/Completion/Candidate.lean`, `lean/Editor/Completion/Fake.lean`, `lean/Editor/Completion/Contract.lean` |
| Sources registered by name; a named source run inside the asking command; the names of the sources registered in a category, for a prompt that asks for one | `lean/Editor/Config/Registry.lean` ("Sources": `sourcesIn`), `lean/Editor/Setup.lean` (`defineSource`), `lean/Editor/Command/Dispatch.lean` (`ControlRequest.askSource`, `RegistryRequest.categorySources`) |
| Matching styles: the interface, its model and contract, the fuzzy and orderless styles; their registration and config's choice by category | `lean/Editor/Completion/Style.lean`, `packages/completion/Completion/Styles.lean`, `lean/Editor/Completion/StyleContract.lean`, `lean/Editor/Config/Registry.lean` ("Styles"), `lean/Editor/Setup.lean` (`defineStyle`, `useStyle`, `useStyleFor`) |
| `prompt` with candidates from sources, `setCandidates`, `chooseCandidate`; accepting the chosen candidate | `lean/Editor/Api.lean` ("Prompts") |
| The listing, made before each scene from what the prompt's style answers, the style chosen by its category from the matching the host hands | `lean/Editor/Loop.lean` ("Prompts": `Loop.listed`, `Loop.Keys.matching`), `lean/Editor/Completion/Style.lean`, `lean/Editor/Fuzzy.lean` |
| `minibuffer-next`, `minibuffer-previous` and the roles the mode fills with them | `packages/minibuffer/Minibuffer.lean` |
| Sources that answer later: `Reask`, `Later`, the asking source a prompt holds, its job's order and batches, `sourceJob`, `minibuffer-candidates` | `lean/Editor/Completion/Candidate.lean`, `lean/Editor/Completion/Later.lean`, `lean/Editor/Setup.lean` (`sourceJob`), `packages/minibuffer/Minibuffer.lean` |
| The reconciler of a prompt's jobs: a source's job started and started again, the match job spawned, closing cancelling them | `lean/Editor/Loop.lean` ("Prompts": `Loop.completionJobs`, `Loop.matchWork`, `Loop.Spawn`), `lean/Editor/Headless.lean` (`Running.launch`, `Running.publish`) |
| The match job: the listing made on a pool thread over the job port's matcher, its delivery, a failed match | `lean/Editor/Loop.lean` (`Candidates.listing`, `Loop.inlineMatches`), `lean/Editor/Job.lean` (`JobRequest.fuzzy`, `Job.embedFuzzy`), `lean/Editor/State.lean` (`listMatched`, `matchFailed`) |
| A filtered source's candidates marked with the style's ranges, in their order, none dropped; the size that chooses inline or a match job counting them | `lean/Editor/Loop.lean` (`Candidates.listing`, `Loop.listed`, `Loop.completionJobs`), `lean/Editor/State.lean` (`Candidates.passingSize`, `Candidates.listingSize`) |
| Sources a command filters: a lister, a filter fed its output with the typed text as an argument, the first records in one batch | `lean/Editor/Completion/Filtering.lean` |
| A run that keeps the head of its standard output | `lean/Editor/Process.lean` (`ProcessRequest.runHead`, `Process.Head`), `lean/Editor/Job.lean` (`Process.runHead`), `crates/editor-process/src/service.rs` (`Service::start_head`, `RunResult::Cut`) |
| Displays: the interface, its model and contract, the minibuffer display and its rows; their registration and config's choice by category | `lean/Editor/Completion/Display.lean`, `packages/completion/Completion/Displays.lean`, `lean/Editor/Completion/DisplayContract.lean`, `lean/Editor/Config/Registry.lean` ("Displays"), `lean/Editor/Setup.lean` (`defineDisplay`, `useDisplay`, `useDisplayFor`) |
| The candidate list: the sheet shown in the publish, kept on the prompt, the place that grows and never shrinks, and the list's view above the minibuffer's | `lean/Editor/State.lean` ("The minibuffer's place": `displayed`, `Prompt.tallest`, `cutStrip`, `candidateListRect?`), `lean/Editor/Loop.lean` (`Loop.candidateListView`, `Loop.Keys.displaying`) |
| The `:!` history and the ex names as the ex line's candidates, from two sources | `packages/ex/Ex.lean` (`exCommand`, `historySource`, `namesSource`), `lean/Editor/Api.lean` (`exNames`) |
| An answer for the input scheme: `minibuffer-ask`, the reserved continuation `InputScheme.answerName`, and the loop handing the answer to the scheme | `packages/minibuffer/Minibuffer.lean`, `lean/Editor/InputScheme.lean` (`answered`), `lean/Editor/Loop.lean` ("Prompts": `Loop.answer`) |
| Keys pressed by an invocation: the reserved name `InputScheme.keysName`, which the binding search invokes with the keys of the binding accepted, and the loop feeding them to the scheme from rest | `lean/Editor/BindingSearch.lean`, `lean/Editor/InputScheme.lean` (`keysInvocation`), `lean/Editor/Loop.lean` ("Prompts": `Loop.pressed`) |

Pinned on the models by `ModelTest.stateChecks` and `stateRequestChecks`
(the state's operations), `promptChecks` (the loop, its host on the
models, the commands and the mode: the acceptance criteria),
`candidateChecks` (the listing, the scene's fields for it, choosing
and accepting by keys, and the sources a prompt is asked with),
`sourceContractChecks` (the sources' contract), `setupChecks` and
`registryChecks` (sources registered by name), `dispatchStateChecks` (a
named source run inside the asking command) and
`dispatchGiveUpChecks` (what is given up); on the models and the real text
binding by the cases of `lean/Editor/Api/Cases.lean`; through the headless
host over the real library and the real elaborator by
`ConfigTest.promptChecks`; and on the executable by the fixtures
`tests/headless/prompt` and, for candidates with the library's matcher,
`tests/headless/candidates`. Sources a command filters are pinned by
`ModelTest.filteringChecks` on the job model and the loop's driver, and by
`ContractTest.filteringChecks` over the real process service with the
fixture `tests/completion/filter` standing in for fzf; the head run by the
process port's contract (`JobContract.processProperties`) and the process
service's (`editor_process::contract::RUN_HEAD`).

**An answer can be the input scheme's.** A key whose edit needs a text
typed in the minibuffer, as Vim's `/` needs its pattern, cannot complete at
the key, and the grammar has no command to name as a continuation: the
edit is the scheme's. So the scheme yields `minibuffer-ask`, which opens a
prompt whose continuation is the reserved name `InputScheme.answerName`;
`Loop.invoke`, the one entry every host already runs an answer through,
hands that answer to the scheme (`InputScheme.answered`) and runs the
invocation the scheme yields for it as it runs a key's. No host changes,
and no command can be registered under the reserved name.

A command can need a string from the user: a file name, an ex command. It
cannot wait for one. A command may not block, and while a command runs no
key is handled, so the keys of the answer would never arrive. Emacs waits
in a recursive edit, a command loop run inside the command; a blocked
minibuffer read is what wedged `edmacs`. Nothing here runs a loop inside a
command.

**A command waits for an answer by naming the command that receives it.**

- `prompt label continuation initial` opens the prompt and returns at
  once. The asking command runs to its end like any command. When the
  prompt is accepted, the continuation's command runs, as a command, with
  the answer.
- **The continuation is an invocation**: a command's name and plain
  arguments, of the asker's own. It is plain data, so a request of the
  editor's port can hold it, the editor state that holds it keeps its
  derived equality, and a test can compare it.
- **The command is looked up by its name when the answer arrives**, in the
  registry as it then is, exactly as a key binding's name is. So after a
  reload the answer runs the new config's command of that name, never a
  closure of the old config, which a reload forbids ("Reload": no command
  of the old config runs after the install). A name no command is
  registered under says `<name>: no such command` in the echo area, as a
  binding to such a name does. The name is not checked when the prompt is
  asked for, for the reason a binding's is not: the registry may change
  before the answer.
- **The answer is the command's first argument.** The command is run with
  the answer, a string, and then the continuation's own arguments.
  `open-file` already reads its path as its first argument, so an
  invocation of `open-file` with no argument is a continuation as it
  stands. The asker's own arguments follow, so a command can carry what it
  needs across the wait (a buffer's number, a flag).
- **What it costs**: two prompts in a row are two commands, the second
  asked by the first's continuation. That is what a continuation is.

What was set aside:

- **A prompt awaited from a job.** Four reasons, each read off the code.
  - A job is started by the host after its command has ended, and whatever
    it asks of the editor comes back through the queue, behind the keys
    already there ("Getting results back"). A prompt opened that way would
    open after the keys typed meanwhile, which would then run in the
    asking window: with `:` and `w` typed quickly, `w` would be a motion.
    Opened inside the command, the prompt has the focus before the next
    key is looked up.
  - A job cannot change editor state, so the answer would still be used by
    the command the job finishes with. The job adds a thread hop and
    removes no continuation.
  - It needs a request of the job port that the editor thread answers,
    with a clause in the job model, an answer in the runner and a property
    in the contract run three ways. Every wait today is completed by a
    library service.
  - A job has an owner, and a reload that installs cancels config's jobs.
    Every reload would withdraw the prompt of a command of config's.
- **A function kept by the loop or by the registry.** A request cannot
  carry it ([lean-runtime.md](lean-runtime.md), "A request that carries a
  program over its own port"); kept past a reload it would run old
  config's code; and the editor state could no longer be compared.
- **A recursive edit**, as above.

**One prompt at a time.** Asking for a prompt while one is open is
refused, as a value the command sees (`alreadyOpen`), with nothing made and
nothing changed. So is asking where no window is focused to ask from
(`noWindow`), which is the editor with nothing in it that a command run
bare finds. The command says so or does something else. A continuation can
ask for the next prompt, because its own is closed by then. Replacing the
open prompt was set aside: it would drop the first command's continuation
without a word. So was a stack of prompts: it needs several minibuffer
windows in one place, and neither the command line nor completion needs
it.

**The open prompt is editor state**, and the minibuffer is a buffer and a
window of that state ([text-and-display.md](text-and-display.md), "Views
as built"). While it is open no command is in flight: every command that
runs meanwhile is one whole command.

**Accept and cancel are commands over one request.**

- **Accept** reads the minibuffer's text, which is the answer, and makes
  one request of the editor state that closes the prompt with it.
  **Cancel** makes that request with no answer, and nothing else. With no
  prompt open each is refused, as a value.
- **Closing** removes the minibuffer's window, empties its buffer's slot,
  and gives the focus back to the asking view, the view that was focused
  when the prompt was asked for. Given an answer it also records the
  continuation with the answer as its first argument.
- **Closing and recording the answer are one request**, and a request
  about the editor state is answered without asking the interrupt flag ("A
  state request is answered without asking"). So accepting cannot be
  stopped between the window closing and the answer being recorded: it
  happens whole, or the command is rolled back with the prompt open.
- **The loop gives the minibuffer up by the rules that exist** ("Nothing is
  given up until a command has ended"): the window is gone, so its markers
  are given up, and the buffer's slot is empty, so its text is released,
  once the accepting or cancelling command has run to its end. The scheme
  is told the view is closed. No new rule.
- **The focus goes to the asking view even if the user moved it
  meanwhile**, so the answer's command runs with the window the prompt was
  asked in, which is what a command that asks expects.
- **When the asking view was closed while the prompt was open**, the
  prompt stays open. On closing, the focus goes to the first window of the
  tree, in drawing order, and the answer's command runs with that window.
  A view's id is never used again, so the asker cannot come to mean
  another view. This is `open-file`'s rule for a file that finishes
  loading after its view was closed. Cancelling the prompt when its asker
  is closed, and refusing to close the asker, were set aside: both make a
  window command's result depend on a prompt it knows nothing of.

**The answer's command runs as a step of its own, before the next
event.**

- The answered invocation is kept in the editor state until the accepting
  command ends (`EditorState.Outbox.answered`), as the jobs a command asked for
  are. After a command that ran to its end the loop takes it out and hands
  it back with the step (`Loop.Stepped.answered`). A command that did not
  run to its end answers nothing.
- **The host runs each answered invocation before it pulls another
  event**, as an invocation no key yielded: the echo area is cleared, the
  command is looked up, and it is called with the focused window, the
  invocation's arguments and no keys. The host takes that step in as it
  takes any step in, and an answer's command that hands back answers of
  its own has them run the same way. So a key typed after the accept key
  is handled after the answer's command.
- **Why the host and not the accepting command's step.** The host holds
  the cells of the stores, and a command over a store is made over the
  cell as it is when the command is looked up. Run inside the accepting
  command's step, an answer's command would be looked up before that
  step's write was written back. As a step of its own it is like every
  other command: one rollback, one scene, one log entry, one ending.
  `ConfigTest.promptChecks` pins the case: a command over a store that
  accepts and adds one, and a continuation over the same store that adds
  one, leave two. Two hosts carry the rule, the driver on the models and
  the headless host, each with a check that a key sent after the accept
  key is handled after the answer's command; a third host must do the
  same.
  Running it inside the accepting command, as an on-enter action runs
  inside the command that set the mode, was set aside for this, and
  because a refused answer's command would then roll the prompt open again
  under the accept command's name.
- **A chain that never ends** (an answer's command that asks and accepts
  for ever) is runaway code. Each link makes text requests, so the
  interrupt key stops it at the next one ("Runaway code is not a design
  driver").

**A command has another command run after it the same way, with no
prompt.** Built by the command loop's phase 12.

- **A command cannot hold another command.** A command is a program over
  the editor's port, the registry is the host's, and the one way a
  command had another run after it was a prompt's continuation.
- **A command can have another run inside it, where the other is to be
  part of it** (`runCommand name call`, `ControlRequest.runCommand`; the
  command loop's phase 13). The loop puts the named command's program
  before the rest of the asking command's, as it puts a mode's on-enter
  action: guarded, answered from the same state, one step of the history
  with the asking command, rolled back with it, and said under its name
  when it fails. The reply says whether a command was registered under
  the name; it cannot hold the command, since a command is a program
  over the port the reply is part of.
  - The name is looked up as a key's invocation is: the loop makes what
    the dispatcher is told of the registry's commands from the lookup
    `Loop.run` makes, so config's command of a compiled command's name is
    the one run.
  - A command run this way that asks for a store to be written gives the
    asking command up: only the command the loop runs has its write
    written back.
  - Its first user is evil's dot repeat, which replays a change with the
    command the change's own keys ran
    ([keymaps-and-modes.md](keymaps-and-modes.md), "The last change").
    A replay is one step of the history and is said under `repeat`, so
    the two reasons that set this aside for the ex line are what a replay
    wants. The ex line still asks for its command to be run after it.
  - Pinned by `ModelTest.dispatchStateChecks` and
    `ModelTest.dispatchRunCommandChecks`.
- **`invoke invocation` records the invocation** where a prompt's answer
  is recorded (`EditorState.Outbox.answered`), after what is there. So that
  field, and what a step hands back (`Loop.Stepped.answered`), is the
  invocations to run next: a prompt's continuation with its answer, and
  what a command asked for. The names stay: they were given for the
  first.
- **Everything above holds for it unchanged**: the host runs it as a step
  of its own before the next event, the command is looked up then, a name
  no command is registered under says `<name>: no such command`, a
  command that asks and does not run to its end has nothing run, and a
  refused one is rolled back alone, under its own name.
- **The ex line is its first user**: `ex` looks the line's name up and
  asks for the bound command to be run after it
  ([keymaps-and-modes.md](keymaps-and-modes.md), "The ex command line").
  Running the bound command inside `ex` was set aside for the reasons
  above: the lookup before the step's write, and a failure said under
  `ex`'s name.
- **Set aside: one request that looks an ex name up and records its
  command.** The rule for an argument a name does not take would then be
  in the dispatcher. With two requests the dispatcher answers a question,
  and the ex line's rules are in `packages/ex/Ex.lean`.

**Rollback and the interrupt around a prompt.**

- **A command that asks and then does not run to its end** is rolled back
  to the state from before it, which has no prompt. The text and the
  markers it made for the minibuffer are not released: that is the rule
  for everything a failed command made ("What is not undone").
- **An accept that is interrupted or refused** (it reads the text, a
  request that is guarded) is rolled back with the prompt open and its
  text as typed. Nothing was given up, since nothing is given up until a
  command has ended.
- **A cancel** makes one request about the editor state and cannot be
  interrupted or refused.
- **An answer's command that is refused or interrupted** is rolled back to
  the state after the accept: the prompt stays closed, the answer is not
  kept, and the echo area says what became of the command under its own
  name. The prompt is not opened again.
- **Any other command that fails while a prompt is open** is rolled back
  to a state in which the prompt is open, with the minibuffer's history
  and markers kept and restored like any buffer's and window's.
- **The interrupt key does not close a prompt.** It raises the flag, the
  loop lowers it as it takes the key, and the key is then stepped for the
  focused view like any key. With no command running it interrupts
  nothing, which is the rule that exists. A scheme may bind it; neither
  scheme here does.
- **A job's result is delivered while a prompt is open.** Nothing blocks:
  the loop runs the job's command as always, on whatever it names, and the
  prompt stays open.
- **A command that would show a buffer in the minibuffer's view shows it
  behind the prompt.** The minibuffer's view shows no other buffer, and
  while a prompt is open it can be the view a command has in hand: the
  focused view, or the view the command was called in. `open-file` meets
  both. A load whose asking view was closed is delivered with the prompt
  focused, and the command can be called with a path while the minibuffer
  has the focus. It then shows the file in the window the focus goes to
  when the prompt closes: the asking view of the prompt, or the first
  window of the tree when that view was closed
  (`EditorState.askedFrom`, the one definition of that rule;
  `Files.shownIn`). The prompt stays open with the focus. Before this the
  show was refused, and a loaded file was left in a buffer no window
  showed. Pinned by `FilesTest.fileCommandChecks`.
- **A reload leaves the prompt open.** It is compiled state. Its
  continuation is a name, looked up when the answer arrives.

**Candidates.** A prompt may be asked with candidates: records the answer
may be chosen from, each the text accepting it gives with what a display
may show beside it. While it is open the scene lists the candidates the
typed text matches, two commands move a choice through that list, and
accepting hands the continuation the chosen candidate.

- **They come from sources, asked once by the asking command's
  `prompt`**: `prompt label continuation initial (sources := …)`, where a
  source is a name, a category and a program over the editor's port from
  a query (the text typed so far and the asking view) to candidates
  ([keymaps-and-modes.md](keymaps-and-modes.md), "A prompt's sources"). It
  may ask what a command may: the state's buffers, the bound ex names.
  - A source is given as a value, which `prompt` runs, or named, which the
    loop runs from the registered sources (`ControlRequest.askSource`): a
    request cannot carry the program, so the name crosses. A name no source
    is registered under refuses the prompt with `noSuchSource`.
  - A prompt may ask for a category instead: `prompt` asks the loop once
    for the names of the sources registered in it
    (`RegistryRequest.categorySources`), whose reply is names and never a
    program, and then asks each by name, after the defaults the prompt
    gave, each of which is asked by name where one of its name is
    registered there. A category with no source lists nothing and is not
    refused. The shipped prompts ask this way, so config adds to and
    replaces what they list.
  - Each is asked inside the asking command, in order, after the two
    refusals that make nothing and before the minibuffer's text is made,
    and what they answer is what the open prompt holds, as plain data,
    each in its source's group. If one is refused the asking command is
    refused and rolled back like any, and no prompt opens.
  - It has no `IO` and cannot wait. A list that needs the file system is
    made by a job, whose command asks with a source of the result
    (`.given (.ofTexts name category names)`).
  - This is how a source supplies candidates though a prompt holds no
    program ("A function kept by the loop or by the registry", above):
    the source is asked by the asking command, and what the prompt keeps
    is its answer. A registered source is the registry's, by owner, as a
    command is, so a reload replaces config's and none of its code is kept
    past one.
- **The list is then fixed**, but for `setCandidates`, which replaces an
  open prompt's candidates and forgets its listing and its choice. A job's
  command can bring a list that way.
- **The candidates, the listing and the choice are fields of the open
  prompt**, so they are editor state. A command that fails is rolled back
  to the listing and the choice from before it. A reload leaves them: they
  are strings, not config's code.
- **The loop brings the listing up to date before each scene, and nothing
  else asks a style for a prompt.** While a prompt is open and has
  candidates, the publish reads the minibuffer's text; when it is not the
  text the listing is for, it asks the style chosen for the prompt's
  category (`Loop.Keys.matching`; the fuzzy matcher's by default) and
  keeps the candidates it answers, in its order, with the ranges that
  matched, then those a filtered source passed, in the order it gave,
  none dropped, each marked with the style's ranges where it matches it,
  with nothing chosen
  ([lean-runtime.md](lean-runtime.md), "The editor's port is a
  composite"; [keymaps-and-modes.md](keymaps-and-modes.md), "A prompt's
  matching styles").
  - For a short list the style runs on the editor thread, in the publish,
    as config's mode-line segments do. That is safe for config's style
    because a style is a program over the fuzzy port alone: it cannot read
    the state, cannot be refused, since the fuzzy port has no error, and
    cannot be interrupted. A source, a program over the editor's port, is
    kept out of the publish for those reasons.
  - **A list longer than `Loop.inlineMatches` (250) is matched off the
    editor thread** (completion's phase 3): the publish only reads the
    text, and the step spawns a match job, on Lean's task pool, under
    `completion-match <view>` and the owner of the style, that makes the
    listing with the same program a short list's is made with
    (`Candidates.listing`), asking the matcher as a request of the job port,
    and finishes with the command that lists it if it is still the match
    in flight. At most one is in flight: a key or a batch meanwhile spawns
    nothing, and the delivery's scene spawns the next for the latest text,
    so batches cannot starve the listing. A matcher that throws ends the
    match with `completion-match: ` and why in the echo area, and that text
    is not matched again until it or the candidates change. So a key never
    waits on the match; the listing arrives a moment after it, and while
    typing fast it can be an earlier text's (owner decision of the phase's
    plan). Config's style runs on the pool too: there it cannot outlive its
    config, since the match job is config's when the style is ("Reload").
  - **The display builds at most its rows each publish**
    (`EditorState.displayed`, completion's phase 4): it is handed the
    listing as it is, never copied or mapped, and answers rows for a
    window of it round the choice, ten by default, as vertico and ivy list
    ten. 100,000 rows built at every key would break the bound above.
  - The style is looked up from the step's keys each time and never kept
    in the state, which holds only the prompt's category: a reload
    changes it from the next listing.
  - The first listing is made by the scene of the asking step, for the
    initial text. Every event ends in a scene, so a command always finds
    the listing of the text the last scene showed.
  - A text that did not change costs one read and no ranking, unless a
    batch came in since, which is listed for the same text with the choice
    kept on its candidate. A prompt with no candidates costs what it cost
    before, and one whose every candidate was passed asks the style only
    to mark them, and not at all for the empty text. The size that chooses
    between the editor thread and a match job counts the passed candidates
    with those to match (`Candidates.listingSize`), in `Loop.listed` and
    in the reconciler alike, so a long passed list is marked on the pool.
  - It is the loop's own request: it is not guarded, so the interrupt flag
    never stops a scene. The ranking runs in the call, on the editor
    thread for a short list and on a pool thread for a long one
    ([rust-library.md](rust-library.md), "Fuzzy matching, as built").
  - Set aside: listing in the command that typed. That command is the
    scheme's self-insert, which knows no prompt, and an undo, a put and a
    committed text change the text too. Set aside too: asking again at
    each use, with no listing kept. The list a key steps through could
    then differ from the one shown.
- **The choice** is an index of the listing, or none. `chooseCandidate`
  moves it one step, next or previous. From nothing chosen, next chooses
  the first and previous the last; next from the last and previous from
  the first choose nothing. So the text as typed is one stop of the
  round. The minibuffer's text is not changed by a choice, and a change of
  the text forgets the choice, since the next scene lists again.
- **What accepting gives the continuation**:
  - a candidate is chosen, and the listing is for the minibuffer's text:
    that candidate;
  - nothing is chosen, whatever is listed: the typed text;
  - nothing matches: nothing can be chosen, so the typed text.

  So every prompt that shipped before candidates behaves as it did, and a
  user who types and accepts gets what was typed. Set aside: the first
  match when nothing is chosen. `:r` and the accept key would then run
  `reload`.
- **Sources are registered by name; one that answers now is asked once,
  one that answers later from a job.** Completion's phase 1 built the
  registration by owner and the asking inside the asking command, and its
  phase 3 sources that answer later
  ([keymaps-and-modes.md](keymaps-and-modes.md), "A prompt's sources"): a
  source names a registered job and when it is asked again; `prompt`
  records it and runs none of it; the loop's reconciler, after each
  publish, starts its job under `completion <view> <source>`, and starts it
  again, the previous one cancelled, at the next generation and after the
  source's pause, when it depends on the text and the text changed. Its
  batches are posts, taken into the prompt by `minibuffer-candidates`, a
  stale generation's dropped, and listed by the scene after each; a later
  source's candidates come after those that answered now, and a
  text-dependent source keeps its previous answer until its new job's
  first batch. **No source is run in the publish**: what asks again is a
  job, so no rule for config's code inside a scene is needed. **Closing a
  prompt cancels its jobs**, its sources' and its match, by the keys the
  loop recorded, at the publish of the closing step.
- **File names** (completion's phase 6) are a source that answers later,
  asked again when the text through its last `/` changes
  (`Reask.beforeLast '/'`), at once: typing within a directory starts no
  job, and the directory is read once, on the library's file service
  thread, through the job port's file request `File.list`. Its job
  (`Completion.Paths.gather`) sorts and builds candidates on a pool
  thread, and delivers them in batches of at most 1,000. A source's
  answer for another directory is not listed (`Reask.answers`, against
  `Asking.answeredFor`), so the scene of the key that types a `/` lists
  nothing of the old directory before the new batch arrives; a source
  that waits for a pause keeps its previous answer, as phase 3 decided.
- **Sources a command filters** (project navigation's phase 1,
  `lean/Editor/Completion/Filtering.lean`) hand both the listing and the
  filtering to external programs, so a workspace of 100,000 files is never
  passed to Lean whole: only the best few hundred are. Such a source
  answers later and is asked again after a pause (`Reask.afterPause`, 50
  ms by default); its job:
  - runs a *lister*, a `Process.Command` the source chooses, whose standard
    output is the candidates, held whole up to 64 MiB by default, enough
    for well over 100,000 paths;
  - feeds that output to a *filter*, `fzf --filter <text>` by default,
    with the typed text appended to its arguments as one argument. It
    never passes through a shell, so no text typed into a prompt can run
    a command;
  - reads the filter's output as a head (`ProcessRequest.runHead`): past
    its byte limit, 256 KiB by default, the library ends the filter and
    answers what it kept as a success, so an empty text, which prints
    every candidate, still answers. A cut head's last part of a record is
    dropped;
  - splits records on a line feed or a NUL (`git ls-files -z`, `fzf
    --read0 --print0`), drops empty ones and those that are not UTF-8, and
    delivers the first `limit` (200 by default) as **one batch**, an empty
    one included, so an answer of no matches replaces the previous text's
    at once;
  - treats a lister exit status the source declares a partial listing
    (`partialListing`, none by default; `find`'s 1 for the workspace
    finder's fallback) as an answer of the records it printed;
  - treats a filter exit status the source declares (fzf's 1) as no
    matches, which is no failure; any other exit, a time-out (10 s by
    default for each run) or a refusal fails the source through
    `sourceFailed`, naming the program, so `fzf` not installed is said as
    that and never as an empty list.

  The source is filtered: the prompt lists its answer in the filter's
  order and drops nothing, and the category's style only marks the ranges
  it matches, so highlighting looks the same as in other prompts. Nothing
  in it knows of files or workspaces; which commands list and filter is
  the source's choice, so project handling stays in Lean and config.
  A source's job is handed only its query, so what the command that
  opened the prompt chose reaches it there: `prompt` takes a place, which
  replaces the asking view's, and a context, plain arguments
  (`Query.context`), both kept with the prompt and carried in each order
  the reconciler starts (`Completion.Order`, the context's length and its
  arguments after the region). `find-file-in-workspace` hands its root as
  the place and its lister as the context
  ([projects.md](projects.md), "`find-file-in-workspace`").
  - **Prior art**: fzf.vim, and Emacs's consult (`consult-fd`,
    `consult-ripgrep`, affe), which hand both the listing and the filtering
    to external processes.
  - **Alternative considered**: a Rust `FileWalk` port over the `ignore`
    crate. Rejected: it would put a walk and ignore-file rules in the
    editor, and still pass every file to Lean.
  - **Open**: the lister runs again at each ask, and nothing is cached.
- **The listing's projection** (`Candidates.answering`): where a listing is
  made, inline or in a match job, an asking source's stale answer and the
  candidates its typed text does not reveal (`Candidate.hiddenUntil`) are
  left out; the state is never changed. The size that chooses between the
  two counts hidden candidates as shown, per source
  (`Candidates.current`), so a key costs the editor thread nothing per
  candidate. Over more than the inline limit, a key typed within a large
  directory costs the editor thread one read of the minibuffer, and the
  match job lists it with the `path` style off the thread.
- **A source's job that throws** finishes with `StateRequest.sourceFailed`:
  the source is marked done and the echo area says `<source>: <message>`,
  as a match job's failure says `completion-match: …`. A stale job's
  failure is silent.

**Matching off the editor thread, measured.** `mise run prompt-bench`
(`config-test bench-prompt`, [on-demand-checks.md](../dev-practices/on-demand-checks.md))
times a key typed into an open prompt, one of the six of `src/f1`,
committed as typed text, from sending it to the editor thread having
handled it, published its scene and run an empty `noop` sent right after
it, read on the editor thread: each row is a headless host on the real
queue and the library, the candidates paths of about 40 bytes. One run,
2026-11-17, at `fb583c1`, on an Apple M5 Max (18 cores, a pool of 18
threads), 600 keys a row, in µs, median / 99th percentile / maximum:

| Row | Key |
|---|---|
| no candidates | 96.6 / 224.8 / 326.4 |
| 100 inline | 113.4 / 255.5 / 338.1 |
| 250 inline | 187.1 / 339.1 / 424.0 |
| 500 inline | 313.0 / 475.2 / 569.8 |
| 1,000 inline | 675.2 / 2572.5 / 2923.0 |
| 10,000 inline | 4873.3 / 8001.6 / 13517.8 |
| 100,000 inline (the limit lifted, the path before phase 3) | 49454.3 / 71940.7 / 72544.5 |
| 100,000 on the worker, each key joined | 117.0 / 211.0 / 316.1 |
| the listing of that row, key to delivery | 51744.8 / 72610.8 / 73327.8 |
| 100,000 on the worker, keys 20 ms apart, nothing joined | 139.9 / 639.2 / 896.1 |

- **Within bound**: both rows on the worker, the joined one and the one at
  typing cadence, where a key arrives while a match runs or while its
  delivery is handled; each has its median within twice the no-candidates
  row's and its 99th percentile under 1 ms. The bound is judged on those
  two rows; an out-of-bound worker row would fail the phase's criterion 4.
  An earlier run of the cadence row was out of bound (99th percentile
  2.4 ms): the delivery replaced a listing of 100,000 candidates, and
  freeing the old one on the editor thread took about 3 ms, so a key that
  arrived meanwhile waited. The host now lets go of the frame a step
  replaced on a pool task (`Headless.Running.release`), and the row has been
  within bound in each run since.
- **The inline limit is 250**: the largest size whose 99th percentile was
  under 1 ms in each of the four runs taken on this machine. 500 was under
  in this run and in one other and over (1.6 ms) in two; 1,000 was over in
  four of five. A key listed inline costs Lean's work over the candidates
  (their texts gathered for the matcher and each hit's ranges, which
  `Styles.inOrderSpans` computes) much more than the matcher's own,
  7.4 ms for 100,000 in Rust.
- **The listing of 100,000** arrives about 50 ms after the key (the
  matcher's call, the candidates' texts copied to it, and each hit's
  ranges), which the owner accepted: while typing fast the listing can be
  an earlier text's.

**A key in the file prompt, measured** (completion's phase 6). The row
`open-file, 10,000 entries` of `mise run prompt-bench` times a key typed
within a directory of 10,000 files in `open-file`'s prompt, on a host of
the test scheme whose jobs reach a fake file service, the directory listed
once and joined before the keys
([on-demand-checks.md](../dev-practices/on-demand-checks.md)). A key typed
within the directory starts no listing (`Reask.beforeLast`), and the match
job lists it with the `path` style off the editor thread, so the key costs
what a key over 100,000 on the worker does. Three runs, 2026-11-18, at
`36c8b64`, the commit that adds the row, on the Apple M5 Max above (a pool of 18
threads), 600 keys a row, in µs, median / 99th percentile / maximum, with
the run's no-candidates row beside it:

| Run | no candidates | open-file, 10,000 entries | Within bound |
|---|---|---|---|
| 1 | 176.8 / 248.7 / 403.9 | 89.0 / 157.3 / 161.5 | yes |
| 2 | 162.6 / 512.8 / 1898.4 | 91.0 / 157.8 / 211.3 | yes |
| 3 | 182.1 / 354.2 / 543.6 | 85.3 / 158.9 / 165.6 | yes |

The row is within bound in each run: its median within twice the
no-candidates median and its 99th percentile under 1 ms. The machine may
not have been quiet (another worktree's builds were running on it during
the session), which the no-candidates row's spread in run 2 suggests.

**A key in the workspace finder, measured** (project navigation's phase
2). `mise run find-file-bench` (`config-test bench-workspace-files`,
[on-demand-checks.md](../dev-practices/on-demand-checks.md)) times a key
typed into `find-file-in-workspace`'s prompt on one headless host of the
test scheme over the library's real process and file services, in a
repository that `tools/workspace-bench-repo.sh` generates: 100,000 files
at `src/m<i / 100>/f<i>.rs`, paths of 17.8 bytes on average, committed
once, which git found (the prompt's label `Find file in repo@main: `), so
the lister is `git ls-files`. Three runs, 2026-11-18, at `cee8647b`, on
an Apple M5 Max (18 cores, 128 GB, macOS 27.2.1, a pool of 18 threads),
fzf 0.74.5, 120 keys a row, in µs, median / 99th percentile / maximum:

| Run | no candidates | finder, each key joined | key to the updated list | finder, keys 120 ms apart |
|---|---|---|---|---|
| 1 | 56.7 / 87.9 / 91.5 | 198.4 / 310.8 / 321.3 | 136219.4 / 173959.7 / 178484.0 | 260.3 / 428.8 / 464.9 |
| 2 | 56.2 / 105.7 / 111.6 | 187.6 / 304.8 / 318.4 | 133897.4 / 174818.3 / 175074.0 | 247.2 / 428.8 / 470.6 |
| 3 | 55.9 / 94.8 / 103.6 | 196.8 / 297.3 / 307.9 | 134832.4 / 173571.9 / 174169.4 | 251.3 / 484.4 / 531.8 |

Alone, outside the editor, the medians of 20 runs were, in the three runs,
58.1, 58.9 and 57.7 ms for `git ls-files -z --cached --others
--exclude-standard`, and 13.9, 13.8 and 13.8 ms for `fzf --read0 --print0
--filter m12` fed its output.

- **No key waits on the lister or the filter.** Every key is handled and
  published within 0.6 ms, the 99th percentile under 0.5 ms in every row,
  while the list it updates comes about 134 ms later: the source's 50 ms
  pause, `git ls-files` (about 58 ms) and fzf (about 14 ms) run in the
  source's job on the pool, and the batch's listing on the editor thread.
  The cadence row's keys arrive while that job runs and cost no more than
  about 60 µs over the joined row's. That is what phase 2's last
  criterion asks: the time from a key to the updated list is measured and
  recorded here, and no key's handling waits on the lister or the filter.
  The criterion is met.
- **A key's handling is more than twice the no-candidates floor**, a
  measured fact, and so out of the 2× bound the phase's plan set for its
  own runs (the bound `bench-prompt`'s worker rows use): in every run both
  finder rows' 99th percentile is under 1 ms, but their median, 188-260
  µs, is more than twice the no-candidates median, 56-57 µs. The cost is
  not the lister's or the filter's: it is the editor thread re-marking the
  passed candidates on every key, the previous answer's, up to the
  source's limit of 200, with the style's ranges for the new text
  (`Candidates.listing`, the passed candidates' `style.hits`), as an
  inline listing of that size does; `bench-prompt`'s inline rows put 100
  candidates at about 113 µs and 250 at about 187 µs on this machine. It
  is within the inline bound the plan relied on (at most 200 records
  reach the editor thread, under `Loop.inlineMatches`, 250) but not within
  twice the no-candidates floor. The rdm task
  `mark-filtered-candidates-once-per-batch` is the work that brings a key
  back to the floor: marking the passed candidates once per batch, or off
  the editor thread.

**A typed key with completion at point, measured** (completion's phase 5).
The two insert rows of `mise run prompt-bench` time a word key in insert
state under the Vim scheme that ships, on a fake job clock and the real
library, queue and recorder: with no at-point source, and with the shipped
`words` re-arming its pause at each key over 20 open buffers of about
50 KB, four of each sample's six keys typed with the session open
([on-demand-checks.md](../dev-practices/on-demand-checks.md)).

**The auto-popup row's bound is the plain insert row**: its median at most
twice the `insert, no at-point` median, and its 99th percentile under
1 ms. The row measures what the auto popup adds to a typed key in insert
state, and the plain insert row is that key with nothing armed. It was
first judged against the prompt's no-candidates row, a key of the test
scheme, which swung from 49 µs to 187 µs between runs on this machine
while the auto-popup row's own median sat at 121-134 µs, so it failed in
about one run of three on the floor alone. The worker rows keep the
no-candidates row as theirs.

Three runs, 2026-11-17, with the bound above (the commit after
`6ba2e2f`), on the Apple M5 Max above (a pool of 18 threads), 600 keys a
row, in µs, median / 99th percentile / maximum, with the run's
no-candidates row beside them:

| Run | no candidates | insert, no at-point | insert, auto popup, 20 buffers | Within bound |
|---|---|---|---|---|
| 1 | 77.0 / 187.6 / 301.6 | 100.1 / 115.8 / 127.9 | 124.1 / 175.3 / 190.0 | yes; both worker rows yes |
| 2 | 50.5 / 84.5 / 104.3 | 99.8 / 116.3 / 143.4 | 117.0 / 143.2 / 157.8 | yes; both worker rows yes |
| 3 | 48.0 / 69.0 / 104.4 | 98.0 / 114.8 / 123.8 | 116.5 / 145.8 / 168.6 | yes; both worker rows yes |

- **The auto-popup row stays within about 25 µs of the plain insert row**
  in every run, and its 99th percentile under 0.2 ms: re-arming the pause
  (a withdraw and a start on the clock) and the pure check of the chain
  are what a typed key adds, and the session's listing is matched off the
  thread. D9's fallback (re-arming in place of restarting) would save at
  most the one withdraw and start, and is not built.
- **The plain insert row is steady** (98-100 µs median in these runs),
  where the no-candidates row moved from 48 µs to 77 µs; the runs at
  `fdd4cb9`, judged against no candidates, saw it move from 53 µs to
  187 µs and put run 1 out of bound by that floor alone.

**Sessions at point** (completion's phase 5,
[keymaps-and-modes.md](keymaps-and-modes.md), "Completion at point") use
the same jobs, keyed by the session's view: the reconciler reads what is
completing, a prompt or a session (`EditorState.completing?`), so a
session's later sources start under `completion <view> <source>`, its long
list is matched under `completion-match <view>`, and closing the session
cancels both at the closing step's publish. `words` answers later from the
job `words`, registered by the `at-point` package, so its owner is that
package's and a reload does not cancel it; it reads snapshots of the open buffers the asking
command took, released when the session closes. A trigger character asks
through an invocation the step hands back (`at-point-triggered`), run as
the next step. The pause is a timer the host arms on the job clock, not a
job: each typed key in insert state restarts one wait (withdrawing the held
one, ended as cancelled in the table of waits, then starting another), and
its completion posts an event, from the clock's completion path, before the
clock's move returns, which runs `at-point-paused`. So a typed key costs a
pure check of its buffer's chain and two calls into the timer service, and
no text request, job or job line; the insert rows below measure it.

How the scene shows the candidates is in
[text-and-display.md](text-and-display.md), "Views as built", and the keys
that move through them in [keymaps-and-modes.md](keymaps-and-modes.md),
"The minibuffer".

**What ships that asks.** `open-file`, run with no path as its first
argument, asks `Open file: ` with itself as the continuation, so the
answer is the path it opens, in the view it was asked from ("Getting
results back"). The prompt starts with the asking view's directory as its
text and completes file names from the source `files`, whose job lists
the directory typed so far (completion's phase 6,
[keymaps-and-modes.md](keymaps-and-modes.md), "`open-file` completes file
names"); the command reads the answer as a typed path, `~` and relative
names included (`Files.resolve`). `ex`, run with no line as its first argument, asks `:`
with itself as the continuation and the `:!` history and the bound ex
names as its candidates, from two sources, so the answer is the line it
runs
([keymaps-and-modes.md](keymaps-and-modes.md), "The ex command line").
`find-file-in-workspace` asks `Find file in <name@branch>: ` with itself,
`true` and the workspace's root as the continuation, over the source
`workspace-files`, which lists the workspace's files with its lister and
fzf in its job; the answer, a path under the root, is opened through
`open-file` run by name, so config's override of it applies
([projects.md](projects.md), "`find-file-in-workspace`").
`find-file-in-project` asks `Find file in a workspace of <name>: ` with
itself, `true` and what it asked as the continuation, over the source
`project-workspaces`, whose job runs `git worktree list`; the answer, a
label, is resolved by the job `project-workspace-choose`, which lists the
worktrees again, and its finishing command runs `find-file-in-workspace`
by name, finding a worktree not yet found in a third job first
([projects.md](projects.md), "The project's workspaces and
`find-file-in-project`").
`save-buffer` does not ask: a buffer with a file needs no
name, and one with no file needs a file that is not there yet, which is
more than a prompt. Config asks with `prompt`, and registers the command
that receives the answer with `commandWith`, which is given its call
([lean-runtime.md](lean-runtime.md), "The config session as built").

How the minibuffer takes keys is in
[keymaps-and-modes.md](keymaps-and-modes.md), "The minibuffer", and how
the scene shows it in [text-and-display.md](text-and-display.md), "Views
as built".

### Structured lifetimes

Every job has an owner: a buffer, a view, an agent session, or a package.
When the owner goes away, its jobs are cancelled. Nothing runs unowned.

As built (`lean/Editor/Job/Table.lean`, `lean/Editor/Job/Jobs.lean`):

- **One owner type** serves the registry and the jobs
  (`lean/Editor/Config/Owner.lean`), so an owner's registry entries and its
  jobs go together. The user's config is the one owner there is.
- **The job table is pure**: a job's id, its owner, its name and a handle.
  Every job is added with an owner; there is no other way in.
- **A shell over the table and the runner** is what the editor thread
  calls: start a job, take the result of one that has ended, remove an
  owner. Removing an owner takes its jobs out of the table and cancels each
  one. A job's result is taken from the table, so once the owner is removed
  a wake-up that was already queued finds nothing, and no handler runs. All
  of it happens on the editor thread, so there is no race to close.
- **A runtime that ends cancels every job.**

**A long-lived job owns a handed-over child** (acp-agents phase 3). A
streaming child stays named for the job that opened it
(`Handle.children`), and `Handle.conclude` ends every child the job still
holds, however the job ends. A child handed to a package's crate
(`editor_service::stream::take_over`, [rust-library.md](rust-library.md),
"Handing a streaming child to a package's crate, as built") is no
exception: moving it out of the job's set is not built. So a session is one
long-lived job: it opens the child, hands it to the crate through a
request of the package's service, and waits on that service until the
session ends; ending or cancelling the job ends the child. A cancel goes in
this order:

1. the runner withdraws the job's package wait (`Handle.cancel` →
   `Handle.withdraw` → `Handle.drop` → the service's `cancel`), so the crate
   drops the request and will post no completion for it;
2. the job concludes and ends the child (`Handle.conclude` →
   `endChildren` → `Processes.cancel`);
3. the child's streams are abandoned, so the crate's consumer, blocked in a
   pull, is answered `Cancelled`: the crate's last event, which it sees.

The request was withdrawn first, so the crate keeps nothing and posts
nothing ("a request cancelled first gets none"); a completion it posted
just before, already on the queue, finds no wait and is dropped.

**A session's long poll, and how its end is shown** (acp-agents phase 4).
A session's job loops on `agents-api`'s `next`, a package wait that is a
long poll: it completes once the session holds an event, and the crate's
flush does not wait for it, as echo's does not wait for an attach. Orders
come from other jobs (`send`), so a prompt does not hold the session job,
and an answer to a permission request goes out while the prompt is
pending. When the agent ends by itself, the crate puts `ended` last in the
final batch, which the session job reads, and a later `next` is refused.
When the session job is cancelled, the order above holds: the runner
withdraws its `next` first, then ends the child, and the crate posts
nothing for the withdrawn wait; the job's own outcome, `cancelled`, is the
end the editor sees, since a job cannot post once it is cancelled. Inside
the crate a cancel of the turn (`Order.cancel`) answers every parked
permission request of the turn `cancelled` and posts each `withdrawn`
before it sends `session/cancel`. The orders are proved on the protocol's
model (`agents-api`'s `AgentsApiTest/Protocol/Theorems.lean`), forced on
the stepped host over the fake, a package's own fake
(`AgentsApiTest/Linked/AgentsApi/Session.lean`), and in the crate's
`LocalPool` tests. A long poll holds its job's unit of the host's
activity for the session's life, as a service wait does, so a real host's
headless `settle` would not settle while a session is open; the stepped
host judges a wait at the rest of its fakes and never reads the activity
count, so a stepped `settle` settles with a session open, and no check of
phase 5 runs a session on a real host (rdm task
`acp-session-outside-mark-for-next` marks the long poll outside before one
does).

**A conversation's job posts once a batch, paced by the job clock**
(acp-agents phase 5; `packages/acp/Acp/Conversation.lean`). The
conversation's session job posts each batch `next` answers, everything the
service held when it was taken, as one invocation (`agent-events`, its
events written as arguments by `agents-api`'s `AgentsApi/Arguments.lean`),
so one editor-queue event, one turn and one published scene; then it
sleeps `batchPause`, 50 ms, on the job clock (`sleep`, a wait on the timer
service: the fake clock on a stepped host, which only a check or a
script's `advance` moves), as compile's run does. So it takes at most once
a pause, and what the agent sends meanwhile waits in the service for the
next take. On a stepped host every event queued between two turns is in
one take, into a parked `next` or across the pause; on a real host each
take is one turn and one scene. A post cannot wait until the loop has
handled it, so a take cannot include what arrives after it; nothing here
promises more than that, per take. Pinned on the stepped host
(`packages/acp/AcpTest/Linked/Acp/Conversation.lean`, AC3: a thousand
events in ten pieces, both ways, one memory-queue event and one scene).

**The stall watchdog: one keyed job armed once, judged by a generation**
(acp-agents phase 7; `packages/agents-api/AgentsApi/Table.lean` decides,
`packages/acp/Acp/Table.lean` carries it out). A working agent silent
past `AgentRecord.stallTimeout` is of unknown activity. Its watchdog is
one job, `agent-stall`, keyed `agent-stall <id>` and carrying the
record's generation (`heard`) it was armed at, that waits on the job
clock (`waitUntil`; the fake clock on a stepped host) until a deadline:
the timeout after it starts, or the deadline its last verdict gave. It is
armed once while the agent works, not again for each batch: restarting a
keyed job for each batch would cancel one job a batch, each cancel a turn
of the loop, and the conversation's one-scene-a-batch property above
would not hold. Each batch instead stamps the record with the job clock's
time the session job put on its post (`.heardAt`). At its deadline the
job's command, on the loop, carries out the pure `AgentRecord.verdict` of
the record as it is then: `.stalled` at the armed generation when nothing
was heard since; armed again for the last batch's timeout when one came
since and that is still ahead; otherwise `.stalled` at the last batch's
generation; nothing once the agent no longer works. The reducer ignores a
`.stalled` that is stale or comes when the agent no longer works; an
agent that stops working has its watchdog cancelled by its key. The
verdict is pinned as a pure function (`AgentsApiTest/AgentsApi/Table.lean`)
and on the stepped host by advancing the fake clock to one millisecond
under each deadline and then to it (`AcpTest/Linked/Acp/Table.lean`,
AC2).

**A load's history is queued before its open completes** (acp-agents phase
7; `packages/acp/rust/src/session.rs`). The agent replays a loaded
session's history as notifications before it answers `session/load`; the
crate posts them, merged, before `Opened`, and the service holds the
events of a session still opening, so the session job's first `next`
after the open takes the whole history in one batch. An open refused
because its session ended first marks the session abandoned, so its held
history is freed rather than kept for a `next` that cannot come.

**The permission audit log's writer** (acp-agents phase 6;
`packages/acp/Acp/Permissions.lean`). Every permission request and its
answer are appended to `<state>/agents/permissions.log` through the job
port's file requests. Records are made on the editor thread, in the order
things happen, and queued in an outbox kept in an unscoped store. One job
at a time, `agent-audit`, takes the outbox's lines as one text, makes the
log's directory and appends the text, and returns the file service's
answer as a value; its command drops the lines it wrote and hands the next
lines to a new job, and on a refusal keeps every line for the next
record's job and says it once until a write lands. The outbox's rules are
pure (`packages/acp/Acp/Permissions/Outbox.lean`) and pinned by
`outboxChecks`. So the appends reach the file service in the order the
records were made, though jobs run on a pool: two append jobs at once
could land out of order, and a keyed job would cancel an older one and
lose its records, so it is neither. The outbox and a
write in flight live through a reload, the store being unscoped and the
job a package's. Pinned on the stepped host by the orders the file fake
was handed (`packages/acp/AcpTest/Linked/Acp/Permissions.lean`, AC4), and
by a forced order there: the file fake holds the first write's completion
while the user answers, and the answer's record starts no second job and
goes in the write that follows the first.
Pinned on the stepped host with the
service's fake and the process fake's hand-off (`FakeProcesses.handOff`)
by `EchoTest/Linked/Echo/Packages.lean`'s two forced orders: (a) the
consumer held, the job's wait withdrawn at the service before the process
fake's kill of the child, whose consumer then reads `one` and `cancelled`;
(b) the child exited by itself and its completion handed to the pump but
not stepped when the cancel comes, which drops it, the fake keeping no
reply and the late kill a no-op. Each was seen to bite by hand, as phase 2's
orders were: (a) fails when `endChildren` is taken out of
`Handle.conclude`, (b) when `Handle.drop` stops cancelling at the package
services. The crate's own lib test holds its consumer in a pull while the
request and then the child are cancelled, and sees no completion.

**In tests, a host, its loop and its queued work end inside a bracket**
(deterministic-test-concurrency phase 3), so that nothing a test creates
outlives it (AGENTS.md, "Deterministic concurrency in tests"):

- **`Headless.withHost` is the only way to have a host**
  (`lean/Editor/Headless.lean`; `Host`'s constructor and `start` are
  private). It runs its body against the host and returns once the loop's
  task has ended, whether the body returned or threw: a loop still running
  is asked to stop and waited for with no deadline. Its guard only says a
  hang, once, and never ends the wait. Tests, the bench and the window mode
  (`withHostEnding`, which hands the loop's error back for the exit status)
  all use it, and `run` and `runAndDispose` run on it. The headless CLI
  alone bounds the wait: after the hang is said it waits `hangGrace`
  (5 s) more, then gives up as `Failure.hung` with status 1, so CI and
  fixtures never hang. Pinned by `ConfigTest.bracketChecks` and the run
  checks of `ConfigTest.scriptChecks`, which hold the loop inside an event
  and let it go only from the bracket's own report of the hang.
- **`Editor.Test.Linked.withFiles` removes a test's directory only once
  the services' flushes are completed** (`lean/Editor/Test/Linked/Services.lean`):
  a flush of each service the check handed paths under the directory, the
  file service unless it names others (the grep service's flush waits for
  a cancelled search's thread, which may still be walking), waited for with no deadline,
  whether the body returned or threw; a guard says a hang, and a refused
  flush is said too. A check that runs a host over the directory nests the
  host's bracket inside it. ConfigTest and the packages' linked tests reach
  it through the kit's `HostContext.withFiles`
  (`lean/Editor/Test/Linked/Host.lean`); FfiTest's `inOwnDirectory` keeps the same rule
  with a flush of its own, pulled through the one parked pull of the
  completion queue (`FfiTest.pullTask`). Pinned by
  `ContractTest.linkedServicesChecks` over the real file service, its
  worker held in process.
- **A Rust owner's drop stops and joins the thread it started**:
  `editor_service::Worker` (a service's test loops in `editor-ffi`), the
  watch service's timer thread (joined when its last handle is dropped),
  and the headless render session (`render::Headless`, whose drop does
  what its `stop` does). Each is pinned by a test whose thread is held by a
  hook the drop calls before it joins, so a drop that did not join is seen
  every time.
- **The reload job is the loop's** (deterministic-test-concurrency phase
  4): the loop keeps its task (`Running.reloadTask`) and its end waits for
  it, after `cancelAll`, so the host's bracket, which waits for the loop,
  waits for the reload too. A reload's wake-up to a queue that has been quit
  is refused and gives its unit back. Before it waits, the loop's end calls
  `Collaborators.endWaits` with `"reload"`: a test's hook, which a check
  that holds a reload at a gate lets it go on. The window mode pays for it:
  a quit during a reload waits for that elaboration to end. Pinned by
  `ConfigTest.bracketChecks`' "a host's bracket returns only once its
  reload job has ended".
- **A check's bracket gives up on a hung loop**: with D3 a reload that
  really hangs keeps the loop's end waiting, so `withHost` and
  `withHostEnding` take the `grace` and `abandoned` that `hostedWithin` has,
  and the linked test kit's `onStage` (every check host) and
  `withShippedHost` (`lean/Editor/Test/Linked/`) pass
  `grace := some hangGuard`: a loop still running `hangGuard`
  after its hang was said is handed to `abandoned`, and the check fails as a
  hang (`a hang: the editor loop had not ended …; giving up`). The window
  mode, the bench and the CLI keep what they had (`none`, `none`, `some
  hangGrace`). Pinned by `ConfigTest.bracketChecks`' "a check's bracket
  whose loop is held past its guard and its grace fails as a hang".
- **A stepped host lives in its bracket too** (deterministic-test-concurrency
  phase 5): `Headless.withStepped` makes the loop's state on entry and,
  whether its body returned or threw, closes its memory queue (a late post
  is refused and gives its unit back), ends the loop (`Running.wind`, its
  wait for a reload guarded, the hang said once and, with `grace`, given up
  on as `withHost` does), and drops the loop's state before it returns. The
  body's error is the one thrown; when it returned, an error a turn threw
  is. Pinned by `ConfigTest.steppedChecks`.
- **Not yet in a scope** (tasks filed, `tech-debt`): pool jobs, which `cancelAll` cancels
  and does not wait for (`pool-jobs-outlive-host-loop`); the Rust service
  threads that are waited for by a count and not joined
  (`rust-service-threads-joined-by-count`); and the test threads left
  behind on a panic path (`rust-test-threads-left-on-panic`).

## What the Lean runtime requires of us

Each of these was measured against the pinned toolchain
(`research_notes/lean-embedding-experiments.md`). They are requirements on
the job system, not options.

| Finding | Consequence |
|---|---|
| Blocked jobs starve the pool: with 32 jobs blocked in I/O a new pool task waited 0.9 s, with 128 it waited 4 s | An awaited service call must not hold a pool thread. Services complete a promise; a job that has to block in a system call runs on a dedicated thread. |
| `IO.cancel` only sets a flag. It did not interrupt a sleep, a process wait or a pipe read | Cancellation is built by us: each job carries a token, every await races against it, and cancelling a service request cancels the underlying work (kills the process, closes the stream). |
| A user `try`/`catch` can swallow a cancellation error | Cancellation is checked again after the handler; a cancelled job cannot continue to its next await. |
| The pool does not grow for a burst: 16 tasks ran on 2 threads until it was warm | Warm and size the pool at startup. |
| Pure work at the head of a job's `do` block runs on the spawning thread, before the task exists | The spawn function takes the job as a function and forces the task boundary first, so nothing runs on the editor thread. |
| Deep recursion or a missing native symbol in interpreted code is a C++ exception that aborts the process, and Lean's `try`/`catch` does not see it | Nothing catches it, and the process aborts. A C++ `try`/`catch` could stop the exception but not restore what the Lean frames it skipped were holding, so there is no guard. See [lean-runtime.md](lean-runtime.md). |
| Lean never kills or reaps a child process; children outlive the editor | Child processes belong to the Rust process service: each child leads a process group of its own, a cancelled job's run kills its group, and the editor's mains shut the service down before they quit, which kills every group and blocks until every child is reaped. Checked by `editor-process`'s contract on real processes, with a child that starts a grandchild (`crates/editor-process-std/tests/contract.rs`), by `crates/editor-ffi/tests/processes_shutdown.rs` through the C function, and by `contract-test`'s cancelled job. A descendant that leaves the group is not reached, and outlives the editor; one that holds a child's stream open holds neither a cancel nor shutdown, which waits for the reap and not for the streams to close (the contract's escaped-descendant property, on real processes). See [rust-library.md](rust-library.md), "Processes, as built". |
| Returning from `main` hangs while a dedicated task is still blocked | Shutdown posts a quit event, unblocks every dedicated task, and then exits explicitly. |
| A thread hop costs 2.7 to 5.2 µs; a call into Rust costs 8 to 19 ns | Editor API calls are direct calls on the calling thread, not messages. |

Two more findings, made while the job system was built on Lean 4.35.0:

- **`IO.wait` on a pool thread adds a thread.** A pool task blocked in a
  system call starves the pool, as the first row says. A pool task blocked
  in `IO.wait` (`Task.get`) does not: Lean adds a thread to the pool for
  each blocked call, so 64 jobs parked that way were 64 threads. Neither is
  acceptable, so the runner never waits on a pool thread, and the test of
  the first row counts threads, not only delay. Pure code in a job that
  blocks in `Task.get` still adds a thread, and nothing stops config from
  writing it.
- **Passing a function to `spawn` is not enough.** Written as
  `asTask do run (job ())`, the application `job ()` is an argument of the
  action handed to `asTask`, and Lean evaluates it on the calling thread,
  before the task exists. The application has to sit in a function that
  only runs with the task.

As built, the mechanism for each row and the check that pins it. `lake
test` runs `model-test` (`lean/ModelTest.lean` and its modules under
`lean/ModelTest/`), with no Rust library; `contract-test` and
`config-test` are linked with it and run by `mise run ffi-test`.

| Row | Mechanism | Check |
|---|---|---|
| Blocked jobs starve the pool | A wait is a promise in the table of waits, completed by the pump, and the rest of the job is chained on it, so a job in a wait holds no thread. The pump is a dedicated task. No request of the job port blocks in a system call yet, so no job runs on a dedicated thread; the reload job is the one piece of work that does | `model-test`: more jobs than the pool has threads (at least 64) all reach their wait on a fake clock, from fewer threads than there are jobs, while a new pool task runs, and the same with every job in a load, on the fake of the file service with its completions held. Written first with `IO.wait`, it failed with one thread a job. `contract-test`: the same with real one-hour timers, and with the pump parked in its pull a warming holds exactly the threads the pool had before the pump was started |
| `IO.cancel` only sets a flag | A token in each job's handle: whether it is cancelled, and the wait it is in. Cancelling sets it, tells the service to withdraw the wait and ends the wait as cancelled | `model-test`: cancelling a sleeping job ends it with the fake clock never moved and the wait withdrawn; it failed against a cancel that only set the flag. `contract-test`: the timer leaves the library's schedule |
| A `try`/`catch` can swallow a cancellation | Cancellation is not a reply and nothing is thrown: the runner looks at the token before each request, when each reply arrives and when the program ends, and stops applying the job's continuation, which is where the `catch` handlers are | `model-test`, in the model and in the runner: a job that catches every error around each of five sleeps, cancelled in the first, makes no further request; a job cancelled while a reading of the clock is in flight, or as its wait completes, is not continued |
| The pool does not grow for a burst | `Pool.warm` at start-up holds one task on every thread of the pool at once. The pool keeps Lean's size, one thread a core | `model-test`: warming holds a task on every thread of the pool at once, all of them different; a second warming, asked for two threads more, holds the same threads; and a burst afterwards lands on exactly those threads. The checks pin no size: they learn the pool's threads by warming it (`Pool.whole`), so they pass whatever `LEAN_NUM_THREADS` says |
| Leading pure work runs on the spawning thread | `spawn` applies the job inside its task, in a function that is never inlined | `model-test`: with a job's leading work held on a promise, `spawn` returns; it did not, written the naive way |
| An interpreter exception aborts the process | Nothing is added: a job from config is called with no guard, on a pool thread with the 64 MiB stack | `ffi-test`: a pool task has that stack. `mise run ffi-overflow`, on demand, shows the abort. No test of a job that overflows: it would abort the test |
| Lean never kills or reaps a child | The job port has no request that starts a process, and a job holds no `IO` | The compile-time checks of `lean/Editor/Job.lean`: an `IO` action is not a job. The process requests arrive with the process service |
| Returning from `main` hangs while a dedicated task is blocked | Quit ends the pump, as it ends every pull, and every executable exits explicitly | `contract-test` quits the queues and requires the pump to have ended; the fixture run of `editor headless`, under the task's time limit |
| A thread hop costs microseconds, a call nanoseconds | A request that needs no wait is a direct call on the job's thread, in a loop | `model-test`: 100,000 `now` requests in one job register no wait and are answered on one thread. `mise run job-bench` measures the cost |

### The runner is built on plain tasks and promises

`lean/Editor/Job/Runner.lean` takes a job a request at a time. A request
that needs no wait is answered by a direct call, and the loop goes on. A
request that waits registers a promise, and the rest of the job is chained
on the promise's task with `BaseIO.chainTask`. The job's outcome goes into
one promise of its own.

It does not use Lean's async library (`Std.Async`). Measured in a prototype
of each runner, when the job system was planned, on Lean 4.35.0:

- **Neither holds a pool thread at a wait.** `Std.Async`'s bind is the same
  primitive. With 64 jobs waiting, a new pool task ran within 6 µs under
  the plain runner and 33 µs under the other.
- **`Std.Async` nests a task for each bind.** A job that made a million
  requests answered at once overflowed a 64 MiB stack under it and aborted
  the process; the plain runner finished the job in 109 ms with flat
  memory. A job that looped over 400,000 waits held 35 MB more under
  `Std.Async`, about 90 bytes a wait for the life of the job, and nothing
  more under the plain runner. A timer that ticks for the life of the
  editor is exactly that loop.
- **Cancellation is built by us either way.** `Std.Async`'s is cooperative,
  delivered as an error that a `try`/`catch` sees, and its `race` leaves
  the loser running.
- **Its timers have no clock a test can move.** The clock is behind a port
  of ours in either design, so nothing of `Std.Async` would be left in use.

### Cancellation

- **The token** is in the job's handle: the job's state in the runner's
  protocol, its flag and the wait it has recorded among it, written only
  inside a critical section of the table of waits ("The runner's protocol,
  modelled", below).
- **Every wait races it.** Cancelling sets the flag and takes the recorded
  wait in one section, then tells the service to withdraw that request and
  ends its promise as cancelled. A promise resolves once, so whichever of
  the service and the cancel comes first wins, and the other does nothing.
  A wait the job was still making when it was cancelled is withdrawn by the
  job itself, in the section that would have recorded it, which then tells
  the service to withdraw it too. It does so even when the service completed
  the wait before the job recorded it, since a service keeps a completed
  request's reply until it is taken or withdrawn, and a cancelled job never
  takes it.
- **A cancelled job makes no further request**, and its outcome is
  `cancelled` whatever it would have returned.
- **A cancelled job runs no cleanup of its own.** There is no `finally`
  after a cancellation. What a job holds is the runner's to release: the
  wait it is in is withdrawn, and a handle to a library object is freed by
  its finaliser when the continuation is dropped. A child a job's run
  started needs no registering with the job: the run is the wait, and
  withdrawing the wait kills it (below).
- **A cancelled job's child is killed.** Cancelling a job in a process wait
  withdraws the wait, and the process port's real implementation cancels
  the run at the library: `Handle.cancel` → `Handle.withdraw` →
  `Processes.cancel` → `Ffi.processesCancel` → the library's process
  service, which kills the child's process group and reaps the child. A
  run the job was still starting when it was cancelled is killed by the
  run's own thread, which sees the cancel as it registers its child; one
  the service had started already, before the job recorded the start, the
  job withdraws itself at its `serve`, which kills the child.
  Removing an owner and ending the runtime cancel through `Handle.cancel`,
  so they reach it the same way. `model-test` shows the withdrawal on the
  fake, and `contract-test` that a real child is reaped.
- **A cancelled job's file requests.** Cancelling a job in a file wait
  withdraws the request at the file service. A load or a save that was
  still waiting there is never worked. A save that was being worked does
  not replace its file: the library reads the cancel before its rename, so
  a cancelled save has either replaced the file whole or not touched it. A
  load that was being worked, and any result the service had kept, is
  dropped. The job is not continued, whichever came first.
- **What a job loaded is released by the runner**, since it registered each
  snapshot with the job as its load replied: when a job fails or is
  cancelled, on the job's own thread after its last request; when a job
  finished, by the editor thread once the job's command has run; and when
  an owner is removed or the runtime ends, for a finished job whose command
  will never run.
- **A streaming child does not outlive its job.** The runner keeps the
  children a job started (`Handle.children`) and, when the job ends,
  finished, failed or cancelled, cancels every one it still holds, which
  kills the child's group in the library: a job's command has no request
  that could use one. A job cancelled in a read or a write has that wait
  withdrawn first, which drops it at the library uncompleted, then its
  children ended. A child is named by its start's wait, so a job cancelled
  while its start is in flight has the start withdrawn, and the library's
  own thread kills the child as it registers it.

### The runner's protocol, modelled

Status: built by host-tests-on-fakes phase 2. How the runner moves many
jobs through their waits is a pure transition system
(`lean/Editor/Job/Protocol.lean`), its safety invariants are proved in Lean
(`lean/Editor/Job/Protocol/Theorems.lean`), and the real runner applies it
one transition per critical section. It is not the job port's model
(`Editor/Job/Model.lean`), which runs one job's requests.

**The states.** Each job has a token (`Protocol.JobState`): where it is, a
flag that says it is cancelled, and the wait it has recorded as its own.
Where it is:

| Status | What it means | Holds a unit |
|---|---|---|
| `queued` | spawned, no wait asked yet | yes |
| `running` | on its thread again after a wait | yes |
| `asking w k e` | its wait `w` of kind `k` (parking or service) registered and handed to its service, not yet recorded; `e` is how it ended, if it already has | yes |
| `waiting w` | in the service wait `w`, recorded | yes |
| `parked w` | in the parking wait `w`, recorded, its unit given back | no |
| `woken c` | its wait ended as `c`, its continuation queued | yes |
| `done` | ended | no |

The state beside the jobs is the runner's share of the activity count, the
next fresh wait and whether the loop has ended. The table of waits is the
waits the `asking` (not ended), `waiting` and `parked` jobs carry, and the
queued wake-ups are the `woken` jobs: both are read off the jobs, not
stored.

**The transitions**, each one atomic step:

| Transition | Enabled when | Effect |
|---|---|---|
| `start j` | `j` is the next job, the loop has not ended | a `queued` job; a unit taken |
| `ask j w k` | `queued` or `running`, `w` fresh | `asking w k`, not ended |
| `park j` (park-with-wait) | `asking w parks e` | not cancelled, not ended: `parked w`, recorded, a unit given back; not cancelled, ended as `c`: `woken c`, recorded; cancelled: `woken`, the wait withdrawn in the step if it had not ended |
| `serve j` (wait-on-service) | `asking w service e` | as `park`, with `waiting w` and no unit given |
| `wake w c` | `w` in the table | `asking` ended early; `waiting w` or `parked w` to `woken c`, a parked job taking a unit back |
| `resume j` | `woken` | `running`, nothing recorded |
| `cancel j` | a job, the loop has not ended | cancelled, nothing recorded |
| `done j` | `queued` or `running` | `done`; a unit given back |
| `loopEnd` | not ended, every cancelled job `done` | ended; no `start`, `cancel` or `loopEnd` after it |

`ask` and `resume` are the model's own: the runner registers a wait and
hands it to its service before it records it, and a service may end it in
between (a sleep already due, a service that is absent), so the model needs
the state between; and the woken job's continuation runs later, on the
pool. A wait that ends before the job has recorded it takes no unit, since
the job still holds its own, and a job cancelled on its way in withdraws its
wait in its `park` or `serve` and keeps its unit: each step moves the count
at most once, and the count is the number of holding jobs. The count is the
runner's share of the host's, and the claim is where `tracksIdle` is set:
handles, the reload and posted events hold the rest, and `Activity.untracked`
moves nothing.

**What is proved**, over every reachable state (`Reachable`), with no
`sorry` and no axiom beyond `propext`, `Classical.choice` and `Quot.sound`,
each theorem's axioms pinned in the module so another fails the build:

- `cancel_finds_running_or_recorded`: a job not cancelled and not done is
  `queued`, `running` or `asking`, on its thread where it sees the token, or
  has its wait recorded, which a cancel takes and withdraws.
- `count_zero_iff_none_holds`: the count is 0 exactly when no job holds a
  unit: none is running or in a service wait, and no wake-up is queued.
- `done_matches_start`: in every run (`Run`) each job starts at most once
  and is done at most as often as it started, so every `done` matches
  exactly one `start`, which comes before it (`Run.prefix`).
- `loopEnd_settles_cancelled`: after loop-end every cancelled job is
  `done`: its wake-up has been handled and its unit given back, and nothing
  can undo that.
- `JobState.serve_keeps_unit` and `JobState.wake_waiting_keeps_unit`: a
  service wait keeps its job's unit, since neither the `serve` that records
  it nor the `wake` of the `waiting` job moves the count.

**A package's wait is a service wait.** A package's service
(`JobRequest.package`) needs no kind of its own: its wait is `.service`,
asked, served and woken as a file's is, so every theorem above covers it,
and the two just above say it keeps its unit. Its traces are runs of the
model: stepped over the fake package service, a wait completed and one
cancelled (`ModelTest.protocolContractChecks`), and over echo's crate on
real threads (`EchoTest/Linked/Echo/Real/Job.lean`).

`run_iff_Run` proves the executable replay (`Protocol.run`) sound and
complete for runs, and `checker_agrees` ties the decidable checker the model
tests search with (`State.violation?`) to the theorems. They go through one
inductive invariant (`Inv`): the count is the number of holding jobs, every
job not cancelled has recorded the wait it is in, and after loop-end every
cancelled job is done.

**One transition per critical section.** The table of waits is behind a
mutex (`Completions`, its constructor and state private), and every access
to it goes through one private section helper (`Completions.critical`),
whether a job is involved or not: registering and ending a wait, counting
the waits, and each job transition. A job's `start` (`spawn`), `ask`
(`Handle.ask`, with the wait's registration), `park` or `serve`
(`Handle.enter`, with a withdrawn wait's removal), `wake`
(`Completions.finish`, with the wait's removal), `resume`, `cancel` and
`done` are one section each, and so is the loop's end
(`Services.endLoop`, below). Inside it the runner decides the step with the
model's own per-job step (`Protocol.JobState.step`), writes the token, moves
the job's unit and records the transition through the recording port
(`Job.Recorder.record`), before it lets the lock go; `Recorder.applied` is
told after, on the same thread. The token's constructor is private and it is
written only by the section's `Section.transition`, so a split step, a unit
given back before the wait is recorded, cannot be written. A section calls
no port, no other section and no promise but the activity's own waiter,
whose consumers are all waits: the services' `start` and `cancel` and the end
of a wait come after it. A host's recorder is `Recorder.none`, which records
nothing; a check gives the runner the fake (`Job.FakeRecorder`), which keeps
the trace and holds a thread at a transition it names, after its section or
inside it.

**The loop's end waits for every cancelled job.** The table keeps the jobs
cancelled and not yet done (`Pending.unsettled`): a job's `cancel` section
adds it unless it is done, and its `done` section takes it out. A host's
loop's end (`Running.wind`) cancels its jobs, then hands a task for each of
those (`Services.unsettled`, each the job's `Handle.finishedRan`) to
`Collaborators.endCancelled`: those its own cancel has just cancelled, and
those an owner's removal (`Jobs.removeOwner`, a reload that installs) or a
keyed cancel (`Jobs.cancel`, `cancelJob`, a start under a key) cancelled
before, which have left its table of jobs. Last it ends the loop in a
section of its own that decides `loopEnd` with the model's own step over
those jobs' tokens (`Services.endLoop`, `Protocol.State.step`), from a state
that has not ended, since the table outlives one loop: `loopEnd` is applied
and recorded only once every cancelled job is done, so a loop's end the
model refuses is never recorded, and after it every cancelled job's
wake-up has been handled and its unit given back, as
`loopEnd_settles_cancelled` has it of the model. A test stage waits for
each task under its hang guard (`Editor.Test.Linked.Stage`), so a job that
never ends is reported as a hang there and never waited for for ever. The
editor's `endCancelled` waits for none, so its loop's end may find a
cancelled job not yet done and record nothing, which its recorder,
`Recorder.none`, would not keep anyway. A table several hosts share holds
their cancelled jobs too, and each loop's end over it waits for them all.

**The pre-fix counterexample.** The runner before the runner-park fix
(784962e3) gave a parking job's unit back, then recorded its wait. Rebuilt
as a step over the same state (`PreFix`, `lean/ModelTest/Support/Protocol.lean`),
a bounded search over it (`ModelTest.protocolChecks`) finds the shortest
trace that breaks `cancel_finds_running_or_recorded`:

```
start 0, ask 0 0 parks, giveBack 0
```

The job is parked, its unit given back, and has recorded nothing, so a
cancel there finds nothing to withdraw: the host read idle, ended its loop,
and the job withdrew its own wait after the host's bracket had returned. The
same search over the protocol finds nothing within 6 steps of one job and 5
of two.

**Where each piece is checked.**

- The model: `ModelTest.protocolChecks`, each transition enabled and
  refused, the replay, and the search.
- The proofs: `lake build`, which elaborates the theorems
  (`Editor/Core.lean` imports them; the config base does not).
- Recorded traces are runs of the model (`Editor/Job/ProtocolContract.lean`,
  `recordedRuns`, each trace replayed by `Protocol.replay`, whose refusal
  names the index, the transition and the state): on the fake clock, files
  and processes (`ModelTest.protocolContractChecks`), a sleep woken, cancelled while
  parked or already due, a cancel held at a job's ask of a sleep or of a
  load, recorded before the `park` or `serve` that withdraws the wait, a
  cancel held between the wake of a load or a streaming start the service
  completed at once and the job's `serve`, after which the service keeps
  nothing of it (`loadCancelAfterWake`, `startCancelAfterWake`), a
  sleep then a load, whose second `ask` comes after its `resume`, a load,
  and several jobs at once; on a stepped host
  (`ConfigTest.protocolContractChecks`), ending in the loop's end; and over
  the library's timer and file services on real threads
  (`ContractTest.protocolContractChecks`).
- The loop's end: on the fakes it is refused, recording nothing, while a
  cancelled job is held at its resume, and recorded once the job is done
  (`loopEndAfterCancelled`); on a stepped host a nap cancelled by its key
  and a config job a reload's install cancelled, each held at its resume
  until the loop's end hands it over to be waited for, are done before
  `loopEnd` is recorded. With the loop's end handing over only the jobs
  still in its table, the stepped check fails in every run: the trace
  records `loopEnd` before both jobs' `done`, and the model refuses it.
- The record is inside the section: a transition held at its record holds
  the table's lock (`Completions.busy`), so a competing cancel records after
  it (`recordedInside`, on the fakes); it fails if the record moves out.
- The park (`parkHolds`): a job held on its own thread just after it gave
  its unit back for its sleep is in a wait the cancel made there withdraws,
  on the runner over the fakes, on a stepped host whose loop's end makes
  the cancel, and on the model; and it is in none on `PreFix`, nor on the
  same stepped host with its park put in the pre-fix order. That last run
  is the stepped host's own check, one function (`ConfigTest.steppedPark`)
  over the park's order (`ConfigTest.ParkOrder`): with the runner's order
  it holds; with the pre-fix order (`ConfigTest.preFixOrder`) the hold
  comes at the job's `ask`, its unit given back, and the loop's end's cancel
  finds no wait recorded and withdraws none, in every run, by the hold
  alone (`asked := some 1, unitBack := true, withdrawn := #[]`). The
  pre-fix order is put together in the config-test module around the real
  runner, from the two collaborators a park moves and tells, the count and
  the recorder: it gives the job's unit back as its `ask` of a wait that
  parks is told applied, before passing that on, absorbs the park's own
  give, and takes a unit back at a park that kept it, as the old wait's end
  did. It is not a seam in the runner, which still applies and records its
  park in one section and alone writes the token, and the editor's wiring
  imports no test module and gives the runner `Recorder.none`, which tells
  no transition for an order to act on. So the split stays unwritable in the runner, what is
  said above of its sections holds unchanged (every access to the table is
  one `Completions.critical`, and the park is one of them), and the proofs,
  which are of the model, are not touched.

**What the model leaves out.** Handles (`Services.fileWorked`), the reload
and posted events, which hold the rest of a host's count; the job table
(`Editor/Job/Table.lean`), the editor thread's record of which results it
still deals with, which no transition reads; the requests a job makes that
are answered at once; and liveness: nothing here says a wait ends. That a
cancelled job ends is the stage's hang guard's to report, not the model's.

### Completing awaits without Rust calling Lean

A service request carries an id. When the work finishes, Rust queues a
completion. A dedicated Lean task pulls completions and resolves the
matching promise, which wakes the job on the pool. The editor thread is not
involved, so a burst of job I/O does not delay typing.

As built:

- **The table of waits** (`Job.Completions`) holds, for each wait in
  flight, an id and the action that ends it: for `register`, resolving the
  wait's promise; for `registerWith`, the caller's own (deterministic-test-concurrency
  phase 2). An id is a counter from 1, never used again in a process.
  `finish` with an id removes the entry in one atomic step and runs its
  action outside it, once, on the thread that finishes it, and does nothing
  for an id that is not there. That is the whole matching rule: a request
  carries its id to the service, the completion carries it back, and a
  completion for a wait that was cancelled meanwhile is dropped.
- **The clock port** (`Job.Timers`) is what the runner's waits are made of:
  read the clock, start a wait with an id and a deadline, withdraw a wait.
  Its fake (`lean/Editor/Job/Fake.lean`) is a clock a test moves by hand;
  its real implementation (`lean/Editor/Job/Real.lean`) is the Rust
  library's timer service ([rust-library.md](rust-library.md)). A deadline
  no machine word holds is clamped, never wrapped.
- **The file port** (`Job.Files`) is beside it: start a file request as a
  wait, take the request's reply once the wait has completed, withdraw a
  wait, and release a snapshot a load's reply named. Its requests are a
  load, a save, a stamp and a listing of a directory (`FileRequest.list`,
  completion's phase 6). A completion says only
  that a wait is over, so a wait's reply is fetched afterwards, on the
  job's thread. Its fake is the pure model of files behind a reference
  (`Job.FakeFiles`), and its real implementation the library's file
  service, which works requests on one thread of its own, in order
  ([rust-library.md](rust-library.md), "Files and watching"). No Lean
  thread is parked for a load or a save.
- **The process port** (`Job.Processes`) is beside them: start a process
  request as a wait, take its reply once the wait has completed, and
  withdraw a wait, which kills the run's child. Its fake is the pure model
  of processes behind a reference (`Job.FakeProcesses`), and its real
  implementation the library's process service, which runs each child on
  threads of its own ([rust-library.md](rust-library.md), "Processes, as
  built"). No Lean thread is parked for a run.
- **The file-watch port** (`Job.FileWatches`) is beside the process port:
  start a watch request as a wait, take its reply once the wait has
  completed, and withdraw a wait or end a watch. Its fake is the pure
  model of watches behind a reference (`Job.FakeFileWatches`), which
  completes a read as soon as a change is recorded and does not apply the
  window; its real implementation is the library's watch service, which
  registers each watch on a thread of its own and coalesces on its timer
  thread ([rust-library.md](rust-library.md), "Watching, as built"). No
  Lean thread is parked for a watch.
- **The grep port** (`Job.Greps`) is beside them: start a search request
  as a wait, take its reply once the wait has completed, and withdraw a
  wait or cancel a search. Its fake is the pure model of project search
  over the fake file service's model (`FakeFiles.greps`); its real
  implementation the library's grep service, which runs each search on a
  thread of its own ([rust-library.md](rust-library.md), "Project search,
  as built"). No Lean thread is parked for a search.
- **The pump** (`Job.pump`) is one dedicated task for the process's one
  table: it pulls the completion queue and finishes the wait each
  completion names, until quit. A completion carries an id whichever
  service queued it. It is `pumpFrom` over a port, `Job.CompletionSource`
  (`lean/Editor/Job/Pump.lean`), whose library adapter is
  `Job.librarySource`; its fake, `Job.FakePump`, is the one step point of
  the job services' fakes ("Recording fakes for the host's background
  collaborators").
- **A flush is a wait like any other** (deterministic-test-concurrency
  phase 1). Each port has a `flush` (`Timers`, `Files`, `Processes`,
  `FileWatches`, `Diffs`): the service completes the wait once it has
  finished the work handed to it before that it can finish on its own,
  queueing the flush's completion behind the completions of that work
  ([rust-library.md](rust-library.md) says what each service covers: due
  waits; every file request, unobserved writes among them; runs ended and
  cancelled children reaped; starts returned; diffs worked). The pump
  finishes waits in the order the queue gives them, so when a flush's
  promise resolves, the promises of the work it covers have resolved.
  `Services.flushed` registers the wait, hands its id to the service named
  by the data variant `Service`, and returns its task; a flush a service
  refuses ends `cancelled`. `awaitWithin` is the one hang-guarded wait: a
  task's value, or `none` past a patience, which a caller reports as a hang
  and never as a result. Each fake flushes as its service does: the fake
  files, diffs and processes park a flush behind their held completions,
  and the fake clock and watches complete one at once. The contract
  (`lean/Editor/Job/FlushContract.lean`) runs on the fakes in `model-test`
  and on the real ports in `contract-test`, the real file service held by
  its in-process hold (`Ffi.filesHold`), a request that parks its worker
  until it is cancelled.
- **A file request's handle** (`Services.fileWorked`, deterministic-test-concurrency
  phase 2) is the task of one file request's reply, for a caller that is
  not a job. It registers the request's wait with `registerWith`, whose
  action takes the reply through the port (`Files.take`), hands it to the
  caller's `noted` and then resolves the task; a wait withdrawn ends with
  `Files.withdrawnReply`. The take runs when the wait ends, not off the
  task: in Lean's runtime a mapped task that is still waiting when its last
  reference goes is deactivated and never runs, so a take hung off the task
  would never happen for a caller that dropped it, and the service would
  keep the result for ever. As built, a caller may drop the task
  (`discard`) and the service keeps nothing of the request. **A handle is
  for one request's reply; a flush is for everything handed before.** The
  contract (`lean/Editor/Job/HandleContract.lean`) runs on the fake file
  service in `model-test` and on the real file port in `contract-test`,
  held by the same in-process hold: a held request's handle has not ended
  until the worker is let go, then ends with its reply, and the service
  keeps nothing of it, dropped or not.
- **Which to use, and the one exception.** Wait on a handle for one
  request's reply; wait on a flush for everything handed out before it;
  hand a request unobserved (no id, no reply, nothing to wait on but a
  flush) only where a bound on the editor thread's cost demands it, and
  say why where it is done. The one such use is the host's session journal
  ("The session journal", below): moved onto handles it cost the editor
  thread 34 to 66 µs a key (102 to 120 µs at 10 MiB) against 3.3 to 3.9 µs
  unobserved (`mise run journal-bench`, side by side in one binary,
  2026-11-21), and every wait for its work is already a flush, so keeping
  it unobserved leaves nothing that polls. The cost is the table of waits
  (about 25 µs a register and take, growing with the waits in flight), task
  `job-wait-table-copy-cost`. The restore checks' copy of the journal
  (`lean/ContractTest/Editor/Restore/Run.lean`) pays no editor-thread cost
  and hands its orders through handles.
- **Cancelling a job cancels the request**: the timer leaves the library's
  schedule, a file request leaves the file service, a run's child is
  killed with its process group, and a pending watch read is withdrawn.
  Ending a job, however it ends, also ends every watch it still holds.
- **A completion-queue turn** is one iteration of the pump: one pull, one
  completion, and the one wait it names finished, whose job's continuation
  then takes its reply on the pool. So a turn ends at most one wait, and a
  job, which is in at most one wait at a time, gets at most one reply a
  turn. The process service queues one completion for each read of a
  streaming child, never one for each chunk the child writes: however fast
  the child writes, the completions of its output equal the reads its job
  made, and each delivery holds everything read up to its take. A child
  held at its bound is waited for by `Service::wait_held`
  (`editor_ffi_processes_await_held` through C), which a reader notifies on
  a Condvar of its own as it parks: a test readout, never a production
  wait, whose bound is a hang guard. The watch
  service does the same for a watch: one completion for each `next`, never
  one for each change on disk, and the delivery holds every change
  recorded up to its take.

A job reaches time and files only through its port, and the runner does not
use `Std.Async`. `Std.Async` works in this process with no extra setup, and
still offers TCP, UDP and DNS; whether sockets come from it, behind a port,
is for the work that first needs one. It has no process spawning and no
file I/O, which is why those go through the Rust service or a dedicated
thread.

### The pool

The pool's size is Lean's: the machine's hardware concurrency, or
`LEAN_NUM_THREADS` if that is set, read once when the process starts. Waits
hold no thread, so the pool only computes, and one thread a core is the
size for that. The editor does not set `LEAN_NUM_THREADS`: every child
process would inherit it. A user can.

Lean makes the pool's threads lazily, one for each task enqueued while no
thread is idle. `Pool.warm` (`lean/Editor/Job/Pool.lean`) makes them all at
start-up: it enqueues tasks one at a time, each held until the end and each
enqueued only once the one before has started. Measured in a prototype: 18
threads in 1.6 ms.

A job that computes and never reaches a request keeps its pool thread: the
runner goes on in a loop on that thread until the job waits or ends. So
with as many such jobs as the pool has threads, a further job waits in the
pool's queue until one of them waits, ends or is cancelled.

## The session journal

Unsaved text is journalled as it changes, so that it is on disk when the
process aborts (session-restore phase 1; `lean/Editor/Restore.lean`).

- **Granularity: once per event, coalesced per buffer.** After each
  publish the loop's reconciler (`Restore.journalOrders`) hands the file
  service one record for each buffer whose text moved since its last: every
  edit since then composed into one patch (`TextId.changesSince`, the
  inserted bytes read by `slice`). Not on idle and a bound: a config command
  that aborts the process usually runs right after typing, so an idle
  window would lose the last keys, and a bound that rewrites the whole text
  costs O(size). Not a job per event: each job's end is another event and
  another publish.
- **The path off the editor thread.** The records are orders
  (`Restore.Order`), plain data on the step (`Loop.Stepped.journal`), which
  the host hands the library's file service as unobserved requests: no id,
  never completed, no result kept, worked in order with every other file
  request on the service's one thread (`crates/editor-ffi/src/files.rs`).
  An append is one `write(2)` with no fsync. The editor thread pays for one
  `changesSince` and one `slice` per moved buffer, a small JSON encode and
  one non-blocking enqueue; a buffer that did not move costs no text
  request. A failure is kept by the service and said once per path.
  **This is the deliberate exception to handles** (deterministic-test-concurrency
  phase 2, owner's decision): a file request's handle
  (`Job.Services.fileWorked`) would cost the editor thread 34 to 66 µs a
  key against 3.3 to 3.9 µs here, for the table of waits' cost (task
  `job-wait-table-copy-cost`), and nothing needs one order's reply: every
  wait for the journal's work is the drain, a flush. So the unobserved
  bindings and the failures readout stay while the host's journal uses
  them, and no other caller should.
- **What an abort loses**: only what is queued and not yet written. Bytes
  handed to the kernel outlive the process; they need not outlive a power
  loss, which is not a goal. An end that is not an abort writes them: a
  host's end, headless or windowed, waits for the journal's drain
  (`Headless.Journal.drained`), a flush of the file service
  (`Job.Services.flushed .files`, deterministic-test-concurrency phase 1)
  completed once every order handed before it has been worked, and not for
  a count. It waits at most `drainPatience`, on purpose in real time, so
  quitting never hangs on a stuck file system. A script's `journalled`, and
  `indexed` once the index is written, wait for the same drain.
- **The port and its adapters.** The port is `Headless.Journal`
  (`lean/Editor/Headless/Journal.lean`), which imports no binding; the
  library's adapter is `Journal.real` (`Journal/Real.lean`), and a host
  check is handed the recording fake (`Journal/Fake.lean`), both held to
  one contract (`Journal/Contract.lean`; "Recording fakes for the host's
  background collaborators", above).
- **Compaction**: past max(1 MiB, the base's size), or when the log was
  forgotten past the record's revision, a new base generation is written
  (an atomic save of a snapshot), then the old one's files removed.

**Measured** (`mise run journal-bench`, `mise run milestone-bench`'s
`type-insert`; [on-demand-checks.md](../dev-practices/on-demand-checks.md),
"Milestone 1, measured"), on an Apple M5 Max, macOS 27.2.1: the reconciler
and the hand-off cost a median of 3.1 to 3.5 µs a key and a 99th percentile
under 7 µs at 4 KiB, 1 MiB and 10 MiB, at the start, middle and end
(`journal_order/<size>/<position>`), under the 20 µs expected; and typing
200 characters at the end of the 10 MiB file, headless, had a median key to
frame of 17242 µs with the journal and 17189 µs without (0.3%), and 17423
against 17434 µs in the small file, within the 5% expected.

**Measured again with phase 2's state** (session-restore phase 2, decision
10): the reconciler now also mirrors the frame, the workspace table, the
stores and the jobs, but compares three revisions (the host's cells', the
table's and the config generation) with the ones last mirrored and runs a
codec only when one moved, and a store's value is rendered only by the
debounced write. With a state of two tabs, five windows, 100 jump entries
and a 10,000-line store of the shape of `shell-history`, whose codec the
reconciler is handed (the bench's own since the shell's store left the
core),
`journal-bench` gave a median of 3.2 to 3.6 µs a key and a 99th percentile
of 4.2 to 6.8 µs (`journal_order/4KiB/start` 3.3 / 6.6, `middle` 3.3 /
6.3, `end` 3.3 / 6.2; `1MiB` 3.2 / 6.1, 3.4 / 4.3, 3.5 / 4.5; `10MiB` 3.3 /
4.2, 3.5 / 6.5, 3.6 / 6.8), as before and under the 20 µs expected.

**Measured against handles** (deterministic-test-concurrency phase 2,
2026-11-21, Apple M5 Max, the machine under other load, the two paths run
alternately in one binary): unobserved, a median of 3.4 to 3.9 µs a key
and a 99th percentile of 4.8 to 15.5 µs; through `Job.Services.fileWorked`,
34 to 66 µs and 74 to 116 µs at 4 KiB and 1 MiB, and 102 to 120 µs and 122
to 209 µs at 10 MiB. The hand-off alone went from 0.1 to 0.3 µs to 31 to
112 µs; an observed append with no wait registered cost 1.2 to 2.7 µs, and
registering and taking a wait 25 to 67 µs, with up to about 1,900 waits in
flight behind the file worker. So the journal stays unobserved (above).

**A restart in flight** (session-restore phase 3;
`lean/Editor/Restore/Restart.lean`). From the restart's probe succeeding
until its exec, or until the hand-over is given up (`Restore.Kept.handing`):

- **The user's input is dropped.** The loop drops the keys, committed text,
  preedits and pointer input it is handed, and says the hand-over again in
  the echo area, so no edit can follow the index the hand-over writes. A
  resize, the focus and the queue's other events are handled as ever, and
  so are jobs' results.
- **Leaving waits.** `EditorState.leaves` is false meanwhile, as it is while
  a save is in flight: a quit or a close request does not end the loop
  under the hand-over.
- **The restart waits for a save in flight** before it writes the session,
  as a quit does: otherwise a save that lands after the index would remove
  a journal the index names. Its save, `restart-save`, starts on the
  publish after the save's result.
- **Its saves follow the journal.** A step's journal orders are handed to
  the file service before the step's jobs are started, and the service
  works its one queue in order, so the index and the record are written
  after every journal order handed before them. A test that must know the
  orders are worked, before its directory goes, waits on the journal's
  drain, a flush of the file service, never on its pending count; its real
  case holds the worker with the service's in-process hold and lets it go
  only once the drain has asked for its flush.
- **A journal write that failed since the hand-over began** gives it up: the
  host runs `restart-abandon` in place of the exec, which writes a new
  generation of every journalled buffer.

## Events

The Rust library delivers events as plain data: a key was pressed, a
process produced output, a file changed, a terminal's title changed.
Lean-side sources (an agent session, a timer, a job result) post to the
same editor queue.

- Events for one subscriber are delivered in order, coalesced where the
  event type allows (output chunks batch; a watch's changes are coalesced
  over a fixed window from the first, one change a path, and delivered a
  read at a time, so a file written without pause is still delivered once
  a window; [rust-library.md](rust-library.md), "Watching, as built").
- A handler runs as a foreground command, or starts a job if it has real
  work to do.
- **A parse delivered is an event.** The syntax worker pushes one `parsed`
  event onto the editor queue for each delivery of a highlighted
  document's parse; the loop changes nothing for it and publishes a scene,
  which lays the text out with the new tree. The worker's consumer takes
  only the queue's lock, under the session's state lock, which nothing
  takes the other way round. Coalescing a burst of them is an open question
  ([rust-library.md](rust-library.md), "Highlights, as built").
- High-rate streams never reach the editor thread per item: terminal output
  goes to the grid inside Rust, and process output is framed and batched in
  Rust and reaches the job that reads it by pull, one completion a read on
  the completion queue, never the editor queue. The editor thread sees
  the job's result when the job ends, and what the job posts while it
  runs: a job that must show its progress, a compile streaming its output
  into its buffer, posts a command by name with plain arguments
  (`post`, below), batched by the job itself, at most one a pause between
  reads.

- **A test waits for a parked pull on the park itself.** `Queue::await_waiting`
  (`editor_ffi_events_await_waiting`, `Ffi.awaitWaiting`) returns once a
  number of pulls are parked on a queue, notified by the pull as it parks,
  under the lock its wait then releases, on a Condvar of its own so a push's
  `notify_one` always reaches a pull. A readout for tests, beside the
  queue's `waiting` count; its bound is a hang guard.

Subscriptions are registered by name and owner, and replaced by owner on
reload. See [lean-runtime.md](lean-runtime.md).

## Reload

Config is elaborated on a background task while the editor keeps running on
the old config. The finished environment is delivered to the editor thread
as an event and installed between commands. A config that fails to
elaborate, or whose setup throws, is rejected and the old one stays.

- The editor's own state (buffers, windows, keymaps, tables) is compiled
  Lean state and is untouched by a reload.
- Jobs and pending handlers that came from the old config are cancelled.
  Their closures keep the old environment alive until the last one returns
  (about 2 MB each for a small config, reused afterwards). A prompt's match
  job that runs config's style is among them: it is spawned under the owner
  of its style, so the install cancels it with config's other jobs, and
  its listing never runs; the scene after the install finds the match
  stamped with the old config generation and spawns one with the new
  config's style, with no key typed (completion's phase 3,
  `Headless.Running.publish`). A completion display needs no such stamp
  (completion's phase 4): it runs only inside the publish, on the editor
  thread, never in a job, and is looked up from the registry for every
  step and every publish, so the scene the install publishes already draws
  an open prompt's list with the new config's display; the state keeps only
  what a display answered, which is data.
- **At-point sources need no stamp either** (completion's phase 5): they run
  only inside commands (`C-SPC`, `C-n` and `C-p`'s, `at-point-triggered`
  and `at-point-paused`), looked up through `Loop.Registered`, rebuilt for
  every step and delivery, so no old config code runs after an install. An
  armed pause holds only a view and a number, and asks the chain as it is
  when it fires. A session holds only data, and one a dropped config
  source opened keeps working on what was collected; its config later
  source's job is config's and cancelled by the install, and its match is
  respawned by the install's publish as a prompt's is.
- Subscriptions and key bindings from config are replaced by owner, never
  accumulated. (`edmacs` repeatedly hit reloads that double-added hooks.)
- Reloads are serialised, so two in flight cannot install out of order.

As built (`lean/Editor/Config/Reload.lean`, `lean/Editor/Headless.lean`):

- **The reload job** is one dedicated task per reload. It makes the base if
  no earlier job has, reads the root and the headers of the config files it
  imports, refuses what a file may not import, creates the config
  directory's lakefile and toolchain file when the host may write them and
  they are absent, grows the base by the linked modules the files import,
  elaborates the files that changed and the files that import them,
  evaluates the root's `setup` and runs it against a collecting handler,
  then resolves a promise with the outcome and posts a wake-up to the
  editor queue. It is a dedicated task, not one of the pool's: it reads
  files, and it writes the module data of the config files under `Config/`
  to a temporary directory of the host's.
- **Lean's "importing" flag is up while the job makes an environment.**
  Making the base, growing it, and making the environment of a file that
  imports config files each run Lean's import with its "importing" flag up
  (`Lean.withImporting`), and each turns the execution of initialisers on
  first, since Lean turns it off when an import ends
  (`lean/Editor/Config/Elaborate.lean`, "The base"). Before config was
  modules the flag was up once in a process, for the base; now it is up for
  30 to 190 ms at a time, once for each such environment, on the job
  thread, while the editor thread runs. What makes that safe is unchanged:
  no initialiser runs. A module the base may hold is linked into the
  executable, so its native initialiser ran when the process started and
  the import skips it; a config module declares none, since a file that
  declares `initialize` is refused before its module data is written. The
  flag itself is read by code that registers extensions and attributes
  from an initialiser, and the editor thread runs none: it runs compiled
  loop code and config's `setup` programs and commands, which are values.
- **A reload needs a pool thread all the same.** Lean's frontend elaborates
  on pool tasks, although the adapter asks for synchronous elaboration. So
  while a job computes on every pool thread and none of them reaches a
  request, a reload does not get to elaborate, and never installs: the jobs
  it would cancel are what keep it from running. Seen while the job
  benchmark was written, when it still ended a row's jobs with a reload:
  with one computing job fewer than the pool has threads the reload went
  through, and with one a thread it had not finished after 45 seconds. No
  test pins this. Jobs that wait do not do it, however many there are.
- **The wake-up** is an event from a Lean source, like any other. The editor
  thread handles it in its turn: it takes the outcome from the promise and
  installs it. That is "between commands".
- **A reducer serialises reloads.** `Config.step` is a pure function from the
  config half of the editor's state and an event (a reload was asked for; a
  job finished) to the new state and the effects to perform (start a job;
  report). At most one job runs. A request that arrives while one runs sets
  a flag, and any number of them make exactly one follow-up job, started
  when the running one's outcome has been handled, so it reads the source
  afresh and starts from what was just installed.
- **An accepted outcome** replaces the files and the config's entries in
  the registry, and meets the config's stores with the cells there are. A
  rejected one changes nothing. Either hands the base back, which a reload
  may have grown, and the state keeps it for the next.
- **Nothing of a replaced config is kept** by the editor: the state holds
  the base and the handles of the files of the config that is installed,
  and a finished job's outcome is dropped once it is installed.
  `config-test` checks this with a base and handles that each hold a
  library handle. Whether Lean frees an old environment is observed by the
  benchmark's soaks (`mise run config-bench`), not gated. One thing is kept
  on purpose: a module file read for an environment stays mapped, since a
  closure of an old config may still be alive
  ([lean-runtime.md](lean-runtime.md), "Config and reload").

- **A command asks for a reload** with `reloadConfig`
  (`lean/Editor/Api.lean`), built by the command loop's phase 12. The
  loop holds no config session, so the request is a one-shot output of
  the step: a flag of the editor state until the command ends, which the
  loop takes out after a command that ran to its end and hands back
  (`Loop.Stepped.reload`), as it does the jobs to start. A command that
  did not run to its end asks for none. The host feeds the reducer a
  request, which is what its driver's `reload` does, so the rules above
  hold unchanged. The command `reload-config` asks, and the ex name
  `reload` is bound to it. The reload is asynchronous: a key typed before
  the install runs the old config's binding. Nothing shows a reload's
  report in the echo area: the headless host prints it. On the models the
  loop's driver counts the requests, since it has no config session
  (`ModelTest.dispatchQuitChecks`, `exChecks`); through the host,
  `ExTest.Linked.exChecks` rewrites a config's file, runs the ex line
  `reload`, and sees the key run the new command.

`config-test` shows the editor answering while a file elaborates: with a
config file's elaboration held open through the elaborator port, 100 events
fed from a Rust thread and a command of the old config are answered before
the file is let go.

**A reload cancels the old config's jobs when, and only when, it installs.**
`Config.step` has an effect for it, `cancelJobs`, which it emits for an
accepted outcome before the reload's report and before a follow-up job
starts, and never for a rejected one. The runtime performs the effects of
one event in order on the editor thread: it takes the owner's jobs out of
the job table and cancels them, so no command or handler of the old config
runs after the install, and a wake-up one of its jobs had already posted
finds nothing. Every accepted reload cancels, one whose source did not
change included. A rejected reload leaves the old config's jobs running,
with their handlers. The reload starts no job of the new config.
`config-test` checks both through the headless host: the cancelled job's
line comes before the reload's, its wait is withdrawn at the clock, and its
handler never runs.

**Config's watches end with its jobs.** A watch belongs to the job that
started it, and the runner ends every watch a job holds when the job ends,
cancelled included (`lean/Editor/Job/Runner.lean`, "A watch does not
outlive its job"). So `cancelJobs` ends the old config's watches, and the
library drops their registrations once no other watch shares them: after a
reload installs, only the watches the new config's jobs start deliver, and
watches are replaced, never piled up. The reload path has no code of its
own for this. `ConfigTest.watchReloadChecks` checks it through the
headless host over the fake watch service: the old config's job is
cancelled before the reload is reported and its watch is ended, the new
config's job is told of a change and says the new version, and a rejected
reload leaves the old config's watch delivering.

## What this buys over Emacs

| Emacs | Here |
|---|---|
| One thread; a slow command freezes input and painting | Painting never waits; input queues behind the command |
| Blocking subprocess calls are the easy path | Blocking is a type error in a command; jobs await |
| A minibuffer read blocks its command in a recursive edit, and can wedge the process | A command that asks names the command that receives the answer and returns; the open prompt is editor state, and keys, jobs' results and reloads go on while it is open |
| Async work means process sentinels and callback chains | Jobs are written top to bottom with awaits |
| Threads share mutable state under a global lock | Immutable values, snapshots, one writer |
| An interrupted command can leave half its edits behind | An interrupted command's edits roll back as one group |

## Still to verify

- The prompt benchmark's maximum: the maximum of a key in a prompt matched
  off the editor thread is printed and not judged ("Prompts", "Matching
  off the editor thread, measured"); one run is recorded, on one machine.

- Files from Finder and the Dock have not been seen arriving: an "Open
  With" cold start, a drop on the Dock icon while the app runs, a two-file
  open showing the second, and `editor notes.txt` from a terminal opening
  one buffer (that `NSTreatUnknownArgumentsAsOpen = NO` took). Everything
  but receiving the real Apple Event is pinned by tests; trying it is the
  roadmap `macos-app`'s phase 6, the owner's.
- The system's quit has been seen only in the window adapter's contract
  example, which calls `terminate:` and sends its own process the quit
  Apple Event. A Quit from the Dock's menu and a logout from loginwindow
  have not been seen reaching the editor; nor has the editor's window
  answering them, since the editor runs in a window only once the macOS
  app is installed.
- An input method's composition on macOS. Real keyboard input reaching the
  Lean loop there is no longer open: the owner checked it by hand on
  2026-11-12, with `mise run window-check` started from Ghostty, and the
  reports are with phase 6 of `workspace-and-ports` in rdm. The tool opens
  the real window through the entry point and counts what reaches a Lean
  loop that pulls the editor queue: keys, the text they typed, dead keys,
  and an input method's composition.

  What the check showed:

  - Key presses, key repeat and releases reach the Lean loop: 438 key
    events in the longest run, 72 of them repeats.
  - The window took the keyboard within 30 ms of opening, in every run,
    with no click.
  - Dead keys arrive at all, through composition: in the run where
    composition became enabled they came as 21 preedit and 12 commit
    events. No key event was marked dead: with composition allowed, a dead
    key on macOS reaches Lean only through composition.

  What it left open:

  - Whether dead keys compose in a window that was never clicked. In the
    run where they worked the window was clicked partway through, and it
    is not known whether the dead keys came before the click. Another run,
    never clicked, reported composition as not enabled, but no dead key
    was pressed in it, so it shows nothing either way; macOS did log an
    input-method error (`IMKCFRunLoopWakeUpReliable`) as that run started.
    The one check left is the rdm task `macos-composition-not-enabled`.
  - The window with composition not allowed (`--no-ime`) was not run on
    macOS, so a dead key arriving as a key marked dead has been seen only
    on Linux, with synthetic keys.
  - Nothing beyond dead keys was tried: no input method that composes a
    script, Japanese for one.

  What the gate covers of that path, with no window: the translation from
  winit's values to the window port's inputs; each input becoming its event
  on a queue, stamped when it was reported (Rust, on the port's fake); the
  bindings and the tool's loop over them, on the same fake (`ffi-test`); and
  the tool's counting and its report (`lean-test`). What it cannot cover is
  winit's own loop, which needs a display. `mise run linux-window` runs that
  loop under Xvfb in a container: there the real window keeps the port's
  contract, and keys typed by xdotool reached the Lean loop, with a dead key
  arriving as a preedit and a commit when composition is allowed and as a
  key marked dead when it is not. Those keys are synthetic.

  The spike's window never took focus. No missing call was found: winit
  already gives an unbundled program the regular activation policy and asks
  to be activated when the application finishes launching. Since macOS 14
  activation is a request the system may decline, and it declines for a
  program started from a session nobody has brought forward, an agent's or
  one behind a locked screen. The tool asks for the focus once and reports
  when it arrived, and whether a click came first. The manual check agrees:
  started from a terminal in front, the window had the keyboard within
  30 ms.
- Linux on x86_64, and real keys on a Linux desktop under X11 and Wayland.
  The gate passes on aarch64 in a container. Windows has not been attempted
  ([lean-runtime.md](lean-runtime.md), "Build").
- The window that draws, on a desktop with a person at it. What has run
  in the container (2026-11-14, aarch64, under Xvfb, on Mesa's software
  Vulkan driver; `mise run linux-window`, part 4): a surface made on the
  main thread from the window's X11 handles, configured, drawn on and
  presented on the render thread, and dropped before the window; a
  fixture frame of real text, read back from the surface, within 1 of
  255 of the CPU's picture; each frame's 14 points drawn at 14 pixels at
  a scale of 1, where that does not show the scale reaching layout, and
  at 28 pixels in a second run where winit is told a scale of 2, where
  it does; no frame drawn for nothing before the render loop comes to
  rest; and a key, a
  named key, a key with modifiers, a press, a drag, a release, a wheel
  turn and a resize each arriving on the queue as the port documents it;
  and a change of scale under an open window, from 1 to 2, made by
  changing the display's settings, arriving as a resize at the size last
  known and the new scale, with the frame laid out for it at 28 pixels.
  What has run on macOS (2026-11-14, one desktop, aarch64, Metal, one
  display at scale 2 that refreshes at 120 hertz;
  [on-demand-checks.md](../dev-practices/on-demand-checks.md), "What the
  first desktop run showed"): a surface on Metal made on the main thread
  and drawn on from the render thread; the picture, within 1 of 255 of
  the CPU's; the refresh rate winit reports, as the window tells it to
  its drawer; a window that opens occluded, is refused its first draws, is told it is shown,
  and then draws once; a window on a display that is asleep, which is
  refused two draws, is told nothing and draws nothing for the half
  minute it stays; and a frame laid out at scale 2, with 14 points drawn
  at 28 pixels. What has not:

  - **macOS, in use.** A run started from a terminal in front; input
    read back event by event; a live resize, where the content may lag
    the window's edge; a window covered and uncovered; the order of a
    modifier's own press and the change that names it; Command and
    Option; what text Escape, Enter and a letter under Control carry; a
    trackpad's wheel in pixels.
  - **Two displays, fullscreen and Spaces, on macOS.** A change of scale
    as a window is dragged from a display at scale 2 to one at scale 1,
    and the antialiasing changing with it; the system's fullscreen, in
    and out, which to the editor is a burst of sizes; another Space and
    back, which is hidden and shown; and whether the text is the size of
    the same 14 points in another app. All of it is read in this tree
    and in winit's source and pinned on fakes, and none of it has been
    seen ([on-demand-checks.md](../dev-practices/on-demand-checks.md),
    "The window's scale, as seen"). Two things there may show and are not
    ours to prevent with what is built: the system stretching the last
    picture between two sizes, and a frame of the old size on the new
    one for a draw.
  - **Wayland**: the window, its surface, and the clipboard, which
    without the data-control protocol goes through XWayland or not at
    all. Nothing here ran a Wayland compositor.
  - **A real display.** Xvfb's says no refresh rate, so the window paced
    by the render loop's own interval: that the rate a display reports
    reaches the loop is pinned by tests on fakes, and has not been seen.
    Nor has a second display, or a rate that changes.
  - **A change of scale as winit sends it.** The event cannot be built in
    a test and was not provoked in the container: its translation is
    tested from its part, the scale.
  - **wgpu's OpenGL back end on a window.** The container has no EGL, so
    only Vulkan ran.
  - **That an idle window costs the main thread nothing.** winit's loop
    waits and the adapter asks for no redraw; the cost itself is not
    measured.
  - **How long making the renderer holds the window's thread**, as the
    window opens: finding an adapter and compiling one shader. It happens
    once. The first frame was presented some 220 ms after the window's
    size arrived, in a debug build on a software driver, which bounds it
    there and says nothing of a GPU.
- The system clipboard, anywhere but in the container (`mise run
  linux-window`, parts 5 and 6). Not run on macOS, where what the empty
  text reads back as is not known either. What a clipboard keeps once the
  editor has exited is not addressed: on X11 with no clipboard manager,
  nothing.
- The rare millisecond-scale sample of the editor loop's latency while jobs
  compute. `mise run job-bench` measures the loop as built, in the headless
  host: the time from posting a request to the editor thread having run it,
  over 10,000 samples a row, with nothing running, with 64 jobs each
  sleeping a millisecond in a loop, with one interpreted job computing on
  each pool thread, with two for each, and with nothing running again. It
  is run by hand and asserts nothing.

  The bound the job system was accepted against: in every loaded row the
  median is within twice the larger of the two idle medians, and the 99th
  percentile is under 100 µs. The maximum is reported and not judged. Two
  runs on an 18-core machine met it. One, at commit `fe5f7fb`, in µs
  (median / 99th percentile / maximum):

  | Row | Latency |
  |---|---|
  | Idle | 1.8 / 5.7 / 20.1 |
  | 64 jobs each sleeping 1 ms (34,824 completions a second through the pump) | 2.8 / 12.7 / 117.5 |
  | 18 interpreted jobs computing | 2.3 / 5.1 / 8,667.0 |
  | 36 interpreted jobs computing | 2.3 / 4.2 / 20.6 |
  | Idle again | 2.3 / 5.3 / 21.0 |

  The other, at `bcb92c4`, is the run recorded with the phase in rdm
  (`workspace-and-ports`, phase 5): idle medians of 2.7 and 2.5 µs, and
  3.4 / 16.5 / 70.8 with 64 jobs sleeping, 2.3 / 6.2 / 3,796.1 with 18
  computing and 2.3 / 6.4 / 45.0 with 36. Across both, the largest median
  in a loaded row was 3.4 µs, against a limit of 5.4 µs, and the largest
  99th percentile 16.5 µs, against 100 µs.

  Two things are noted beside the bound. With 64 jobs sleeping, the 99th
  percentile was more than twice the idle one in both runs (12.7 µs against
  5.7, and 16.5 against 5.7): every wait goes through the timer service and
  the pump, tens of thousands of times a second, and the tail of the loop
  shows it, at a scale far below the bound. The benchmark's `within bound:`
  line judges each loaded row by the bound above, and so by the 99th
  percentile's size, not by its ratio to idle.

  What stays open is the maximum. With a job computing on every pool thread,
  one sample in 10,000 took 8.7 ms in one run and 3.8 ms in the other: the
  pool is as wide as the machine, so the editor thread competes with it for
  a core. It is not tuned away. If that tail matters, the remedies are a
  pool smaller than the machine (only `LEAN_NUM_THREADS` at process start
  does that, and children inherit it) or a higher scheduling class for the
  editor thread, set in the glue.
- Key latency in the real command loop. Two things are measured so far, and
  neither is that. The job benchmark's sample is a command run through the
  headless loop, not a key. The keyboard check's sample is a key: the time
  from the instant the window's loop was handed it, read in Rust on the main
  thread, to the instant a Lean loop had pulled the event and read the same
  clock. That is the hand-off across the boundary and the thread wake-up,
  with a loop that does nothing else. With a person typing on macOS its
  median was about 17 µs: 17.4 µs over 438 key events in one run and
  17.5 µs over 100 in another, with 99th percentiles of 30.5 and 50.8 µs
  and maxima under 90 µs. Under Xvfb in a container, with synthetic keys,
  its median was 24 to 34 µs in the runs made, of 40 to 42 samples each.
  What the command loop still has to show is the time from that arrival to
  the edit being applied and the frame asked for, with keymap lookup, a
  command and a real editor state between.
- A reload while every pool thread computes (see "Reload"): whether the
  reload job's elaboration can be kept off the pool, or the pool kept from
  filling with jobs that never wait. Tracked as the rdm task
  `reload-starves-under-computing-pool`.

## Open questions

- **Rebasing proposed edits.** When does the foreground rebase and when
  does it reject? A rule per kind of edit, or one conservative rule?
- **Backpressure.** Answered for process output: a streaming child whose
  undelivered output reaches its bound is held, by not being read, until its
  job reads ([rust-library.md](rust-library.md), "Processes, as built").
  Answered for watches: a delivery holds at most a bound of distinct
  paths, the job's, and past it the batch is one change, missed, on the
  watch's own path, so a recursive watch during a `git checkout` hands its
  job one change ([rust-library.md](rust-library.md), "Watching, as
  built"). Still open for jobs' results and events: what happens when they
  pile up faster than the foreground drains them?
- **Prompts** ("Prompts"). Each of these was decided one way, and the
  other is still possible:
  - the answer is the continuation's first argument, and not its last;
  - a second prompt is refused, and neither replaces the first nor is
    stacked on it;
  - an answer's command that fails does not open the prompt again with the
    text typed, which would need the answer kept across the failure;
  - the continuation's name is not checked when the prompt is asked for;
  - when the asking view was closed the prompt stays open and the answer
    goes to the first window of the tree, where cancelling the prompt
    with its asker is the alternative;
  - the answer's command is a step of its own that the host runs, where
    running it in the accepting command's step would keep the rule in the
    loop alone, at the cost of a stale store cell and of a step that
    stands for two commands.
- **Raw `IO`.** Lean code can reach `IO` directly (files, processes) and
  bypass the interfaces, which breaks the pure model and the fakes, and for
  processes leaves orphans. For commands and jobs this is answered: neither
  can express `IO`. Both are programs over a port
  ([lean-runtime.md](lean-runtime.md), "The editor API is an interface"),
  a program is plain data that holds no `IO`, and an `IO` action offered
  as a command or as a job is a type error, checked when
  `lean/Editor/Job.lean` is compiled. A job's waits are requests of its
  port, and a wait offered as a command is a type error too, checked in the
  same place. The config session runs no `IO` action
  from config either: `setup` is a program over the setup port, a command is
  a program, and nothing else of config's is evaluated
  ([lean-runtime.md](lean-runtime.md), "The config session as built"). What
  remains open is Lean code outside them: compiled runtime code (the command
  loop, the runners, the config session) is in `IO`, and config can still
  define an `IO` action. The session never runs one, but Lean's elaborator
  does when a config file says `#eval`, on the job thread, while the file
  elaborates. Should that be impossible too, or merely discouraged?
