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
| **Main** | Rust | The window, the OS event loop, IME | Wait on anything; run Lean code |
| **Editor** | Lean, a dedicated task | All mutable editor state. The single writer. Pulls events and runs commands and handlers one at a time | Block on I/O or long computation |
| **Lean pool** | Lean | Background jobs that compute or await | Mutate editor state; block |
| **Dedicated job threads** | Lean | Work that blocks in a system call: the reload job today | Mutate editor state |
| **Completion pump** | Lean, a dedicated task | Pulling the completion queue and ending the wait each completion names | Run a job; mutate editor state |
| **Render** | Rust | Turning the published scene into frames and drawing them. Shares the layout cache with the editor thread's layout queries | Run Lean code |
| **Services** | Rust | Timers, child-process pipes, pseudo-terminals, file watches | Hold editor state; call Lean |
| **Workers** | Rust | Tree-sitter parsing, diff, fuzzy matching | Hold editor state |

Rust never calls Lean. The main thread and the services push events onto a
queue, and the editor thread pulls them with a blocking call. Measured in
the spike, a key takes 6 to 12 µs (median) from arrival in Rust to the edit
being applied, most of it the thread wake-up.

On macOS the process's real main thread must run the window. Lean runs its
`main` on a thread it creates, so a small C entry point keeps the real main
thread for Rust and starts Lean on a second one.

### Sharing state

Editor state is an immutable Lean value held by the editor thread. Handing
a job a snapshot is handing it that value. Text lives in Rust ropes, whose
snapshots are cheap; a job or the renderer holds a snapshot handle.

After each command the editor thread publishes the scene (which views show
which text snapshots, with which decorations) to the Rust library. Rendering
reads the last published scene. Layout queries from a command are
synchronous calls answered in the same call (see
[text-and-display.md](text-and-display.md)); the layout cache is the one
structure both threads touch, so its locking is kept per line.

## Foreground: commands

A command is Lean code that may change editor state. Commands run one at a
time, in order, on the editor thread.

- **Ordering.** While a command runs, later input queues behind it, so keys
  typed during a slow command are not reordered. Painting continues from the
  last published scene.
- **Interrupt.** An interrupt key (Emacs's `C-g`) sets a flag in the Rust
  library as the key arrives. Editor API calls check it, so an interrupted
  command unwinds as an ordinary exception at its next call.
- **Rollback.** A command's edits form one transaction group, so a failed
  or interrupted command's edits are reverted as a unit.
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

As built (`lean/Editor/Job.lean`), a job reaches time and nothing else yet:

- **`JobM` is a program over the job port** that may fail with a message,
  so it has `throw`, `try` and `catch`. It is plain data and holds no `IO`.
- **The port's requests are a clock and a wait**: `now` reads the job
  clock, in milliseconds, and `waitUntil` returns once the clock reads a
  deadline or later. `sleep` is written with the two, and so is a `Timer`,
  which is plain data: the instant of its next tick and its period, so its
  ticks do not drift with the work between them.
- **No request carries a promise.** A request is plain data; how a wait is
  completed is the runner's business. A process, a file or a snapshot of
  editor state arrives as further requests of this port, each with a reply
  type, a clause in the model, an answer in the runner and a property in
  the contract.
- **Cancellation is not a reply.** No reply says "cancelled" and nothing is
  thrown into a job; see below.
- **A wait is not a command**, checked when `lean/Editor/Job.lean` is
  compiled: a wait offered at `EditorM Unit` is a type error, alone and
  after a text request in a `do` block. So "a command may not block" is
  pinned beyond `IO`.

The port has a pure model (`lean/Editor/Job/Model.lean`: a clock, and the
instant at which the job is cancelled) and a contract
(`lean/Editor/Job/Contract.lean`), a list of inequalities run three ways:
against the model and against the runner over a fake clock by `lake test`,
and against the runner over the Rust timer service by `contract-test`.

### Getting results back

- **Message.** The job finishes with a value, and a foreground handler
  receives it: `spawn job (fun result => …)`. The handler runs as a command.
- **Proposed edit.** The job builds a transaction against the text revision
  it read and submits it. The foreground maps it through any edits made
  since (the same position mapping anchors use) and applies it, or rejects
  it as stale if the text it touched has changed. A formatter, a rename, or
  an agent's edit all take this route.

As built, the message route, and not yet the proposed edit:

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
| Blocked jobs starve the pool | A wait is a promise in the table of waits, completed by the pump, and the rest of the job is chained on it, so a job in a wait holds no thread. The pump is a dedicated task. No request of the job port blocks in a system call yet, so no job runs on a dedicated thread; the reload job is the one piece of work that does | `model-test`: more jobs than the pool has threads (at least 64) all reach their wait on a fake clock, from fewer threads than there are jobs, while a new pool task runs. Written first with `IO.wait`, it failed with one thread a job. `contract-test`: the same with real one-hour timers, and with the pump parked in its pull a warming holds exactly the threads the pool had before the pump was started |
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
- **The pump** (`Job.pump`) is one dedicated task for the process's one
  table: it pulls the completion queue and finishes the wait each
  completion names, until quit.
- **Cancelling a job cancels the request**: the timer leaves the library's
  schedule.

A job reaches time only through its port, and the runner does not use
`Std.Async`. `Std.Async` works in this process with no extra setup, and
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

- Real keyboard input reaching the window. The spike's window never took
  focus, so keys were only tested through the same queue synthetically.
- Linux and Windows. The entry point and linker workarounds are for macOS.
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
  shows it, at a scale far below the bound. The benchmark's own
  `unaffected:` line still judges the 99th percentile by that stricter
  rule, twice idle, and so prints `no` for this row.

  What stays open is the maximum. With a job computing on every pool thread,
  one sample in 10,000 took 8.7 ms in one run and 3.8 ms in the other: the
  pool is as wide as the machine, so the editor thread competes with it for
  a core. It is not tuned away. If that tail matters, the remedies are a
  pool smaller than the machine (only `LEAN_NUM_THREADS` at process start
  does that, and children inherit it) or a higher scheduling class for the
  editor thread, set in the glue.
- Key latency itself, with a window: the benchmark's sample is a command
  run through the headless loop, not a key.
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
