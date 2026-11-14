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
| **Editor** | Lean, a dedicated task | All mutable editor state. The single writer. Pulls events and runs commands and handlers one at a time | Block on I/O or long computation |
| **Lean pool** | Lean | Background jobs that compute or await | Mutate editor state; block |
| **Dedicated job threads** | Lean | Work that blocks in a system call: the reload job today | Mutate editor state |
| **Completion pump** | Lean, a dedicated task | Pulling the completion queue and ending the wait each completion names | Run a job; mutate editor state |
| **Render** | Rust | Turning the published scene into frames and drawing them. Shares the layout cache with the editor thread's layout queries (the design; what is built, and the decision it awaits, are under "Sharing state"). As built it owns the renderer alone (the device, the surface, the glyph atlas, the quads kept per row), takes frames from a mailbox, and never lays out. `editor-ffi` starts it when a window opens and ends it when the window closes; idle, it is blocked with no deadline | Run Lean code; call layout or a shaper; hold a lock while it draws; touch the window's loop |
| **Services** | Rust | Timers, loading and saving files, child-process pipes, pseudo-terminals, file watches | Hold editor state; call Lean |
| **Workers** | Rust | Tree-sitter parsing, diff, fuzzy matching | Hold editor state |

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

Editor state is an immutable Lean value held by the editor thread. Handing
a job a snapshot is handing it that value. Text lives in Rust ropes, whose
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
  one writer and no reader but a command.
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
- **The journal reads the clock that stamps input**: `editor-ffi`'s input
  clock is the loop's clock too, so a frame's latency is a subtraction on
  one clock.

That the render thread draws, and not the main thread from the window's
own redraw event, **awaits the owner**. The other way needs no second
thread and no join, and blocks the window on every present.

Not built: anything from Lean reaching the session. The process's window
is run with nothing drawing in it, and frames published from Lean reach
no renderer until the display pipeline's phase 6. The session has run
with a real renderer in a real window only in an example, on demand
(`crates/editor-ffi/examples/window.rs`), where a second thread stands in
for the editor.

## Foreground: commands

A command is Lean code that may change editor state. Commands run one at a
time, in order, on the editor thread.

- **Ordering.** While a command runs, later input queues behind it, so keys
  typed during a slow command are not reordered. Painting continues from the
  last published scene.
- **Interrupt.** An interrupt key (Emacs's `C-g`) sets a flag in the Rust
  library as the key arrives. Editor API calls check it, so an interrupted
  command unwinds as an ordinary exception at its next call.
- **Rollback.** A failed or interrupted command's edits are reverted as a
  unit. The mechanism is built, in the undo tree
  (`lean/Editor/UndoTree.lean`): the loop keeps the tree's state before a
  command and reverts to it if the command fails, by one inverse of the run
  of revisions the command made. That state may be a point inside an insert
  session's open group, so a command's edits need no group of their own. A
  command that moved in the history (an undo, a redo) is not rolled back
  this way, since the move closed the group; what the loop does then is the
  command loop's to decide. The loop that does this is not built yet.
- **Slow commands are logged**, with their duration, so a command that
  should have been a job is easy to find.

The type of a command is `EditorM α`. It offers no blocking operations: no
"run this process and wait", no "read this file", no "wait for this job".
Long work belongs in a job.

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

As built (`lean/Editor/Job.lean`), a job reaches time and files:

- **`JobM` is a program over the job port** that may fail with a message,
  so it has `throw`, `try` and `catch`. It is plain data and holds no `IO`.
- **The port's requests are a clock, a wait and a file request**: `now`
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
- **No request carries a promise.** A request is plain data; how a wait is
  completed is the runner's business. A process or a snapshot of editor
  state arrives as further requests of this port, each with a reply type, a
  clause in the model, an answer in the runner and a property in the
  contract.
- **Cancellation is not a reply.** No reply says "cancelled" and nothing is
  thrown into a job; see below.
- **A wait is not a command**, checked when `lean/Editor/Job.lean` is
  compiled: a wait offered at `EditorM Unit` is a type error, alone and
  after a text request in a `do` block, and so is a file request. So "a
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
  its turn, takes the result from the job table, and runs the command
  exactly as it runs any command. `config-test` records the thread each
  line of output comes from and requires a job's line to come from the
  thread that prints a command's.
- **Config registers a job by name** in `setup`:
  `job "count" count fun n => …`, where `count : Unit → JobM Nat`. `setup`
  starts nothing. The runtime that owns the job table starts a registered
  job when it is asked to: the headless loop's `spawn <name>` today. A
  command cannot start a job yet: `EditorM` has no such request, and adding
  one is for the phase that grows the editor's port.

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
| Lean never kills or reaps a child process; children outlive the editor | Child processes belong to the Rust process service. See [rust-library.md](rust-library.md). |
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
test` runs `model-test` (`lean/ModelTest.lean`), with no Rust library;
`contract-test` and `config-test` are linked with it and run by
`mise run ffi-test`.

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

- **The token** is in the job's handle: a flag, and the id of the wait the
  job is in, changed together in one atomic step.
- **Every wait races it.** Cancelling sets the flag, takes the waiting id,
  tells the service to withdraw that request and ends its promise as
  cancelled. A promise resolves once, so whichever of the service and the
  cancel comes first wins, and the other does nothing. A wait the job was
  still making when it was cancelled is withdrawn by the job itself.
- **A cancelled job makes no further request**, and its outcome is
  `cancelled` whatever it would have returned.
- **A cancelled job runs no cleanup of its own.** There is no `finally`
  after a cancellation. What a job holds is the runner's to release: the
  wait it is in is withdrawn, and a handle to a library object is freed by
  its finaliser when the continuation is dropped. The process service will
  need its requests to register what they open with the job, so that the
  runner releases it. That is not designed.
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

### Completing awaits without Rust calling Lean

A service request carries an id. When the work finishes, Rust queues a
completion. A dedicated Lean task pulls completions and resolves the
matching promise, which wakes the job on the pool. The editor thread is not
involved, so a burst of job I/O does not delay typing.

As built:

- **The table of waits** (`Job.Completions`) holds, for each wait in
  flight, an id and a promise. An id is a counter from 1, never used again
  in a process. `finish` with an id removes the entry and resolves its
  promise, and does nothing for an id that is not there. That is the whole
  matching rule: a request carries its id to the service, the completion
  carries it back, and a completion for a wait that was cancelled meanwhile
  is dropped.
- **The clock port** (`Job.Timers`) is what the runner's waits are made of:
  read the clock, start a wait with an id and a deadline, withdraw a wait.
  Its fake (`lean/Editor/Job/Fake.lean`) is a clock a test moves by hand;
  its real implementation (`lean/Editor/Job/Real.lean`) is the Rust
  library's timer service ([rust-library.md](rust-library.md)). A deadline
  no machine word holds is clamped, never wrapped.
- **The file port** (`Job.Files`) is beside it: start a file request as a
  wait, take the request's reply once the wait has completed, withdraw a
  wait, and release a snapshot a load's reply named. A completion says only
  that a wait is over, so a wait's reply is fetched afterwards, on the
  job's thread. Its fake is the pure model of files behind a reference
  (`Job.FakeFiles`), and its real implementation the library's file
  service, which works requests on one thread of its own, in order
  ([rust-library.md](rust-library.md), "Files and watching"). No Lean
  thread is parked for a load or a save.
- **The pump** (`Job.pump`) is one dedicated task for the process's one
  table: it pulls the completion queue and finishes the wait each
  completion names, until quit. A completion carries an id whichever
  service queued it.
- **Cancelling a job cancels the request**: the timer leaves the library's
  schedule, and a file request leaves the file service.

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

## Events

The Rust library delivers events as plain data: a key was pressed, a
process produced output, a file changed, a terminal's title changed.
Lean-side sources (an agent session, a timer, a job result) post to the
same editor queue.

- Events for one subscriber are delivered in order, coalesced where the
  event type allows (output chunks batch, file-watch bursts are debounced).
- A handler runs as a foreground command, or starts a job if it has real
  work to do.
- High-rate streams never reach the editor thread per item: terminal output
  goes to the grid inside Rust, and process output is framed and batched in
  Rust before it is queued.

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
  (about 2 MB each for a small config, reused afterwards).
- Subscriptions and key bindings from config are replaced by owner, never
  accumulated. (`edmacs` repeatedly hit reloads that double-added hooks.)
- Reloads are serialised, so two in flight cannot install out of order.

As built (`lean/Editor/Config/Reload.lean`, `lean/Editor/Headless.lean`):

- **The reload job** is one dedicated task per reload. It reads the source,
  imports the base if no earlier job has, elaborates the chunks that
  changed, evaluates `setup` and runs it against a collecting handler, then
  resolves a promise with the outcome and posts a wake-up to the editor
  queue. It is a dedicated task, not one of the pool's: it reads files.
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
- **An accepted outcome** replaces the chunks and the config's entries in
  the registry, and meets the config's stores with the cells there are. A
  rejected one changes nothing.
- **Nothing of a replaced config is kept** by the editor: the state holds
  the chunks of the config that is installed, and a finished job's outcome
  is dropped once it is installed. `config-test` checks this with states
  that each hold a library handle. Whether Lean frees an old environment is
  observed by the benchmark's soak (`mise run config-bench`), not gated.

`config-test` shows the editor answering while a chunk elaborates: with a
chunk's elaboration held open through the elaborator port, 100 events fed
from a Rust thread and a command of the old config are answered before the
chunk is let go.

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

## What this buys over Emacs

| Emacs | Here |
|---|---|
| One thread; a slow command freezes input and painting | Painting never waits; input queues behind the command |
| Blocking subprocess calls are the easy path | Blocking is a type error in a command; jobs await |
| Async work means process sentinels and callback chains | Jobs are written top to bottom with awaits |
| Threads share mutable state under a global lock | Immutable values, snapshots, one writer |
| An interrupted command can leave half its edits behind | An interrupted command's edits roll back as one group |

## Still to verify

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
- The window that draws, anywhere but in the container. What has run
  (2026-11-14, aarch64, under Xvfb, on Mesa's software Vulkan driver;
  `mise run linux-window`, part 4): a surface made on the main thread from
  the window's X11 handles, configured, drawn on and presented on the
  render thread, and dropped before the window; a fixture frame of real
  text, read back from the surface, within 1 of 255 of the CPU's picture;
  no frame drawn over an idle second; and a key, a named key, a key with
  modifiers, a press, a drag, a release, a wheel turn and a resize each
  arriving on the queue as the port documents it. What has not:

  - **macOS, all of it.** A surface on Metal made on the main thread and
    drawn on from the render thread; the picture; a live resize, where
    the content may lag the window's edge; occlusion, and that a hidden
    window is told so; the refresh rate winit reports; the order of a
    modifier's own press and the change that names it; Command and
    Option; what text Escape, Enter and a letter under Control carry; a
    trackpad's wheel in pixels; a change of scale between two displays.
    All of it is read in the libraries' source or compiled, none of it
    run. The steps are in
    [on-demand-checks.md](../dev-practices/on-demand-checks.md), "The
    window's contract, on a desktop".
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
- **Backpressure.** What happens when jobs or events pile up faster than
  the foreground drains them?
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
  does when a chunk says `#eval`, on the job thread, while the chunk
  elaborates. Should that be impossible too, or merely discouraged?
