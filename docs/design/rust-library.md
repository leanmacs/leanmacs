# The Rust library

What the Rust library provides to the Lean editor, timers among it, and what
the editor gets from Lean's own runtime instead. The test of this list is whether
whole features (version control, the rdm client, the agent UI) can be
written in Lean on top of it with nothing feature-specific in Rust.

Text storage and the display path are in
[text-and-display.md](text-and-display.md). This document covers the rest.

## The pattern

Every service has the same shape:

- **In Rust**: the logic is plain Rust over ports (traits) for the real
  things it touches, with a hand-written fake and a contract check per
  port, and a thin adapter. It is tested by `cargo test` with no Lean.
- **At the boundary**: a few C functions in `editor-ffi`. Long-lived
  objects are handles. Requests and results are plain data, and grow by
  adding variants and fields, not functions.
- **In Lean**: a binding, behind an interface the editor defines, with a
  pure model for tests. A contract check runs the same properties against
  the model and the real binding.

Calls go from Lean to Rust only. Anything that happens later (output
arrived, a process exited, a file changed) is an event Lean pulls, tagged
with the request or handle it belongs to. See
[concurrency.md](concurrency.md).

What a service must provide for a job to wait on it, as the timer service
does (the crate docs of `crates/editor-ffi/src/lib.rs`, "Services and
completions"):

- **`start`, with the caller's id.** It returns at once and never blocks: a
  job that waits holds no thread.
- **One completion event for each started request**, on the completion
  queue, whose code is the request's id; none if the request was cancelled
  first.
- **`cancel(id)`**, which stops the underlying work and is safe for an id
  that is unknown or done. A completion may still arrive after it, and Lean
  ignores a completion for an id it is no longer waiting for.
- **Plain data only.** The service never calls Lean: a dedicated Lean task,
  the completion pump, pulls the queue.

These conventions are a crate of their own, `editor-service`, which
`editor-ffi` and the crate of every package that holds Rust depend on: the
two event queues (`queue`, which `editor-ffi`'s `events` re-exports), the
registering of a service and its completion (`Service`, whose id a
process-wide counter gives from 1024 up; the core's services keep their
fixed ids below it and report with `events::complete`), the port a service
reports through (`Completer`, with the fake `RecordingCompleter` and the
contract `completer_contract`), the buffers that cross the boundary
(`buffer`), and the owner of a thread a service starts for a scope
(`Worker`, in `worker`): dropping it runs the `stop` it was given, once,
and joins the thread, on every path, a panicking test's included, so a
thread a test starts has ended before the test does. A worker dropped on
its own thread does not join itself. The process's own services are
statics that are never dropped: their threads live for the process and end
with it, and they are no workers. A package's crate depends on it and on
nothing else of the editor's ([packages.md](packages.md), "Rust in a
package").

## Timers

The first service behind the completion queue
(`crates/editor-ffi/src/timers.rs`). A job's `sleep`, its `waitUntil` and
its `Timer` are all waits on this service.

- **The clock is a port**: milliseconds since the clock began, with the
  real monotonic clock and a published fake a test moves by hand.
- **The schedule is pure**: which wait is due when, earliest deadline first,
  and what cancelling means, tested with no thread and no clock.
- **The service loop** completes due waits and otherwise parks until the
  next deadline, a new wait, or a wake for a fake clock that was moved. The
  process has one instance, whose thread starts with the first request. A
  completion is an event of the kind `Completion` from the library source,
  whose code is the request's id.
- **A flush** (`editor_ffi_timers_flush`, deterministic-test-concurrency
  phase 1) is due at the clock's reading when it is asked, and comes out of
  the schedule in the same turn as every wait due by then, after them,
  whatever their ids. So its completion is queued behind those of every
  wait that was due when it was asked. A wait not yet due is not covered:
  it is no work the service can finish now.

Timers were listed as Lean's (`Std.Async`). They are in the library because
every wait of a job then completes one way, through the pump; because the
clock is then one port with one fake, on each side of the boundary; and
because the pump is proven by the simplest service before processes depend
on it.

## Processes

The workhorse: version control, the rdm client, agents, language servers,
linters, formatters and test runners are all processes.

Lean's own process support is not enough. In the experiments a dropped or
cancelled child kept running, exited children stayed as zombies, and
children outlived the editor. So the library owns every child process.

- **Spawn** with argv, environment and working directory. Stdin is a
  writable stream or closed. Stdout and stderr are captured separately.
- **Output** arrives as a complete result (for short commands) or as framed
  events (for long-lived ones). Framing is done in Rust: lines, chunks, or
  length-prefixed messages, batched before they are queued.
- **Ownership.** A process handle that is dropped or cancelled kills its
  process group. Every child is reaped. When the editor exits, no child
  survives unless it was started detached on purpose.
- **Pseudo-terminals** are the same service with a terminal attached; the
  terminal emulator below reads from one.

From Lean, a job awaits a short command as one call, and a long-lived
process is a handle plus a stream of events.

### Processes, as built

The first use, "run to the end and collect the output", which git needs
(the process service's phase 1), and streaming children, whose output a
job reads as it comes and whose standard input it writes to (phase 2;
"Streams and input", below).

- **The port** is `editor-process`'s `Processes`, in the editor's terms: a
  `Command` (a program, its arguments, an environment and an absolute
  directory) is spawned as a `Child` in a process group of its own, with
  both output streams piped and its standard input closed or, when the
  spawn asks (`Input::Pipe`), piped and taken as a `ChildInput`. The input
  is the spawn's, not the command's, and the service decides it once: a
  run's child has its input closed unless the run is fed, and a streaming
  child's is its `Streaming`'s, as in Lean, where `Process.Streaming` and
  the fed run (`ProcessRequest.runInput`) have one. The child's
  streams are read with a pull (`Output::read`), it is waited for
  (`Child::wait`) and killed (`Child::kill`). A program is a bare name,
  looked up on the `PATH` the child gets, or an absolute path; the
  environment is the editor's, emptied first if asked, then with variables
  unset and then set. A spawn that fails is a `Refusal`, a kind (not
  found, denied, failed, and the service's own: a relative directory, a
  relative program, shut down) and the platform's words naming the program
  and the directory. The port is pull-based and blocking, so backpressure is the core not
  reading, and a write is held by the pipe it writes to.
- **The app's identity**: the service adds `CFProcessPath` to every
  command's `unset` (`Command::without_app_identity`), whatever the command
  said, so a program the editor runs never takes the app as its own main
  bundle; the launcher sets it in the editor's environment on macOS ("The
  app's launcher", below). The fake matches a script whether or not a
  command's `unset` names it.
- **The rules of a child**: `wait` blocks until the child has ended, then
  ends every process still in its group, then reaps the child, and answers
  the same if asked again; `kill` ends the whole group, may be called from
  any thread while `wait` blocks, and does nothing once the child has been
  reaped.
- **The fake** (`editor_process::fake::FakeProcesses`) is a table of
  scripts by command: what the child writes, how and when it ends, how many
  processes it starts in its group, how many outside it (which no group
  kill ends, holding the streams open), which ids it writes to which file,
  and a stream whose read fails. It records every spawn, kill and reap,
  answers whether an id is alive, and holds a child, a read or a reap on a
  latch so a test acts while a run is in flight without sleeping.
- **The contract** (`editor_process::contract::check`) holds an
  implementation to fourteen properties in a directory its caller owns,
  with a ground that makes a file, reads the ids a child wrote, asks
  whether a process is alive, a zombie counted as alive, and ends a process
  outside a child's group. Eight are the
  port's: a run to its end, an exit by signal, the directory, the
  environment, the refusals, a kill that ends a child and the grandchild it
  started (`/bin/sleep 600 &`), the stragglers of a child that exits by
  itself, and a kill after the reap. Six are the service's, run over the
  given processes: a cancelled run's child and grandchild end and it is
  never completed; after shutdown every child is reaped and every
  grandchild ends; a start after shutdown is refused; a spawn refusal is a
  result, completed once; output past the limit kills the group; and a run
  whose descendant left its group holding its streams still ends at a
  cancel and at shutdown. That descendant is started with Perl's `setpgrp`
  (`/usr/bin/perl`, on macOS and on Debian alike; macOS has no `setsid`
  command), and the property is skipped, saying so, where it is absent. The
  fake keeps it, fakes written to break one rule each (a group kill that
  ends only the child, a wait that does not reap, one that leaves the group
  alive, one that drops standard error, one that reports a signal as a
  status, one whose second wait answers otherwise) are each reported, and
  the real adapter keeps it on real processes in a temporary directory.
- **The service** (`editor_process::service::Service`) is above the port
  and beside it, not in `editor-ffi`, so that the contract can drive its
  cancelling and its shutdown on the real adapter. A run is started with
  the caller's id and returns at once; its thread refuses a relative
  directory or program before any spawn, spawns, starts a reader thread for
  each stream, waits, waits for both readers to reach their stream's end,
  keeps the result and calls the completion. Three threads for each
  running child. A cancel, or shutdown, stops the run waiting for its
  readers: the run is over once its child is reaped, and its readers,
  detached, end when their streams close. A stream past the
  run's limit of bytes kills the group and the run is `OutputTooLarge`,
  never output cut short. **A run may be fed its standard input**
  (`Service::start_with_input`): its child's input is then a pipe, and a
  fourth thread, its writer, detached as the readers are, writes every
  byte while the readers read and then drops the pipe, so the child reads
  end of file; input larger than a pipe cannot hold a child that writes as
  it reads. A write the child does not take, because it closed its input
  or ended, is ignored, and the run comes to what the child did. This is
  how a filter feeds a range of lines to a command (`:{range}!`,
  `docs/design/keymaps-and-modes.md`). The contract holds it to two more
  properties: `/bin/cat` fed four pipes' worth, a NUL and a byte that is
  not UTF-8 among it, gives it back whole; and `/usr/bin/true` fed a
  mebibyte exits 0. **A run may keep the head of its standard output**
  (`Service::start_head`, project navigation's phase 1): it is fed as
  above, and its standard output's reader, once the stream goes past the
  run's limit, keeps exactly the first `limit` bytes, kills the group and
  the run comes to `RunResult::Cut` with them and what was read of
  standard error; how the child ended is not said, since the service ended
  it. Standard error keeps the usual rule, and output within the limit,
  exactly `limit` bytes among it, is a run to its end (`RunResult::Ran`). It is a fact about a process with no policy in it: it is
  how a filter given an empty text, which prints every candidate, still
  answers ([concurrency.md](concurrency.md), "Prompts": sources a command
  filters). The contract holds it to one more property, `RUN_HEAD`: a
  child that never stops writing, fed a few bytes, under a limit of 4,
  answers `0123` as cut, and its child and grandchild end; a group kill
  that ends only the child, and a wait that does not reap, each fail it.
  An id in use is refused. Cancelling kills the
  group of a running child, drops its result and never completes it.
  Shutdown refuses every later start (as shut down, completed at once),
  cancels every run, kills every group and blocks until every child is
  reaped; it does not wait for a stream to close. **A flush**
  (`Service::flush`, deterministic-test-concurrency phase 1) is a wait of
  the caller's, completed once every run started before it has ended (its
  result kept, or cancelled and its child reaped), every open asked before
  it has been answered, and every streaming child cancelled or forgotten
  before it has been reaped; with nothing to wait for it is completed at
  once. Each run's thread, after its own completion, and each streaming
  child's waiter, once its child is reaped, removes its ticket from every
  flush and completes those it was the last thing for, in the order they
  were asked; shutdown completes the rest once every child is reaped. A
  run's result is kept, and an open answered, before its completion is
  queued, so each holds a ticket until then and a flush waits on the
  tickets: a flush asked in between is still completed after it. **A
  live streaming child, its pending read and a write held by a full pipe
  are not covered**: they wait on the child, not on the service, and a
  flush that waited for them would never be completed. The contract holds
  it to two more properties, `FLUSH` (a run held until it is cancelled
  keeps a flush from completing; cancelled, the flush's is the next
  completion and the child has been reaped by then; a wait that does not
  reap fails it) and `FLUSH_LIVE_STREAM` (a flush completes beside a live
  streaming child whose read is pending). The contract's own properties
  wait on a flush, never on the pending count, to know a cancelled run is
  over.
- **The adapter** (`editor-process-std`) starts a child with
  `std::process` and `process_group(0)`. Its wait sees the exit with
  `waitid(P_PID, pid, WEXITED | WNOWAIT)`, which leaves the child unreaped,
  so its pid, which is also its group's id, cannot be given to another
  process; it then kills the group and only then reaps. A kill takes the
  same lock and does nothing once the child is reaped. So no signal ever
  reaches a group id that may have been reused, and no straggler of a group
  outlives its run. The system calls are rustix's, pinned exactly; std has
  neither a wait that does not reap nor a group kill.
- **Streams and input.** A streaming child (`Service::open`) is opened
  with its input (closed or a pipe), how each output stream is framed and
  its bound; then each read, write and close is a wait of the caller's,
  completed once, whose reply is taken once (`Service::take_stream`).
  Framing is plain data (`editor_service::frame`, which `editor-process`
  re-exports as `editor_process::frame`): lines split on `\n`, a line
  without its `\n` and keeping a `\r`, the bytes after the last `\n` a last
  line at the stream's end; raw bytes, whose deliveries end to end are the
  stream; or `Content-Length` messages, whole bodies without their headers
  ("Handing a streaming child to a package's crate, as built", below). **Coalescing is the reads being pulls**: a read is
  completed once, by the first reader that makes something deliverable,
  never once a chunk, and its delivery is drained when it is taken, so it
  holds everything read up to then. A completion-queue turn ends one wait,
  so a job gets at most one delivery a turn however fast its child writes,
  and nothing of a child's output reaches the editor queue. **The bound**
  is how many bytes of each stream may have been read and not taken, a line
  in progress among them. It counts each stream on its own: a bound across
  both streams, with room reserved before each read, would let a reader
  blocked on a stream the child does not write hold the other stream's room
  for ever, and the child would never be read again. A reader reads at most
  the room left, and at none it parks, so the pipe fills and the child
  blocks in `write(2)`: it is **held** until a take makes room. Nothing is
  dropped and no delivery says so. A line longer than the bound, its line
  feed counted, ends the child as `LineTooLong`, its group killed. A partial
  line that fills the bound exactly is judged by one more byte, read
  outside the bound: if it comes the line is too long, and if the stream
  ends there the line is its last, delivered whole. A `Content-Length`
  message longer than the bound, its header counted, ends the child as
  `MessageTooLong` as soon as its length is parsed, with no probe and its
  body unread; a malformed header, or a stream that ends inside a message,
  ends it as `Failed`. The last delivery carries the
  exit, once both streams have ended and the child is reaped, and the child
  is then forgotten. A write is handed to a writer thread, which writes
  every byte and then completes; a child that closed its input, or ended,
  is `InputClosed`, and one with no input or a closed one is refused at
  once; nothing is buffered beyond the pipe. **`SIGPIPE`**: the library runs
  inside Lean's executable, where std's start-up never ignores the signal,
  so a write to a closed pipe must not raise it. The adapter sets
  `F_SETNOSIGPIPE` on the write end on macOS, and on Linux blocks `SIGPIPE`
  in the writing thread around the write, takes the pending signal and
  restores the mask (`libc`, pinned exactly: rustix has neither call outside
  its unstable `runtime` feature); `tests/sigpipe.rs`, with the signal at
  its default, pins it. **Threads**: four for each streaming child, its
  waiter, two readers and a writer when its input is piped; the editor's
  expected streaming children are a handful (agent sessions, language
  servers). Cancel kills the group, wakes parked readers and the writer,
  and drops the child's waits uncompleted, its pending read with them in
  the same step, so no reader or waiter completes it after the kill;
  shutdown cancels every child as
  it does every run. The contract holds the port's input to three more
  properties (a write reaches `/bin/cat` byte for byte, a write to an input
  the child closed is `InputClosed`, a child spawned with no input has
  none to take) and the service to nine more, 26 then, 28 with the fed
  run's two, on real
  processes: lines as they are written and a line written echoed back,
  bytes, 20,000 lines in order at a bound of 256, one completion for
  10,000 lines, a child held at a bound of 4,096 that cannot finish until
  it is read, a line too long, a last line exactly the bound long delivered
  whole and one a byte longer, its line feed counted, too long, a cancel of a held child and its
  grandchild, and shutdown of a held child and one waiting for input. In Lean, `Process.start`, `read`, `write`,
  `writeLine` and `closeInput` are requests of the job port; a child is
  named for the job that started it, and the runner cancels every child a
  job still holds when the job ends.
- **The kill signal** is `SIGKILL`, with no `SIGTERM` and no grace period,
  so neither a cancel nor shutdown can hang on a child that ignores a
  polite signal.
- **Across the boundary**, `editor-ffi`'s `processes.rs` holds the
  process's one service, over the real adapter, behind thirteen C functions:
  a run (the command as words and one string, as a list of strings
  crosses), a fed run (the same, and the bytes of its input), a run that
  keeps its head (the same as a fed run; a cut run's result is status 9,
  which runs and streams leave unused, with no words and both streams in
  the buffers), a take (a status, words, a detail and both streams), a cancel,
  a shutdown and a readout of what is pending; and for a streaming child an
  open (a run's words after its input and its two framings, with the bound
  for the limit), a read, a write, a close of its input, a take of a wait's
  reply (the same record as a run's result, a delivery's two streams in its
  buffers) and a readout of whether it is held, for tests. A delivery's
  frames cross as words, each stream's framing (0 lines, 1 bytes, 2
  messages) and for lines and messages their count and lengths, and its end
  as a code (0 not yet, 1 exited, 2 a line too long, 3 failed, 4 a message
  too long); framing 2 and code 4 are `Content-Length`'s, which an open's
  words do not spell yet, so no child Lean opens produces them. One more C
  function, `editor_ffi_library_start`, which the entry point calls before
  Lean runs, provides the service as `editor-service`'s stream source
  ("Handing a streaming child to a package's crate, as built", below). In Lean a run is
  a request of the job port (`lean/Editor/Process.lean`, `Process.run`),
  with a pure model that scripts commands, and a run that keeps its head
  is `ProcessRequest.runHead`, answered `Process.Head.whole` or
  `Process.Head.cut`; cancelling a job withdraws its
  wait, which cancels the run in the library and so kills the child. A run
  with a time limit (`Process.runWithin`) is a run here: Lean's adapter
  arms an alarm on the timer service and cancels the run when the alarm
  comes first, so the library has no deadline of its own. Before a child
  starts, Lean looks up the environment of its directory, a run of
  `mise env --json` there with such a limit, and sets its variables under
  the command's own ([concurrency.md](concurrency.md), "A child's
  environment, as built"). The headless and window mains call the shutdown
  before they quit the queues.

### Handing a streaming child to a package's crate, as built

Built by the acp-agents roadmap's phase 2 (its transport design "C"), from
the ACP design spike of 2026-11-23; it is no longer a proposal. The spike's
code, marked `SPIKE`, never landed: what is described here was built again
test-first.

An ACP client (and later an LSP client) is a package's crate that speaks
JSON-RPC to a child. The core's process service keeps owning the child:
its spawn, environment, group, kill, reap and shutdown, as above. A Lean job
opens it as a streaming child as it does today (`Process.start`), and then
hands its number to the package's binding, whose crate **takes the child
over**: from then on the crate's own thread pulls the child's framed
streams and writes its input, Rust to Rust, and the job reads it no more.
Rust still never calls Lean: the crate reports through its own service's
completions, which Lean pulls.

**The pieces.** A package's crate may depend only on `editor-service`
(until `package-native-libraries` phase 5; since then a package's library
reaches this port through the package runtime's `take_over`)
([packages.md](packages.md), "The service conventions as a crate of their
own"), so the hand-off is a port there, in the editor's terms, and the crate
that holds the process's one process service provides it:

| Piece | Where | What |
|---|---|---|
| `frame` | `editor-service` | The framing of a child's streams (`Framing`, `Frames`, `Framer`, `Outbox`) and `Stream`, moved here from `editor-process`, which depends on `editor-service` and re-exports both (`editor_process::frame`, `editor_process::Stream`). Plain data, no thread and no port, so it widens every package crate's reach by values alone. A delivery's frames are one type on both sides |
| `stream::StreamSource` | `editor-service` | The port: `take_over(child) -> Result<Box<dyn ChildStreams>, Refused>`, refused as `NoService`, `NoSuchChild`, `ReadPending` or `Taken` |
| `stream::ChildStreams` | `editor-service` | A child taken over: `pull()`, which blocks until a `Delivery` (both streams' frames and, in the last, how it `Ended`: exited, signalled, a line or a message too long, failed), the end or a cancel (`Pulled::Cancelled`); and `write(bytes)`, which blocks until they are in the pipe, or answers `InputClosed` with the platform's words. A consumer writes from one thread at a time: overlapping writes are each written whole, but which caller gets which reply is unspecified |
| `stream::provide`, `stream::take_over` | `editor-service` | One process-wide `OnceLock` holding the source, provided once, and the call a package's crate makes. The editor links from one Rust archive, so there is one static |
| `stream::fake::FakeSource` | `editor-service` | The port's published fake: a model a test steps on its own thread, framed and bounded by the real `Outbox`, so its rules cannot drift from the service's. A child writes into model pipes, of which only the bound's room enters the outbox; it answers a line of its input, ends, or is cancelled. A pull never blocks: with nothing to give it panics, saying to step the fake first. It records take-overs and writes |
| `stream::contract::check` | `editor-service` | The port's contract, over a `Ground` that opens a child for each of the contract's `Scenario`s, makes a job's read pending and withdraws it, and waits for a reader's park |
| `Service::hand_off(child)`, `Handed` | `editor-process` (`service/hand_off.rs`) | The hand-off on the service; `Service` is the port's `StreamSource` itself and `Handed` its `ChildStreams`, through `End::ended`, so the provider converts nothing |
| `stream_contract::ServiceGround` | `editor-process` | The contract's ground over a `Service`: each scenario a `/bin/sh -c` script, or the `FakeProcesses` script that mimics it (`stream_contract::scripts`) |
| `editor_ffi_library_start` | `editor-ffi` (`processes.rs`, `processes/streams.rs`) | A C function, idempotent, that provides a zero-sized source forwarding each take-over to the one `PROCESSES` static. `editor_entry` (`lean/ffi/glue.c`) calls it first, before the main-thread service is opened and before Lean runs. Providing it forces no `LazyLock`, so nothing starts at load, and a take-over never depends on an open having come first |

**The rules it keeps.**

- **The bound and "held, never dropped".** A consumer's pull is the job's
  read and take in one call: it drains the outbox, which makes room and
  wakes a parked reader. A consumer that does not pull holds the child in
  `write(2)` exactly as a job that does not read does. Nothing is dropped,
  and the bound still counts each stream on its own. The bound is the
  opener's choice; an agent's is in megabytes ("The bound for ACP",
  below).
- **One reader.** A child with a read of the job's pending is refused
  (`ReadPending`): the job takes or cancels its read first. Once handed,
  the job's read, write and close of it are refused, as for an unknown
  child, and a second take-over is refused (`Taken`). A child the service
  does not hold live, unknown, cancelled or forgotten after its last
  delivery, is `NoSuchChild`. The refusals are checked under the state
  lock and then the stream's, as a read is.
- **A job's write in flight at the hand-off** completes to the job, and the
  consumer's write follows it: the write slot records who asked
  (`Asker::Job(wait)` or `Asker::Consumer`), the writer answers each reply
  to its asker, and a consumer's write waits on `changed` for a slot a
  job's write still holds. The spike's writer sent every reply to the
  consumer once the child was handed, which stranded that job's wait.
- **Cancel, kill and shutdown** reach a consumer mid-pull: they abandon the
  child's stream under its lock and notify `changed`, the condvar the
  consumer waits on, so its pull answers `Cancelled`. **The waiter
  notifies `changed` once it has recorded the exit**, so a consumer waiting
  for the end wakes; that was the one change the spike found was needed.
- **A child that exits before the hand-off** keeps its frames and its exit
  in its stream state until its last delivery is taken (`Streamed::end`,
  `Service::forget`), so a take-over after the exit still delivers every
  line and the exit, in one pull.
- **Who owns the session.** The child stays named for the job that opened
  it, and the runner cancels every child a job holds when the job ends, so
  the opening job lives as long as the session: a session is one
  long-lived job, which opens the child, hands it to the crate and waits
  on the crate's events through a package's service
  ([packages.md](packages.md), "Behind a port, so it stays replaceable").
  Moving the child out of the job's set is not built. Cancelling the job
  withdraws its package wait at the crate first, then ends the child, and
  the crate's consumer, blocked in a pull, is answered `Cancelled`, its
  last event; the crate posts no completion for a request withdrawn first
  ([concurrency.md](concurrency.md), "A long-lived job owns a handed-over
  child"). The fixture `echo` shows it: its job `echo-attach` and the
  forced orders of its cancel on the stepped host
  (`EchoTest/Linked/Echo/Packages.lean`), and the crate's lib test of an
  attach cancelled while its consumer is held in a pull.
- **Threads.** Each child keeps its waiter, two readers and its writer,
  and the consumer adds its own. For ACP, as built (acp-agents phase 4),
  `acp-service`'s real connector (`Threads<S>`, `packages/acp/rust/src/lib.rs`),
  which since `package-native-libraries` phase 5 takes the child over
  through the stream source it holds, the package runtime
  (`Threads<Runtime>`), starts two a session: `acp-session`, which runs the protocol's connection
  (the SDK's future under a plain `futures::executor::block_on`, no
  runtime) and writes every line the SDK sends straight through
  `ChildStreams::write`, so the child has one writer; and `acp-pull`, which
  pulls the child's standard output into the connection's lines and drops
  its standard error (`src/stream.rs`). Both end once the child has; those
  that have ended are joined at the next session's start. Six or so a
  session, for a handful of sessions. The crate's tests run the same
  session future on a `LocalPool` the test steps on its own thread.

**`Content-Length` framing**, which an LSP client needs, is the third
`Framing` beside `Lines` and `Bytes`, in `editor_service::frame`:

- A framer with two states, header and body. The header is ASCII lines
  ending `\r\n` up to an empty line; `Content-Length: <decimal>` is
  required, once, its name matched without regard to case; `Content-Type`
  is allowed and ignored. Any other header, a length twice or missing, one
  that is not a decimal number, a bare `\n`, a line with no colon or a byte
  that is not ASCII is malformed. A take gives whole bodies,
  `Frames::Messages(Vec<Vec<u8>>)`, without their headers. The framer
  keeps a parse cursor, so a push parses only what it adds, and a body is
  never scanned.
- The bound counts the header in progress, the body in progress and the
  headers of messages not yet taken. A message's size is known once its
  length is parsed, so one whose header and length pass the bound is
  `MessageTooLong` at once, beside `LineTooLong`, with no probe byte and no
  further read, its body unread; so is a header with no end that fills the
  bound. `Outbox::fault` says which (`Fault::LineFillsBound`, today's
  partial line at the bound, judged by one byte more as before;
  `Fault::MessageTooLong`; `Fault::Malformed`). The service ends the child
  on `MessageTooLong` as `End::MessageTooLong`, and on a malformed header,
  or a stream that ends inside a message, as `End::Failed` with the
  framer's words, its group killed either way.
- Writes stay bytes: the consumer frames what it writes (an ACP line with
  its `\n`, an LSP header and body), and the writer writes every byte.
  Nothing in the service parses JSON.
- **Reachable from Rust alone, for now.** `Service::open` takes it for
  either stream, and the port, its fake and its contract cover it; the
  open's words across the C boundary (framing 0 lines, 1 bytes) and Lean's
  `Process.Framing` do not spell it yet. A delivery's messages would cross
  as framing word 2 and a message too long as end code 4 ("Across the
  boundary", above), which no child Lean opens produces yet.

**What pins it.**

- **The contract**, `editor_service::stream::contract::check`, twelve
  properties over children of nine scenarios: `TAKEN_LINES` (lines read
  and a line written after a take-over, then the exit), `TAKEN_HELD`
  (2,000 lines at a bound of 64: the reader parks while nothing pulls,
  then every line arrives in order, none over the bound), `TAKEN_MEGABYTES`
  (a line of three mebibytes under a bound of four, whole), the refusals
  `REFUSED_TAKEN`, `REFUSED_READ_PENDING` and `REFUSED_NO_SUCH_CHILD`, the
  write's refusals as input closed `REFUSED_WRITE_NO_INPUT` (a child with
  no input) and `REFUSED_WRITE_ENDED` (after the last delivery was
  pulled), and
  `MESSAGES`, `MESSAGE_AT_BOUND`, `MESSAGE_TOO_LONG` (a header announcing
  a body past the bound, the body never written, ends the child at once)
  and `MESSAGE_MALFORMED`. Each pull and write runs on a thread of the
  check's, waited for up to the ground's hang guard, so a hang fails its
  property and a fake's panic fails it too. It passes on `FakeSource`, and
  bites on six flawed fakes, each named by the property it breaks (output
  past the bound dropped, a second take-over allowed, a pending read
  ignored, a message split where a pull finds it, a too-long body read
  before the refusal, a write to a closed input answered as written). `editor-process`'s `tests/stream_contract.rs` runs
  it on `Service<FakeProcesses>` and `editor-process-std`'s on
  `Service<StdProcesses>`, real children in a temporary directory.
- **The orderings, forced**, in `editor-process`'s `service/hand_off.rs`,
  on the real service over the port's fake, each held at its step by a
  latch: `a_cancel_while_the_consumer_is_blocked_in_a_pull_answers_cancelled`
  and `a_shutdown_while_the_consumer_is_blocked_in_a_pull_answers_cancelled`
  (a test hook, `before_pull_wait`, runs under the stream's lock just
  before the consumer's wait, so the abandon comes only once it is in it;
  the child's streams held open by a process outside its group and its
  reap held, so nothing but the abandon wakes it),
  `a_child_that_exits_before_its_hand_off_still_delivers_its_lines_and_its_exit`
  (the hook `exit_recorded`, then both readers let go, then the hand-off),
  and `the_waiter_wakes_a_consumer_waiting_for_the_end` (the reap held while
  the consumer waits). Each was seen to bite by hand on 2026-11-25: with
  the notify taken out of the abandon, the first two fail as hangs; with
  the waiter's taken out, the last does; and with the spike's diverted
  write, `a_jobs_write_in_flight_at_the_hand_off_completes_to_the_job_and_the_consumers_follows_it`
  fails waiting for the job's completion.
- **`Content-Length`**: the framer's unit tests in `editor_service::frame`
  (whole messages across every split, an empty body, `Content-Type`
  ignored, each malformed header, a stream ended inside a message, the
  bound with the header counted, four mebibytes pushed a byte at a time
  parsed once); and on `FakeProcesses`
  `a_message_past_the_bound_kills_the_group_at_its_header_with_no_byte_of_its_body_read`,
  whose record shows the header's bytes read while the pipe held body.
- **The wiring.** `editor-ffi`'s `tests/stream_source.rs`, on real
  processes: once the library has started, a take-over is answered by the
  service; a child opened through the C function is taken over through
  `editor_service::stream::take_over`, read and written to and its exit
  seen; and the job's read of it is refused. In the fixture package `echo`,
  the linked test's wiring module `EchoTest/Linked/Echo/Real/Attach.lean`
  opens a streaming child through the linked kit's real process port, with
  a bound of four mebibytes, hands its number to `Echo.Real.attach`, and
  echo's library (`rust/src/attach.rs`), a library of its own loaded when
  the editor starts ([packages.md](packages.md), "A library loaded when the
  editor runs, as built"), takes it over through the package runtime
  (`take_over`, then `child_pull`, `child_write` and `child_release`, each
  the core's over `editor_service::stream`), reads `one`, `ping-me`,
  `got pong` (writing `pong` back) and `three` and sees the exit 2; a
  second child, blocked in a pull, is cancelled through the job port and
  the library sees `<cancelled>`; and a child whose last delivery was
  pulled is not taken over again. So the runtime reaches the source
  `editor-ffi` provided, from a library that carries no copy of
  `editor-service`'s statics. That echo's crate depends on nothing of the
  editor's is held by `deny.toml`'s entry for `editor-service`, which
  leaves it out of its wrappers (`mise run deny`; cargo-deny counts its
  dev-dependencies too). acp's library takes a child over the same way,
  through the runtime (`Threads<Runtime>`); since `package-native-libraries`
  phase 5 no package crate is linked into the archive.

**The bound for ACP.** Claude Code's adapter sent a 27,490-byte line on its
first prompt (its list of commands), and a tool call's update carries the
edited file whole, in its diff and again in `_meta`
([agent-hosting.md](agent-hosting.md), "The ACP spike"), so a line is
about three times the largest file it edits. A line longer than the bound
kills the agent (`LineTooLong`). Decided (acp-agents phase 4): the bound is
sixteen mebibytes a stream (`AgentsApi.lineBound`), which takes files of
about 5 MB, and an over-long line ends the session (`ended lineTooLong`),
never is skipped: skipping a JSON-RPC line could drop a response and
leave a request waiting for ever, while ending is safe and seen
([agent-hosting.md](agent-hosting.md), "The ACP client, as built").

## Files and watching

| Service | Where | Notes |
|---|---|---|
| **Load a file into a rope, save a rope** | Rust | Bytes go straight between disk and the rope. Saves are atomic (temporary file, then rename). Invalid bytes and line endings are preserved. |
| **Small reads and writes, stat, list, rename, remove** | Lean | Lean's own file functions, called from jobs on a dedicated thread, behind the editor's file interface. |
| **Watching** | Rust | Watch a file, a directory's entries or a directory's tree; changes coalesced over a fixed window, one a path, and delivered a read at a time. Built: "Watching, as built", below. |

As built, loading and saving are whole: the port, its adapter, the logic and
the service behind the completion queue, here, and in Lean the bindings and
the job interface's file requests, which a job awaits
([lean-runtime.md](lean-runtime.md), "Interfaces and models";
[concurrency.md](concurrency.md), "Sharing state", says how a job names a
snapshot). Lean's own interface for small reads and writes is not built;
watching is ("Watching, as built", below). The editor's commands over
loading and saving are built
(`packages/files/Files.lean`, the command loop's phase 9;
[concurrency.md](concurrency.md), "Getting results back"): the open command
loads under a limit of 1 GiB, which is the editor's policy and a round
number with no measurement behind it, and the save command expects the
stamp the buffer holds, or whatever is there when it is forced. Nothing
reloads a buffer whose file changed on disk, and nothing follows a buffer's
file with a watch yet: a change is found when a save is asked for.

- **The port.** `editor_text::fs::Fs`, defined by `editor-text` in its own
  terms, with ten methods. `stat` says what is at a path, following links,
  and is none for nothing; it is the one way time and metadata reach the
  core, which reads no clock. `read` gives a file's bytes whole. `write`
  makes a *new* file from pieces, with exactly the permissions given
  whatever the process's mask, or the platform's default, has it on disk
  before it returns, and is refused where anything is, a link included.
  `rename` puts a file in place of another in one step. `remove` removes a
  file. `resolve` follows every link in a path, and is refused as not found
  for nothing and for a link that names nothing alike. `read_link` gives
  the path a link holds, as the link holds it and following nothing, and
  none for what is no link: it is how the core tells a link to nothing from
  nothing. `list` (completion's phase 6) gives what a directory holds, one
  entry per name, `.` and `..` left out, each with its kind, links
  followed, a link to nothing as other, in no particular order; nothing
  there is refused as not found, and what is not a directory as not a file,
  the port's kind for "not what was asked for", which every operation
  already used for a path through something that is not a directory, so
  no kind was added and no existing refusal changed. `make_directory`
  (navigation-and-windows phase 5, for a workspace's working sets kept
  under the state directory, which need not be there) makes a directory
  and every directory on the way to it; one already there is no error, and
  a file at the path or on the way is refused as not a file. `append`
  (session-restore phase 1, for the journal of unsaved text the editor
  adds to as it goes) adds
  pieces to the end of a file, and makes the file with the platform's
  default permissions where nothing is; a directory at the path, or a file
  on the way to it, is refused as not a file, and a directory on the way
  that is not there as not found, so no kind was added. **An append is not
  synced**: the bytes are handed to the system before it returns, and a
  crash may lose the last of them, which a record added to often can
  bear and a save cannot. An error is a kind
  the core decides on (not found, denied, exists, not a file, other) and
  the platform's words.
- **The fake.** `editor_text::fs::FakeFs`, published and not test-only: a
  file system in memory whose time only a test moves, which records every
  call, fails when a test says so, and runs a test's closure between two
  calls.
- **The contract and its ground.** `editor_text::fs::contract::check` holds
  any `Fs` to the port's rules, in order, in one directory, and names the
  first rule broken. The check needs things done that the port has no
  method for (a link made, a modification time and permissions set and
  read), so its caller supplies them as a `Ground`: the truth the port's
  answers are compared with. An implementation whose `write` and `stat`
  agree on permissions the file does not have is refused. What the port
  says of a link to nothing is among the rules: its stat is none, resolving
  it is refused as not found, and it is read as the path it holds. So is
  what a save's stamp rests on: a renamed file keeps its modification time
  and its size. So is a listing: a directory holding a file, a directory, a
  link to a file and a link to nothing lists each once, with the kinds
  file, directory, file and other, and nothing and a file are refused. So
  is a directory made: two levels made at once, each a directory, made
  again with no error and written in, and refused where a file is and
  under one. So is an append: where nothing is it makes a file of the
  pieces, a second adds at the end, and a directory, a path under a file
  and a directory that is not there are refused. The check is shown to
  bite by twenty-five fakes written to break one rule each.
- **The adapter.** `editor-fs-std`, a crate of its own: `StdFs` over
  `std::fs`, Unix only, made by the one constructor `StdFs::system()`. A
  write is `create_new` with the permissions set on the open file, then
  synced; an append opens with `append` and `create` and is not synced; a
  rename syncs the directory and ignores a failure of that. It is
  held to the contract by its own test, in a temporary directory the test
  makes, against a ground that asks the system directly; its other test is
  how it names the system's errors. It runs nothing of the logic.
- **Load** (`editor_text::file::load`). A path that is not absolute is
  refused before the file system is asked. The file is statted before it is
  read, so what is not a file, or is longer than the caller's limit, is
  never opened; it is read whole, once. A file with a NUL byte among its
  first 8,000 bytes is refused as binary, which is git's rule; a file that
  is not UTF-8 loads, its invalid bytes kept. Line endings are counted
  (line feeds alone, and line feeds after a carriage return) and none is
  changed. The stamp returned is the modification time and size from the
  stat made before the read.
- **Save** (`editor_text::file::save`) saves a snapshot, a rope piece at a
  time, in eight steps: refuse a path that is not absolute; resolve it, so a
  link's file is the one replaced, and where it resolves to nothing read
  the link it holds, so the file a link to nothing names is the one made
  and the link stays; stat the target, refuse what is not a
  file, check it against what the caller expects, and keep its permissions;
  write a temporary file beside it, `.<name>.<n>.tmp`, passing over a name
  that is taken, for at most 32 names; stop if the caller cancelled; stat
  the temporary file, for the stamp returned; stat the target and check
  again; rename. A failure from the write on removes the temporary file and
  leaves the target as it was, so a crash never leaves a half-written file.
  **The stamp returned is the temporary file's, taken before the rename**,
  which keeps a file's modification time and size (a rule of the contract).
  It is not read from the target afterwards: a program that wrote the file
  just after the rename would have its stamp returned as the save's, and
  the next save would overwrite its file unnoticed. The rename is the last
  thing asked of the file system, so a save that is refused has not
  replaced the file. **Kept**: the nine permission
  bits, and every byte. **Not kept**, since the file is replaced by a
  rename: other hard links, a foreign owner, the special mode bits, extended
  attributes. A directory that cannot be written refuses the save; there is
  no fallback to writing in place. **A link to nothing** is followed to the
  file it names, which is made in its own directory, with the link left as
  it was: a path that is not absolute is read from the link's directory,
  and links to nothing are followed one after another for at most eight,
  after which the save is refused as not a file.
- **Noticing a change on disk.** A stamp is compared for equality, not for
  "newer". A save is told what to expect (the stamp a load or a save
  returned, no file, or whatever, which is the override), and one that
  finds something else is refused with what is there now and writes nothing
  over the file. It is checked when a save is asked for and at no other
  time. A change that keeps the size inside one tick of the file system's
  clock is not seen; a test pins that.
- **A listing** (`editor_text::file::list`, completion's phase 6): a path
  that is not absolute is refused before the file system is asked; the
  port's refusals become the listing's own (not found, not a directory),
  and the entries are sorted by the bytes of their names, so the answer is
  deterministic and the Lean model answers the same. `std::fs::read_dir`
  is the library, behind the port, with `std::fs::metadata` of each entry
  for its kind.
- **A directory made** (`editor_text::file::make_directory`,
  navigation-and-windows phase 5): a path that is not absolute is refused
  before the file system is asked; the port's not a file becomes not a
  directory, and anything else is handed on. `std::fs::create_dir_all` is
  the library, behind the port; where a file is at the path it says the
  path exists, which the adapter answers as not a file. A save makes no
  directory: a caller that saves where one may be missing makes it first.
- **A stamp alone** (`editor_text::file::stamp`): the stamp of the file at
  a path, or none when nothing is there, from one stat, with nothing read;
  a path that is not absolute is refused before the file system is asked,
  and what is not a file is refused as not a file. It is how a caller tells
  whether a file changed without loading it: Lean's lookup of a child's
  environment keeps a directory's entry by the stamps of mise's config
  files.
- **An append and a remove** (`editor_text::file::append` and
  `editor_text::file::remove`, session-restore phase 1): one call of the
  port each,
  a path that is not absolute refused before the file system is asked. An
  append makes the file where nothing is and makes no directory: the
  directory not being there is not found, and a directory at the path, or
  a file on the way, not a file. **A remove of nothing is no error**: what
  was asked is so already; a directory is refused as not a file.
- **The service** (`editor-ffi`, `src/files.rs`), in the timer service's
  shape: a load, a save, a stamp, a listing, a directory made, an append or
  a remove is started with the caller's id and
  returns at once; **one thread works the requests in the order they were started**,
  so two saves of one file land in order; one completion is queued; the
  result is then taken once by its id, as a status, a snapshot handle for a
  load, words and a detail string. Cancelling a request that waits means it
  is never worked; a save being worked reads the flag before it replaces
  the file. The statuses: done, not absolute, not found, not a file,
  denied, binary, too large, changed, no temporary name, failed, not a
  directory, listed. A stamp request's result is done with four words:
  present or not, then the stamp. A listing's is listed: the count, then
  each entry's kind (0 file, 1 directory, 2 other) and the byte length of
  its name, the names joined as the detail; a name that is not UTF-8 is
  left out, since Lean cannot name such a file. A directory made is done
  with no words, and one refused is not absolute, not a directory, denied
  or failed (`editor_ffi_files_make_directory`, bound as
  `Ffi.filesMakeDirectory`). An append and a remove are done with no words
  (`editor_ffi_files_append`, `editor_ffi_files_remove`), and one refused
  is not absolute, not found, not a file, denied or failed. **A flush is a
  barrier** (`editor_ffi_files_flush`, deterministic-test-concurrency
  phase 1): a marker on the queue under the caller's id, completed when the
  worker reaches it, so every request started before it, observed or
  unobserved, has been worked and its completion queued ahead of the
  flush's. It keeps no result, its id is in use while it waits, and a
  cancel withdraws it. It is what a host or a test waits on to know the
  queue has drained, in place of polling the count. **A hold parks the
  worker, for tests** (`editor_ffi_files_hold`): a request that, once the
  worker reaches it, is completed and then holds the worker, working
  nothing behind it, until its id is cancelled. It is the in-process held
  worker the Lean contract checks queue work behind, with no file, no
  named pipe and no other process; the editor never asks for one.
- **Unobserved requests** (session-restore phase 1): an append, a remove, and a
  save that expects whatever is there may be asked with no id
  (`editor_ffi_files_append_unobserved`,
  `editor_ffi_files_remove_unobserved`,
  `editor_ffi_files_save_unobserved`), for what the editor writes as it
  goes with no job waiting on each write. One runs **in order with the
  observed requests**, on the one thread, so a record appended after a save
  lands after it; it is never completed and keeps no result, and it cannot
  be cancelled, having no id. **The failures readout**: one that fails is
  kept as its path and why, in the refusal's own words, oldest first, and
  each is taken once (`editor_ffi_files_failure`, a record of two buffers
  the caller hands back as it does a result's detail). The count of
  pending requests includes an unobserved one while it waits or is worked,
  so it falls to 0 once the queue has drained; a failure kept is not
  counted. The count is a readout; **the way to wait for unobserved
  requests is a flush**, which no caller has to poll. Their one caller is
  the host's session journal, a deliberate exception kept for its cost on
  the editor thread ([concurrency.md](concurrency.md), "The session
  journal"); everything else that needs one request's reply uses an
  observed request with an id, through a handle
  (`Job.Services.fileWorked`).
- **How the tests are kept off the disk.** `editor-text`'s tests, and the
  service's unit tests, run on the fake. That is held by the gate, not by
  review: the root `clippy.toml` lists `std::fs`, the disk-asking methods
  of `Path`, the working and temporary directory, `Command::new`, the
  clocks and the adapter's constructor as disallowed in every crate, the
  adapter and the one static that makes it marked, and `deny.toml` keeps `tempfile` and
  the adapter out of `editor-text`. Two places are marked as exceptions,
  both in `editor-ffi`: the process's file service, and the one wiring test
  over real files, which asserts bytes in and bytes out. What the lists
  cannot hold is said in their headers.
- **From Lean**, a load and a save are requests of the job interface, and
  the service is the job runner's file port
  ([lean-runtime.md](lean-runtime.md)). The same round trip, load and save
  without edits, runs there three ways: on a pure model of files, on the
  runner over a fake of the port, and on the runner over this service, on
  real files in a temporary directory, with a fixture of each kind (LF,
  CRLF, and bytes that are not UTF-8). A path crosses as the bytes of a Lean
  string, so a file whose name is not UTF-8 cannot be named from Lean yet.

### Watching, as built

Built by the process service's phase 3. A job asks to be told when a file,
a directory's entries or a directory's whole tree changes on disk, and
waits for each delivery as it waits for a stream read. The port, its fake,
its contract, the coalescing rule and the service are `crates/editor-watch`,
whose one dependency is `editor-wait`, the typed time bounds; the adapter is `crates/editor-watch-notify`; the
C functions are `crates/editor-ffi/src/watches.rs`.

- **The port** is `editor_watch::Watch`. `watch(directory, depth, sink)`
  registers a directory to a depth (`Entries`, what is directly inside it;
  `Tree`, everything under it) and tells each change to the sink as a
  `Notice`: a path and a kind, one of created, written, renamed, removed
  and missed. Dropping the registration ends it. A refusal is a kind the
  editor decides on (not absolute, not found, not a directory, denied, the
  system's limit on watches, shut down, failed) and the platform's words.
  The port watches directories only; a watch on a file is the service's.
  Its rules:
  - `watch` is refused, as a value, for a directory that is not there, for
    something that is not a directory, and for one the system will not let
    it watch. A path that is not absolute, or has a `..` component, is the
    core's to refuse (`refusal_before_watch`), so no adapter is asked one.
  - **A registration is live when `watch` returns**: a change made after
    that is noticed.
  - It notices each entry created, written, renamed (under its old path
    and its new one) or removed inside the directory, or anywhere under it
    for `Tree`, subdirectories made after `watch` returned among them. It
    may notice more than it covers (FSEvents is recursive underneath, and
    an earlier change can show up in a flag), never less.
  - A notice names its path under the directory as the caller spelled it.
  - Registrations are independent: two of one directory each notice its
    changes, and dropping one leaves the other whole.
  - **After a registration's drop returns, its sink is never called
    again.**
  - One registration's notices reach its sink in the order the platform
    reported them.
  - An overflow is one `Missed` notice naming the directory. A change of
    metadata alone, and a read, are not noticed.
- **The coalescing rule is pure** (`editor_watch::batch`). Time reaches it
  as a number of milliseconds the caller passes in. A batch holds one
  change a path, in the order of each path's first notice, and a change is
  a path and a *set* of kinds (`Kinds`, the bits created 1, written 2,
  renamed 4, removed 8, missed 16), because FSEvents gives no order inside
  a record it coalesced and can carry an earlier change's flag. **The
  window is fixed from the batch's first notice**, not a trailing
  debounce: the batch is deliverable once the window has passed since its
  first notice, however many notices follow, so a file written without
  pause is delivered once a window and never held back. **The bound** is
  how many distinct paths a batch may hold. A notice for a new path past
  it collapses the batch to one change, missed, on the watch's own path,
  and the batch stays collapsed until it is taken; a `Missed` notice, the
  platform's own overflow, collapses it the same way. This is the
  backpressure answer for watches: a recursive watch during a `git
  checkout` can make hundreds of thousands of notices, and the job is told
  one change. A take leaves the batch empty and not collapsed.
- **The clock** is a trait of the crate's own (`editor_watch::clock::Clock`),
  because the crate cannot depend on `editor-ffi`, where the job clock is;
  `ManualClock` is published for tests. The service's timer thread parks
  until the earliest deadline of a batch with a read pending, or until
  `Service::wake`. A test advances the manual clock and wakes the service,
  then waits for the completion with a deadline: no test sleeps for a fixed
  time. The root `clippy.toml` refuses `std::fs`, the `Path` methods
  that ask the disk, the machine's clocks and the adapter's constructor,
  so its tests run on the fake and the manual clock.
- **The fake** (`editor_watch::fake::FakeWatch`) is a file system in memory
  and the registrations on it. `notice` tells a notice, on the calling
  thread, to every live registration that covers its path. Its ground
  (`FakeGround`) writes, makes directories, renames, removes and links, and
  tells the notices a real file system would: a write to a new file is
  created then written, a rename is renamed under the old path then the
  new one. It records every `watch` call, refusal and drop, scripts a
  refusal for a directory, latches every `watch` call until a test lets go
  (`hold_watches`), and can have each drop call its sink before it
  returns, as a platform's drop that joins a thread in the sink does,
  which is how a test sees that a registration is never dropped under the
  service's lock. `Flaws` makes a fake that breaks one rule of the port.
- **The contract** (`editor_watch::contract::check(watch, clock, ground,
  dir)`) runs 24 properties, each in a fresh subdirectory of a directory
  its caller owns, and returns the names of those that fail. Twelve are
  the port's: live on return (on 20 fresh registrations, so a race shows
  up); created; written; removed; renamed, under both paths; renamed over
  another entry; a tree's write two levels down; a subdirectory made after
  `watch` returned and a file written in it; spelled as given, for a
  directory registered through a link; independent registrations; a
  dropped registration silent (200 writes right after the drop, then a
  sentinel on a second registration); and the refusals. Twelve are the
  service's, run over `Service` on the watch and the clock the check is
  given: a file watch is told of a write, of a rename over the file, of its
  removal, of its creation, of a write after an atomic save, and of nothing
  beside it; a directory watch of each entry created, written, renamed and
  removed directly inside it, and of nothing deeper; a tree watch of a
  change in a subdirectory; five writes within a window of 300 ms arrive as
  one delivery (`COALESCED`); a cancelled watch's pending read is never
  completed; after shutdown a start is refused and a pending read never
  completed; and a flush asked while a start is in the port is completed
  after the start's own completion (`FLUSH`). Where the ground can hold
  the port's `watch` (`Ground::hold_starts`, which the fake's ground
  forwards to `FakeWatch::hold_watches` and a real ground leaves at its
  default, "cannot hold"), nothing is completed while the start is held,
  which forces the order; elsewhere the same order is required.
  - **How a property waits.** A sink sends each notice to a channel, and
    the property waits for one that matches, up to the ground's deadline
    (1 s on the fake, 10 s on real files). A negative claim uses a
    sentinel: the change that must not be noticed, then one that must, and
    when the sentinel's notice arrives nothing of the first may have come
    before it. That holds because one registration's notices are in order.
  - **On real files a service property checks that a kind is present**,
    never that the set is exactly something, and reads up to `READS` (4)
    deliveries for each change it looks for; `DIRECTORY_ENTRIES` looks for
    five. With no window each delivery is taken as soon as it is completed,
    and inotify tells a new file's creation, its write and the write's
    close one by one, so what one step made comes in several deliveries
    (seen in the Linux container). `COALESCED` is the exception: it fails
    if the path written five times is in more than its first delivery. The
    exact sets are pinned on the fake, in the service's unit tests.
  - **A property that needs a read still pending makes its file after
    the read is asked.** FSEvents can tell of a change made just before a
    registration once the registration is live, so a write before the
    watches can complete a read before `CANCELLED_SILENT` cancels it or
    `SHUTDOWN` shuts the service down (seen on the macOS runner under
    load). Both properties make the file after that point instead, which
    is why a fake that misses writes no longer fails them.
  - **The window passes through the ground.** `Ground::let_pass(ms)` lets
    time pass on the clock the check was given: the fake's ground, put on
    a manual clock (`FakeGround::on(clock)`), advances it, and the property
    then wakes the service; a real ground does nothing, and real time
    passes while the property waits. So `COALESCED` is deterministic on
    the fake, and on real files needs only that five writes take less than
    the window.
  - The fake keeps the contract, and each `Flaws` fake fails its own port
    property and the service properties that rest on that rule
    (`crates/editor-watch/tests/contract.rs`).
- **The service** (`editor_watch::service::Service<W, C>`), in the process
  service's shape: a watch is started with the caller's id, a target (a
  file, or a directory to a depth) and its coalescing (a window and a
  bound, both the caller's, with no default), and the call returns at once.
  A short-lived thread refuses a path that is not absolute or has a `..`,
  and a bound of 0 (as failed), then registers through the port, keeps
  `Started` or the refusal and completes. Registration is off the caller's
  thread because a recursive inotify watch walks the whole tree. From then
  on the id names the watch.
  - **A file is watched through the directory it is in**, registered to
    `Entries`, and only the changes that name the file are kept. So a
    write, a rename over the file, and a remove followed by a new file are
    each seen under its name, and a file that is not there yet can be
    watched, its creation told; its directory must be there. A watch on the
    file's own inode would go dead at the first rename over it (inotify's
    `IN_DELETE_SELF`). Siblings' changes are dropped before they reach a
    batch, which costs work in a busy directory and nothing else.
  - **Watches with the same directory and depth share one registration**,
    so N files followed in one directory cost one platform watch.
    Cancelling one drops the registration once no other watch uses it.
  - **A read** (`next`) is a pull, as a stream read is. A watch has at most
    one pending; a second is refused. It is completed at once if the batch
    is deliverable, and otherwise by whoever first makes it so: the notice
    itself when the window is 0, or the timer thread at the batch's
    deadline. One completion a read, and **the delivery is drained when it
    is taken**, so notices between the completion and the take are in it.
  - **The router.** Each registration's sink carries its serial, and a
    notice for a serial no longer live reaches no one. A live serial's
    notice goes to each watch on the registration: a file watch keeps its
    file's path, an entries watch its directory and what is directly
    inside it, a tree watch everything under its directory. A `Missed`
    notice reaches every watch on the registration, so a file watch is
    told missed on its file.
  - **Cancelling** takes a watch's id or a wait's. A watch's drops its
    batch, its pending read and its kept reply, none of them completed; a
    start cancelled while its port call is in flight drops the
    registration when the call returns, and is never completed. An id in
    use is refused. **Shutdown** refuses every later start (as shut down,
    completed at once), cancels every watch and every start in flight
    and drops every registration in one step, so a start held in the port
    does not keep the live watches' registrations, then waits for every
    start in flight; it is idempotent. **A flush**
    (`Service::flush`, deterministic-test-concurrency phase 1) is a wait
    of the caller's, completed once every start asked before it has
    returned from the port (registered and completed, refused and
    completed, or cancelled and what it registered dropped); at once when
    no start is in flight. A start leaves `Starting` before its completion
    is queued, so each start holds a ticket until then and a flush waits
    on the tickets; shutdown waits for every start's thread to finish, its
    flushes completed. A start's thread, after
    its own completion, completes each flush it was the last thing for, in
    the order asked, and shutdown completes the rest. **A pending
    read is not covered**: it waits on the disk, not on the service.
  - **A registration is never dropped, and the completion never called,
    under the service's lock.** It is taken out under the lock and dropped
    after: notify's FSEvents drop joins its run-loop thread, which may be
    in the sink waiting for that lock.
  - **Threads**: one timer thread for the service, a short-lived one for
    each start, and the adapter's for each registration. **Dropping the
    last handle joins the timer thread**: after the shutdown it tells the
    timer to end and joins it, so a completion the timer is inside is
    waited for and nothing of the service runs once the drop returns. The
    service keeps the timer's `JoinHandle` itself rather than an
    `editor_service::Worker`, since `editor-watch` depends on nothing of
    the editor's but `editor-wait`; the rule is the same. A drop on the timer thread itself
    does not join it. The starts' threads are waited for by their count,
    not joined.
- **The adapter** (`editor-watch-notify`) is over `notify`, pinned
  `=8.2.2` with only `macos_fsevent` on: inotify on Linux, FSEvents on
  macOS. `NotifyWatch::system()` is its one constructor, and no notify type
  is public.
  - A registration checks the directory first (one not there, a dangling
    link among them, is not found; something else, not a directory),
    canonicalizes it once, and makes a notify watcher of its own, so that
    registrations are independent: inside one watcher, `unwatch` of a
    directory drops the inotify watch that a recursive watch of its parent
    also uses, since notify keeps one descriptor a path.
  - **Paths are respelled as the caller gave them.** FSEvents reports
    canonical, firmlink-resolved paths (`/private/var/...` for a directory
    given as `/var/...`), and notify filters FSEvents' events on the
    canonical path; so the canonical spelling is registered, and every
    notice under it is spelled again under the given one.
  - **Events map to notices**: a creation is created; a write of data, a
    write's close, and an event notify could not name are written; a
    rename is renamed under each path it names, old and new; a removal is
    removed. A change of metadata alone and every other access are
    dropped. An event that asks for a rescan (inotify's queue overflowing,
    FSEvents' must-scan-subdirectories) and an error in the event stream
    are one missed on the directory. notify's errors: too many watches is
    the system's limit, a path not found is not found, permission denied is
    denied, anything else failed.
  - **A gate** keeps a dropped registration silent. The handler holds it
    for reading while it calls the sink; the drop takes it for writing,
    shuts it, and only then drops the watcher, because notify's inotify
    watcher does not join its thread when it is dropped. Looked at by hand
    on 2026-11-15: with the gate's check taken out of the handler, the
    contract still passed, three runs in the Linux container and on macOS;
    the gate is kept because notify does not promise it.
  - What notify brings in, as `Cargo.lock` resolves it: `notify-types`
    2.3.1, notify's own crate of event types; `walkdir`, `libc` and `log`,
    already in the lock; on Linux `inotify` 0.11.5 and `mio` 1.2.5; on
    macOS `objc2-core-services` 0.3.2 and `bitflags`. `deny.toml` lets only
    the adapter depend on `notify`, only notify on `notify-types`, only the
    adapter and `editor-ffi` on `editor-watch`, and only `editor-ffi` on
    the adapter.
  - **Set aside**, 2026-11-15 (the manifest says why): notify 9.0.0-rc.9,
    a release candidate still changing week to week, to move to in a commit
    of its own; `notify-debouncer-full` and `notify-debouncer-mini`, whose
    window runs on their own thread on the real clock, so the rule could
    not be pinned on a fake, and whose rename stitching relies on inotify's
    cookies, which FSEvents does not have; notify's kqueue back end, with
    no native recursion and a descriptor for each file; and `inotify` or
    `fsevent-sys` directly, two adapters for nothing gained.
  - Its test runs the contract on real files in a `tempfile` directory,
    deliberately not canonicalized, so that on macOS, where the temporary
    directory is reached through `/var`, every property shows the
    respelling. The watch crate has no real clock, so the test defines a
    monotonic one of its own.
- **Across the boundary**, `editor-ffi`'s `watches.rs` is the fourth service
  behind the completion queue (source id 4). The process has one service, a
  static `WATCHES: Service<NotifyWatch, Monotonic>` made on its first use,
  which completes through the completion queue. `editor-ffi` implements
  `editor_watch::clock::Clock` for `timers::Monotonic`, so the window is
  measured on the job clock; the static has a `Monotonic` of its own, not
  the timer service's instance, since only intervals matter.
  `NotifyWatch::system` is on the root `clippy.toml`'s list, with
  the static its one caller, so the unit tests run on the fake.

  | Function | Does |
  |---|---|
  | `editor_ffi_watches_start(id, words, words_len, path, path_len)` | Three words, the target (0 a file, 1 a directory's entries, 2 a directory's tree), the window in milliseconds and the bound, then the path's bytes, which must be UTF-8. False, starting nothing, for words that spell no start, a path that is not UTF-8, an id in use, or when the system refuses the start its thread |
  | `editor_ffi_watches_next(watch, wait)` | Asks for the watch's next delivery, as the wait `wait`. False for a watch that is not live, one with a read pending, or a wait id in use |
  | `editor_ffi_watches_take(wait, *mut RawWatchReply)` | Fills the record and returns true, or returns false when nothing is kept for the wait |
  | `editor_ffi_watches_flush(id)` | Asks for the wait `id` to be completed once every start asked before it has returned from the port; keeps no reply. False for an id in use |
  | `editor_ffi_watches_cancel(id)` | Cancels a watch, dropping its registration once no other watch shares it, or a wait |
  | `editor_ffi_watches_pending()` | Watches starting or live, and waits not answered or not taken: a readout for tests |
  | `editor_ffi_watches_shutdown()` | Ends every watch; a later start is refused as shut down |

  A reply is a status (0 started, 1 not absolute, 2 not found, 3 not a
  directory, 4 denied, 5 the system's limit, 6 shut down, 7 failed, 8
  changes), words, a detail and one buffer, each freed with
  `editor_ffi_text_free`. For changes the words are the count and then,
  for each change, its path's length in bytes and its kinds' bits, and the
  buffer is the paths end to end. **A delivered path is its raw bytes**, as
  the platform gave them, which on Linux need not be UTF-8. The headless
  and window mains call the shutdown after the process service's and
  before they quit the queues.
- **In Lean**, `FileWatch.start` and `FileWatch.next` are requests of the
  job port (`lean/Editor/FileWatch.lean`; [lean-runtime.md](lean-runtime.md),
  "An interface is a port, and a command is a program over it"), with a
  pure model composed with the process model, so that a command a job runs
  changes what its watches see. A watch is named for the job that started
  it and does not outlive it: the runner ends every watch a job still
  holds when the job ends, however it ends. A delivered path that is not
  UTF-8 becomes a change of the watch's own path with missed: the job is
  told that something changed which it cannot name.

| | macOS, FSEvents through notify | Linux, inotify through notify |
|---|---|---|
| Paths | Canonical (`/private/var/...`); the adapter respells them | As registered |
| Recursion | Native, always. notify filters `Entries`, and the service filters again | A watch for each subdirectory, added by walking the tree, and for each new subdirectory as it is made |
| Flags | Coalesced in each record, sometimes with an earlier change's flag. Real-file tests check that a kind is present | One event each, in order: a new file's creation, its write and the write's close come apart. A rename gives `From`, `To` and `Both` |
| A registration | A run-loop thread, joined on drop | An inotify instance and its thread. The drop does not join (hence the gate) |
| Limits | None met in practice | `max_user_instances` (often 128) caps registrations across every program of the user, and `max_user_watches` a tree's directories. Both come back as the system's limit at the registration, or as missed for a subdirectory made later that could not be watched |
| Overflow | Must-scan-subdirectories | `IN_Q_OVERFLOW`. Both come back as missed on the directory |
| Names not UTF-8 | APFS refuses them; notify's callback would panic on one | Possible. Lean delivers missed on the watch's path |
| A watched directory removed | Told as removed when the platform says so; FSEvents goes on following the path | Told as removed when the platform says so; the watch goes dead. Not pinned (open questions) |

Linux is checked by `mise run linux-ci`, which runs the same contract in
the container's own `/tmp`. `LIVE_ON_RETURN` and `DROPPED_IS_SILENT` pass
on both platforms, so the rule that a registration is live when `watch`
returns stays in the port.

**The acceptance criteria and the tests that confirm each.** The Lean
properties are `JobContract.fileWatchProperties`
(`lean/Editor/Job/Contract.lean`), numbered in their order, each run on the
model and on the runner over the fake watch service in `ModelTest`, and on
the runner over the library's service, on real files in a temporary
directory, in `contract-test`.

| Criterion | Tests |
|---|---|
| A job watching a file is told when the file is written | Service `a_file_watch_is_told_when_the_file_is_written` (fake); contract `FILE_WRITTEN` (fake, and real in `crates/editor-watch-notify/tests/contract.rs`); port `WRITTEN`; Lean property 1 |
| … when another file is renamed over it | Service `a_file_watch_is_told_when_the_file_is_renamed_over`; contract `FILE_RENAMED_OVER`, `FILE_SURVIVES_SAVE`; port `RENAMED_OVER`; Lean properties 2 and 7 |
| … when the file is removed | Service `a_file_watch_is_told_when_the_file_is_removed`; contract `FILE_REMOVED`; port `REMOVED`; Lean property 3 |
| A job watching a directory is told the path of each entry created, written, renamed or removed directly inside it | Port `CREATED`, `WRITTEN`, `RENAMED`, `REMOVED`; service `a_directory_watch_is_told_each_entry_directly_inside_and_nothing_deeper`; contract `DIRECTORY_ENTRIES`; Lean property 4 |
| A job with a recursive directory watch is told the path of an entry changed in any of its subdirectories | Port `TREE`, `TREE_NEW_SUBDIRECTORY`; service `a_tree_watch_is_told_of_a_change_in_any_subdirectory`; contract `DIRECTORY_TREE`; Lean property 5 |
| Several writes to one path within the coalescing window arrive as one event | `batch.rs`'s unit tests; service `writes_within_the_window_arrive_as_one_change`, `a_read_waits_for_the_window_from_the_first_notice` and `a_continuous_writer_is_delivered_once_a_window` (`ManualClock`); contract `COALESCED` (deterministic on the fake, and real); `ModelTest.fileWatchModelChecks` (the exact window); Lean property 6, which checks that the five writes are in the first delivery, once, and in no delivery twice, and that a later write is told: that no later delivery holds the path on the real library is left to `COALESCED` |
| After a config reload installs, only the watches the new config made deliver events; none of the old config's do | `ConfigTest.watchReloadChecks` (the headless host, a reload, the fake watch service); `ModelTest.fileWatchRunnerChecks`, "Jobs.removeOwner ends the watches of the owner's jobs, and leaves another owner's" and "a watch ends with its job, finished, failed or cancelled, through the watch service's cancel"; service `a_cancelled_watch_delivers_nothing_and_drops_its_registration` and `a_notice_after_the_registration_is_dropped_reaches_no_one`; contract `CANCELLED_SILENT` and port `DROPPED_IS_SILENT` (real); `ContractTest.fileWatchChecks`, "a job's watch does not outlive it" (the library) |

Other tests: `crates/editor-ffi/src/watches.rs`'s unit tests, on the fake
and the manual clock (words in, a reply out, malformed words refused);
`crates/editor-ffi/tests/watches.rs`, the wiring test, which watches a real
file in a temporary directory through the C functions and pulls the
completion from the real completion queue; and
`crates/editor-ffi/tests/watches_shutdown.rs`, a test binary of its own
because shutdown is process-wide. In Lean, `ffi-test` checks a start, a
read and a take in a temporary directory, words that spell no start, and a
reply's decoding; `contract-test` (`ContractTest.fileWatchChecks`) also
checks that a change whose path is not UTF-8 is delivered as missed on the
watch's own path, and skips that, saying so on stderr, where the volume
refuses such a name (APFS does).

## The app's launcher

As built (session-restore phase 3): `crates/editor-launch`, the core, and
`crates/editor-launch-std`, its real adapters and the `leanmacs` binary,
the app bundle's `CFBundleExecutable` (`docs/design/lean-runtime.md`,
"Restart, as built" and "The app's identity across an exec").

- **The ports** speak of a pid as the core's `Pid`: `Files` (read, an
  atomic write, rename, remove, whether a path exists), `Clock` (the time,
  a sleep), `Pids` (this process's pid, a wait for any process's end with a
  timeout, a kill), `Spawn` (a start that is nobody's child, answering its
  pid), `Exec` (which answers only when the exec failed) and `Platform` (the
  launcher's own path, whether this is macOS, a line on standard error). An
  `Invocation` is a program, its arguments, and the variables set and unset.
- **The rules** are the core's: `launch::run` (the default, explicit
  `--default` over the bundle's layout; a cold start; a hand-over's
  candidates, a missing one marked failed, an exec refused moving to the
  next in the same process with its watcher killed; with none left the
  record renamed `handover.failed` and status 1; a record of a later
  format left as it is and the default started cold; `CFProcessPath` set to
  the launcher on macOS on every exec of an editor), and `watch::watch`
  (the record gone: 0; the process ended with the record there: the
  candidate marked failed and the launcher exec'd again; 60 s over: a
  `SIGKILL` first). The root `clippy.toml` refuses `std::fs`,
  `std::process` and `std::env`.
- **The fakes** (`fake`): files that are a map, a clock that moves only when
  waited on, processes that end on a script on the same clock, starts and
  execs recorded, the exec's sentinel answer `Faked` after which the core
  returns so a test reads what was exec'd.
- **The contract** (`contract`): the file and clock properties run on the
  fakes and on the real adapters; the process properties on real processes
  alone, with `launch-probe --contract` as the helper (a wait and a kill of
  a process that is not the caller's child, a detached start with another
  parent, and an exec that keeps the pid, hands on exactly its arguments,
  applies its variables and answers a missing program `NotFound` with the
  process carrying on). `tests/fallback.rs` runs the launcher and its
  watcher end to end on real processes, a candidate that exits and one that
  kills itself; `tests/identity.rs` checks the main bundle in a fake bundle
  on macOS.
- **The adapters**: `std::fs`, writing beside the target and renaming;
  `std::time`; rustix for the pids, kqueue's `EVFILT_PROC`/`NOTE_EXIT` on
  macOS and `pidfd_open` with `poll` on Linux, polling `kill(pid, 0)` every
  50 ms where neither can be had; a double `std::process` spawn for the
  detached watcher, its intermediate the launcher's own `--detach` mode,
  which hands it the launcher's standard output and reports its pid; and
  `CommandExt::exec`. `identity::main_bundle` reads CoreFoundation's main
  bundle through `objc2-core-foundation`, whose types stay inside the
  crate.
- **The editor's exec and main bundle** (`editor-ffi`'s `launch`) forward
  to these adapters, so the editor and the launcher exec the same way.

## What Lean's runtime provides directly

| Service | Notes |
|---|---|
| **Sockets** | TCP, UDP and DNS from Lean's async library: a local listener for agent hook callbacks, and client connections. Not used yet; the job runner does not use that library, so how a job waits on a socket is for the work that first needs one. |
| **JSON** | Lean's own JSON library. Most external tools speak it. |

HTTP with streamed responses (some agents expose it) has no Lean library
that has been checked; see open questions.

## Platform

| Service | Notes |
|---|---|
| **Window and input** | Key, mouse, IME, resize and focus events on the editor queue. |
| **Clipboard** | Read and write. |
| **Notifications** | Post a desktop notification; request attention on the window; keep the machine awake while agents work. |

What is built of the window is the window itself: everything it reports
reaches the editor queue as the port documents it, and it tells whatever
draws in it what that needs to know. What draws in it reaches no window
from Lean yet ([text-and-display.md](text-and-display.md), "The window, as
built"):

- **The port** is `editor-platform`'s `Platform`: `run` opens a window as
  its options say and runs it on the calling thread until it is closed,
  handing each thing the window reports to one listener, the report, and
  each thing it says of its drawing to another, the drawer; `close` asks a
  running window to close, from any thread; and `request` asks the running
  window something (`Request`: enter or leave fullscreen, minimise, a
  title), from any thread, and does nothing with no window running. It
  grows by data: a new thing a window reports is a variant of `Input`, a
  new thing it tells the drawer a variant of `Canvas`, a new thing it is
  asked a variant of `Request`, and a new way to open it a field of
  `WindowOptions`. What a request does to a window is held to the port's
  request contract (`contract::requests`), against the fake's pure model,
  and the winit adapter's translation runs the same check.
- **What a window reports today** (`Input`): that it opened, with the
  platform's name; the focus gained or lost; a key pressed or released,
  whether it is a repeat, its logical key (a character, a named key, a dead
  key with its character, or unidentified), its physical key and the
  modifiers held, with the text it produced beside them; a step of an input
  method's composition (enabled, a preedit, a commit, disabled); the pointer
  pressed, dragged, released or wheeled, with its position, button and
  modifiers; the frame resized, with its size and scale; files the system
  asks the program to open; and a request to close. Named keys and
  physical keys are W3C UI Events names, as strings.
  The command loop fixed this shape (its phase 1) so that both roadmaps
  build on one, and the winit adapter produces all of it (the display
  pipeline's phase 5). The one option is whether composition is allowed.
- **As the winit adapter maps it.** A key's names are winit's own, which
  winit 0.31 takes from keyboard-types as the W3C values: the system key
  is the named key `Meta` and its codes `MetaLeft` and `MetaRight`, and
  Space is the character it types. keyboard-types' own `Unidentified` is
  an unidentified key. A release carries no
  text, and neither does a key whose text winit gives as a control
  character (Escape, Enter, Tab, Backspace): they are known by their
  names. The modifiers are those winit last reported, so on X11 the press
  of Control carries no `control`. A press and a release are where winit
  says, and the pointer is there after them; a move with a button held
  is a drag, carrying the button held longest, a move with none is not
  reported, and being told the pointer is where it already was is no move
  at all; a wheel is where the pointer last was and carries winit's
  delta, in lines or pixels, positive when the content moves right and
  down. The five buttons winit names are the port's five, and every other
  is another button by winit's number for it. A resize is the new size at
  the scale last known, a change of scale a resize at the size last
  known, and a window reports its size straight after it reports that it
  opened. A touch and a tablet tool are not the pointer: they report
  nothing and leave where the pointer is as it was.
- **Fullscreen is the system's, and Lean may ask for it.** The window
  is made with winit's default attributes, so on macOS it has the green
  button, which puts it into the system's fullscreen on a Space of its
  own: going in and coming out are a burst of resizes, and another Space
  is the window hidden and shown, each of which the window already
  reports and tells its drawer ([text-and-display.md](text-and-display.md),
  "The window, as built"). Lean asks for fullscreen and for a minimise
  with `Platform::request` (`editor_ffi_window_request`), which the winit
  adapter sends on a channel of its own and carries out on the main
  thread when it wakes the loop through winit's event-loop proxy. Whether
  the window is in fullscreen comes back on every `Resized`
  (`Resize::fullscreen`), read after the events that may change it, so
  Lean knows the state whether a request or the green button made it.
  The window's title follows the scene Lean publishes: the presenter
  sends it as a `Request::Title` when it changes. The event loop is built
  without winit's default menu: the menu bar is the editor's ("The menu
  bar", below), whose Window menu runs `toggle-fullscreen` and
  `minimise-window` with Lean's own chords (`C-s-f`, `s-m`) as its key
  equivalents. Nobody has seen a window of ours in fullscreen
  ([concurrency.md](concurrency.md), "Still to verify").
- **The menu bar** (`Request::Menu`, `Input::Menu`). The port carries it
  as plain data (`editor_platform::menu`): menus with a title, a role
  (the application's menu, the windows menu, or none) and items, each a
  separator or a title, an optional key equivalent (a character and the
  port's `Modifiers`) and an action, an editor command by name or a thing
  the system does itself (About, Services, Hide, Hide Others, Show All,
  Quit). The port lists every system action (`System::ALL`). Each crate
  that gives one a word or a selector of its own (`editor-ffi`'s tag,
  winit's selector) does it in an exhaustive match, so a new action fails
  to compile there until it has one, and reads it back by searching that
  list, which its tests round-trip. The menu bar is a field of the
  scene, as the title is: Lean publishes it,
  the presenter sends it as a `Request::Menu` only when it changed, and a
  scene that names none leaves it. The winit adapter takes it out of the
  requests once the window has opened, since the menu bar is the
  application's, and a pure module (`menu.rs`) plans what to build: each
  system action's standard selector, sent to the first responder; a
  command item's action the one method of a target object of the crate's,
  with its index among the command items as its tag; the key string and
  the modifier mask; the application's menu first; and which submenus
  become `servicesMenu` and `windowsMenu`. `menu_bar.rs` builds the plan
  in AppKit and decides nothing. The target is kept alive for the run,
  since an item holds its target weakly, and the main menu is cleared
  before it goes. Each item built is marked with an identifier, so a
  reading tells it from the items AppKit adds of its own (Emoji &
  Symbols, the window list); the plan's model of what AppKit holds is
  read back in the crate's tests, and the contract example reads the real
  one back through a `#[doc(hidden)]` probe, performs each command item
  and Quit, and sees `Input::Menu` and `QuitRequested`. The delegate
  registers `NSFullScreenMenuItemEverywhere = NO`, so AppKit adds no
  fullscreen item that would bypass `toggle-fullscreen`. A command item's
  key equivalent comes from the keymap (`Config.Registry.keyEquivalent?`,
  in Lean): AppKit runs a key equivalent before the window's view sees
  the key, so a chord the menu shows never reaches Lean as a key, and the
  menu and the keymap must agree. A chord a system item already shows
  (Quit's `s-q`, Hide's `s-h`, Hide Others' `M-s-h`) is shown on no
  command item, since AppKit matches the system item first and the
  command would never run by it. On the queue the input is the kind 12,
  code 0, the command's name as the text and no words; Lean runs it as an
  invocation no key yielded, so config's command of the name runs in its
  place. Elsewhere than macOS winit has no menu bar, and a menu changes
  nothing shown, as the port's request contract lets a platform with
  none.
- **Files the system asks the app to open** (`Input::OpenFiles`). When
  Finder opens a file with the app ("Open With", a double-click on a
  document of a type it claims, a drop on its Dock icon), macOS calls the
  application delegate's `application:openURLs:`; it puts nothing on the
  command line. winit 0.31 passes none of this on, and guarantees it never
  registers an application delegate (winit-appkit's crate docs, "Custom
  `NSApplicationDelegate`"). So on macOS `editor-platform-winit` registers
  its own, through `objc2`, `objc2-foundation` and `objc2-app-kit`, pinned
  exactly at the versions winit already resolves to, and `deny.toml` lets
  no other crate of the workspace depend on them. It is installed after
  winit's event loop is built and before it runs, because a cold start's
  open-documents event arrives during `finishLaunching`, before winit makes
  the window. Its one method reads each URL's file path and sends the list
  on a channel of its own, then wakes the loop, as a request is sent; it is
  the one untested forward. Every decision is pure and tested
  (`files.rs`): each list is one input, its paths in order, a path that is
  not UTF-8 is left out, an empty list is no input, and what arrives before
  the window has opened is held and reported after `Opened` and the
  `Resized` after it, in the order it arrived. A close drops pending files
  with the requests. The install also registers
  `NSTreatUnknownArgumentsAsOpen = NO` in the volatile registration
  domain, so AppKit does not take a command-line argument (`editor
  notes.txt`) for a file to open as well. On the queue the input is the
  kind `OpenFiles`, code 0, no text, and the words `[n, then for each of
  the n paths: m, m scalars]`. Nobody has seen it arrive from Finder or the
  Dock yet ([concurrency.md](concurrency.md), "Still to verify").
- **The system's quit** (`Input::QuitRequested`, `Request::KeepRunning`).
  macOS asks an app to quit in one way, whatever the user chose:
  Command-Q's `terminate:`, Quit from the Dock's menu, a logout, restart
  or shutdown. The Dock and loginwindow send the quit Apple Event, whose
  handler in AppKit calls `terminate:`, which asks the application
  delegate's `applicationShouldTerminate:`. The same delegate answers
  every ask `NSTerminateLater`, so AppKit waits inside `terminate:` for a
  reply, and hands the ask on through a channel and a wake of the loop. It
  decides nothing. The pure module `terminate.rs` does: the first ask once
  the window has opened is reported once (one held before it opened is
  reported after `Opened`, the `Resized` and the files); an ask while one
  is pending is not reported again; `KeepRunning` with one pending replies
  `replyToApplicationShouldTerminate:NO`, once, and is otherwise nothing;
  a close with one pending, one held or one still on the channel replies
  `YES`, once, after the drawer is told the window is closing, so nothing
  is left unanswered, unless a `KeepRunning` came with the close (found
  among the requests the closing wake-up drops), when it replies `NO` and
  the run returns; and a window that could not be opened replies `NO`
  to an ask held or waiting, so that the run returns with the failure.
  That a close with a quit pending may end the process inside the run,
  and that a keep running just before it refuses the quit, is the window
  port's rule (`Platform::close`), which the fake models
  (`ScriptedPlatform::quit_let_go`); the editor's window mode keeps it by
  doing all it must before the close, and by asking keep running first
  when its loop failed ([concurrency.md](concurrency.md), "Quit").
  The editor decides in Lean
  ([concurrency.md](concurrency.md), "Quit"). On the queue the input is the
  kind `QuitRequested` (11), code 0, no text and no words; the request is
  tag 4 of `editor_ffi_window_request`.

  What the contract example showed (`examples/contract/`, on macOS):
  winit's loop handles its wake-ups and the requests they carry while
  AppKit waits, since winit adds its run-loop sources and observers in
  the common modes, which hold AppKit's modal-panel mode; a reply made
  from the loop lets `terminate:` return within a few milliseconds; and an
  ask made in those milliseconds is folded into the terminate AppKit is
  finishing (a quit Apple Event is answered and dropped, and a nested
  `terminate:` ends the process). With a terminate pending, a close
  leaves winit's run unable to return, since AppKit's wait is under it,
  and once the close replies `YES`, AppKit ends the process (`exit(0)`)
  inside the run. So what must come before the end is done first: the
  editor's window mode shuts down before it asks for the close
  ([concurrency.md](concurrency.md), "Quit"), and the adapter tells the
  drawer the window is closing before it replies. The check's own close
  comes with a keep running asked just before it, with the scenario's
  third `terminate:` left pending: the close cancels it, `terminate:`
  returns and the run returns. The example runs a close with no keep
  running in a process of its own (`examples/contract/pending.rs`), which
  records its verdict before the close and must then be ended by AppKit,
  inside the run, with status 0; an exit handler fails any end before the
  verdict.
- **What a window tells whatever draws in it** (`Canvas`): that it
  opened, with its native window (`NativeWindow`: an AppKit view, an Xlib
  window or a Wayland surface, as plain data that names no library), its
  size and its display's refresh rate; a new size or scale; a new refresh
  rate; that the system asks for the content again; that it is hidden or
  shown; and that it is closing. The adapter tells damage only when the
  system asks for a redraw: it asks for none itself, and its loop waits.
  It reads the display's refresh rate when the window opens and after a
  move, a resize and a change of scale, and tells it when it is another.
  `editor-ffi` turns each into a word left with the render loop
  ([concurrency.md](concurrency.md), "Sharing state").
- **How it crosses to Lean.** `editor-ffi`'s `window::event` makes each
  input an event of the editor queue, with a key's identity, a pointer's
  detail, a resize and the paths to open as words beside it (the table in
  `window.rs`), and
  `window::input` is its inverse, which `editor_ffi_window_post_input`
  uses to post an input as a window would, for tests and the headless
  driver.
- **What real keyboards have shown.** On macOS, with composition allowed,
  no key event is marked dead: a dead key reaches Lean only as a
  composition's preedit and commit. Whether that holds in a window that was
  never clicked is not settled (rdm task `macos-composition-not-enabled`).
  Under Xvfb on Linux, with synthetic
  keys, a dead key arrived as a preedit and a commit with composition
  allowed and as a key marked dead without. Composition not allowed has not
  been run on macOS, and nothing beyond dead keys, such as a Japanese input
  method, has been tried on either ([concurrency.md](concurrency.md),
  "Still to verify").
- **The fake** is `ScriptedPlatform`: it reports that it opened, then a
  script, and waits for a close. It tells the drawer that it opened, with
  no native window and a fixed size, before it reports so; each scripted
  resize before it reports it; and that it is closing before its run
  returns. It records the options it was run with, and leaves the
  composition steps out when composition is not allowed. Everything above
  the port is tested on it, on both sides of the Lean boundary. It records
  what each run is asked, with the close in its place among the requests
  (`asked_with_close`; tag 9 in `editor_ffi_window_asked`'s words), and
  `wait_parked(bound)` (`editor_ffi_window_await_parked`) is a test readout
  that returns once the run has reported all it has to and waits for its
  close: notified as the run parks, never a poll, the bound only a hang
  guard.
- **The contract** (`editor_platform::contract`): `Opened` is the first
  input and names the platform; a close from another thread ends the run
  within a bound; nothing is reported once the run has returned; a close
  with no window running is harmless; the drawer is told the window opened
  before anything is reported, so that whoever learns of the window finds
  what draws in it made; it is told the window is closing once, last,
  before the run returns; and a platform that cannot open tells it
  nothing. The check asks for a close before the run and then leaves the
  open window alone for a settling time, so a run that an earlier close
  ends returns with no close asked of it and is refused. It is shown to
  refuse platforms that break each rule.
- **The adapter** is `editor-platform-winit`, over winit, pinned exactly
  (`=0.31.0-beta.4`, the newest 0.31 on 2026-11-15; 0.31.0 was not out).
  The gate opens no window, so it covers the adapter's translation, on
  winit's own values, and its refusal to run off the main thread. winit's
  event for a change of scale cannot be built outside winit, so it is
  translated from its scale; a key is translated from its parts too, by
  choice, though 0.31's key event can be built. The lines that take the
  two apart run only in a real window. A close asks the loop to end, with
  a flag the loop shares, and then wakes it with winit's `wake_up`: winit
  may wake a loop nobody woke, so the loop ends on a wake-up only when the
  flag is set. A count of the requests sent to the running loop and of
  those it has carried out on the main thread, notified as the loop
  counts, is a test readout (`probe::await_requests_handled`): the
  contract example reads AppKit back once after it, never by a poll. The
  adapter is held to the
  contract by an example binary that `mise run linux-window` runs under
  Xvfb in a container and `mise run window-contract` on a desktop.
- **Onto the queue**: `editor-ffi` runs a platform and pushes each input as
  an event from the window source, stamped with the reading of an input
  clock when the window reported it (`crates/editor-ffi/src/window.rs` has
  the table). The window is run by the main-thread service
  ([lean-runtime.md](lean-runtime.md), "Start-up and shutdown"). The
  interrupt key has no path of its own: every input takes this one path,
  and it is on this path that the interrupt flag, next, is raised.
- **The interrupt flag** (`crates/editor-ffi/src/interrupt.rs`): the
  primitive under the command loop's interrupt, whose policy is Lean's
  ([concurrency.md](concurrency.md), "Foreground: commands"). Lean sets the
  key (`editor_ffi_interrupt_key_set`, as words: a logical key, the
  modifiers and a mask of the modifiers to compare; Lean computes the mask
  from its chord rule, so the library compares words and knows no chord
  rule) and clears it. Every input reaches the queue through one arrival
  function (`window::arrive`), from a window and from
  `editor_ffi_window_post_input` alike: a press of the key counts one up
  before the event is pushed, and the event carries the interrupt mark,
  bit 3 of a key's code (`KEY_INTERRUPT`); an event the queue refuses
  because it was quit counts it down again. The flag is up while the count
  is above zero (`editor_ffi_interrupt_raised`), and Lean lowers it by one
  when its loop takes a marked event off the queue
  (`editor_ffi_interrupt_lower`, never below zero). `window::input` refuses
  a code with the mark, so a poster cannot forge it. The state is one
  process-wide static, so its C functions are tested in a process of their
  own (`crates/editor-ffi/tests/interrupt.rs`) and the logic on instances
  of its own.

What is built of the clipboard is the Rust library's half, below any
interface in Lean:

- **The port** is `editor_platform::clipboard::Clipboard`: `read` gives the
  text on the system clipboard, or none, and `write` puts text there. It
  says what a system clipboard can do and nothing of what the editor asks
  of one: which register a yank writes and when is the clipboard interface
  in Lean and its model, which are the command loop's. If that interface
  asks for more (the primary selection, something that is not text), the
  port grows by an argument.
- **The fake** is `MemoryClipboard`, text kept in memory, so that nothing
  above the port touches a real clipboard in a test. A second fake,
  `FailingClipboard`, fails every read and write with one reason: what
  the code above the port does when a clipboard cannot be reached is
  tested on it, across the C boundary and through Lean's real binding.
- **The contract** (`clipboard::contract`): text written is the text read
  back; non-ASCII text, a line feed and a tab come back unchanged; a later
  write replaces an earlier one; a clipboard not yet written to reads as no
  text or as text, and does not fail. It is shown to refuse clipboards
  that break each.
- **The adapter** is `editor-platform-arboard`, over arboard, pinned
  exactly, with its default features off. arboard needs no window handle,
  so the adapter stands without a window. It keeps one clipboard for its
  life: on X11 the text is served by the process that wrote it. A
  clipboard that holds no text reads as none, and any other error of
  arboard's is a failure in arboard's words.
- **Where it is checked.** The gate touches no clipboard: a real one is
  the desktop's. The adapter is held to the contract by an example binary
  that `mise run linux-window` runs under Xvfb in a container, in one
  process and with one process reading what another wrote, and that
  `mise run clipboard-contract` runs on a desktop, which nobody has yet.
- **Not built**: binding the adapter to the clipboard interface, and any
  C function or Lean for it (the display pipeline's phase 6).

The URL opener is a port of its own beside the clipboard, which hands a URL
to the desktop's handler for it (the rich-text display's phase 3, for a
link's URL target; `docs/design/text-and-display.md`, "Followable spans, as
built"):

- **The port** is `editor_platform::url_opener::UrlOpener`: `open` hands a
  URL to the system and says whether the system took it, which says
  nothing of whether a program then opened it. Which URLs are opened, and
  the check a URL passes first (a scheme, no control character), is Lean's
  (`lean/Editor/Link.lean`, `lean/Editor/Links.lean`).
- **It is reached from a job, never a command.** An open may block: on
  macOS `/usr/bin/open` returns once LaunchServices has the request, and on
  Linux each launcher is watched for up to 250 ms for an early failure. A
  command may not wait and a job may (`lean/Editor/Process.lean`), so
  `link-follow` starts the job `url-open`, which asks the job service
  `JobRequest.urlOpener` (`lean/Editor/UrlOpener.lean`).
- **The fakes** are `RecordingOpener`, which keeps each URL it takes in
  order, and `FailingOpener`, which refuses every one with its reason.
  `RecordingOpener` refuses a URL holding a NUL byte, as the system does,
  so the fake takes nothing the system refuses.
- **The contract** (`url_opener::contract`) holds only what an opener can
  be held to without launching anything: a URL holding a NUL byte is
  refused, with a reason that is not empty.
- **The adapter** is `editor-platform-open`, over the `open` crate, pinned
  exactly, with its default features off: `SystemOpener` hands the URL to
  `open::that_detached`, which starts the platform's launcher detached and
  reaps it. Only `editor-ffi` links it (`deny.toml`), and only Lean's window
  mode makes it (`editor_ffi_url_opener_system`); the headless mode's jobs
  have no opener.
- **Where it is checked.** The adapter runs the contract in its own tests:
  the NUL byte is refused at the launcher's spawn, before any program
  starts. That a well-formed URL reaches the desktop's handler is the
  adapter's one call into `open`, held by review: any other run would open
  a browser on the machine running the gate. The C functions are tested over
  the two fakes (`crates/editor-ffi/tests/url_opener.rs`), and Lean's
  binding over them through the glue (`ContractTest.urlOpenerChecks`,
  `ContractTest.urlOpenerJobFailures`).

## Text utilities

| Service | Notes |
|---|---|
| **Diff** | Line and word diff between two texts or snapshots, producing hunks; apply or revert a hunk. Used for gutter marks, for turning an agent's whole-file "old text / new text" into reviewable hunks, and for external reloads. Built of it: the line diff a reload applies, "Diff, as built for reload", below. |
| **Search** | Regex and literal search over a rope without copying it; project-wide search on worker threads with streamed results. Built of it: search within a text, "Search, as built", and the search of a workspace's files, "Project search, as built", below. |
| **Fuzzy matching** | Which candidates a pattern matches, and in what order, for a prompt's candidates and for pickers. Built: "Fuzzy matching, as built", below. |

### Diff, as built for reload

Built by the daily-driver floor's phase 5, for reloading a buffer from its
file as one edit that keeps the cursor and the markers.

**The port matches lines, and the script is core logic** (`crates/editor-diff`,
no dependencies).

- `LineDiff` is the port: the hunks that turn one list of lines into
  another. Its fake is `Lcs`, the textbook LCS; its contract holds what a
  script made over any engine keeps.
- `script(engine, old, new, limit)` is the core. It strips the lines the two
  texts share at their start and end in linear time, asks the engine about
  the middle only when each side is at most `limit` lines (the editor passes
  100 000), checks the engine's hunks and takes a list that is not one as a
  single hunk, and trims each hunk to the longest common prefix and suffix
  that end on a character boundary of both texts, so an escape and a
  character that differs only in its trailing bytes are replaced whole.
- The script is steps that walk both texts: retain a count, delete a count,
  insert a range of the new text. It names no text.
- **The adapter** is `editor-diff-imara`, over imara-diff 0.2.0's histogram
  diff, pinned exactly; no imara type is public, and `deny.toml` lets only
  it name the library and only `editor-ffi` name it.
- **The service** is `editor-ffi`'s fifth behind the completion queue
  (`src/diffs.rs`): one thread of its own works the oldest request with no
  lock held, so a long diff holds up neither a load nor the editor thread.
  It is given two snapshot handles, cloned, and nothing it could write
  editor state with. The script crosses back as words. **A flush**
  (`editor_ffi_diffs_flush`, deterministic-test-concurrency phase 1) is the
  file service's marker on the same shared queue: completed when the
  worker reaches it, so every diff started before it has been worked and
  completed first. It keeps no answer.
- **Applying a script** is `editor_ffi_document_apply_script`: one
  transaction, its inserts copied rope to rope from a snapshot a piece at a
  time, refused (`Moved`) when the document's revision is not the one the
  script was made for, and refused (`BadChange`) unless every step starts
  and stops on a character boundary of both. It searches nothing, so its
  cost on the editor thread is linear in the steps and the inserted bytes.
- **Hunks** (built by the version-control roadmap's phase 2, for gutter
  marks): `hunks(engine, old, new, limit)` answers the same checked line
  hunks `script` trims, untrimmed, as byte ranges of whole lines in both
  texts (`ByteHunk`): each from a line's start to the next line's start or
  the text's end, none empty on both sides, none for equal texts. `script`
  and `hunks` share one private function for the strip, the limit and the
  check, so they never disagree about which lines changed. Whole lines,
  not trimmed ranges, because a gutter marks lines and the review buffer
  will excerpt lines. `apply_hunks` says what they give; the contract's
  `HUNKS_APPLY`, `HUNK_LINES` and `HUNK_SWEEP` (generated texts from a
  fixed seed, which the imara adapter's tests name) hold every engine to
  it. The service answers a request for hunks (`editor_ffi_diffs_start_hunks`)
  as a count and four words a hunk (`editor_ffi_diffs_take_hunks`); a take
  of the other kind's answer takes nothing and keeps it.
- Not built: a word diff, applying or reverting one hunk.

### Fuzzy matching, as built

Built by the command loop's phase 14, for the candidates of a prompt
(`concurrency.md`, "Prompts").

**The port is a scorer, and the order is core logic** (`crates/editor-fuzzy`,
no dependencies).

- `Scorer::scores(pattern, candidates)` answers one entry for each
  candidate, in order: a score, higher for a better match, or none where
  the pattern does not match. It is asked for the whole list at once, so
  an implementation reads the pattern once and reuses its scratch memory.
- `rank(scorer, pattern, candidates)` is what the editor asks: the indices
  of the candidates that match, best first. Its rule: **a candidate that
  is the pattern, byte for byte, first; then the higher score; then the
  order the candidates came in.** A scorer that answers too few entries
  leaves the rest unmatched, and extra entries are ignored.
- **Why the order is not the adapter's.** The library does not rank an
  exact match first: it scores `w` the same in `w` and in `wq`. In the
  core the rule is written once and tested on a scorer that answers canned
  scores.

**What matches** is one rule, which the port's contract holds every scorer
to: the pattern's Unicode scalar values all occur in the candidate, in the
pattern's order, adjacent or apart.

- Case is kept: `a` does not match `A`.
- A scalar value matches itself alone: an accented letter is not its base
  letter, and a composed character is not its decomposed form.
- No character of a pattern is syntax: a space is a character to find, so
  an ex line with an argument is matched whole.
- The empty pattern matches every candidate, and no other pattern matches
  the empty candidate.

It is this small so that the Lean model can agree with the library on
every input, with no table of Unicode's: a Lean `String` is a list of
scalar values, and the model is a subsequence test
(`lean-runtime.md`, "The editor's port is a composite"). The cost is
stated: `Re`
does not match `reload`, and a decomposed `é` does not match a precomposed
one. Folding ASCII case is possible later, in the core and the model in
one commit.

**The fake and the contract.** `InOrder` is the port's fake: the rule
above, every match scored 0. `contract::check` names each property a
scorer breaks. Every property is about which candidates match and none is
about a score: one answer for each candidate; a pattern in order matches;
a character the candidate lacks, another order or one repeat too many do
not; the empty pattern and the empty candidate; case; scalar values,
composed or not; no pattern syntax; and a sweep of 20,000 generated pairs
from a fixed seed over four alphabets, against the contract's own
statement of the rule. The contract is seen to bite on scorers written in
its tests that each break a rule.

**The adapter** is `crates/editor-fuzzy-nucleo`, over `nucleo-matcher`,
pinned `=0.3.1`. It keeps one matcher of the library's (about 135 KB of
scratch memory) and makes one fuzzy atom of the pattern, with case kept,
nothing normalised and no pattern syntax read. No nucleo type is public,
and `deny.toml` lets no other crate depend on the library.

- **Its features.** Two of the library's three are on,
  `unicode-casefold` and `unicode-normalization`, only because 0.3.1 does
  not compile without them; the adapter asks for neither. Its grapheme
  segmentation is off: with it only the first scalar value of each
  cluster is looked at.
- **Its limit.** The library adds a score up in a `u16`, unchecked: at
  most `26 n + 10` for a pattern of `n` scalar values, whatever the
  candidate's length, so a pattern of 2,521 or more can panic in a build
  with overflow checks and wrap in one without (read from its source and
  measured, 2026-11-14; the crate docs have the measurement). The adapter
  hands the library no pattern longer than 2,000 scalar values. A longer
  one it matches itself, by the port's rule, and scores every match the
  same, so those are ranked in the candidates' order after a candidate
  that is the pattern. So the adapter answers for any pattern and
  candidates, and no score it answers has wrapped.
- **Its licence** is MPL-2.0, in a workspace that is GPL-3.0-or-later. It
  is used unmodified. Nothing in the gate checks licences, and whether
  the combination is acceptable is the owner's to confirm.
- **Set aside**: `nucleo` 0.5.0, the same matcher behind an injector and a
  worker pool, which answers later through a snapshot that is polled:
  decided against by completion's phase 3, below ("Off the editor
  thread"); `frizbee`, which forgives typing errors, so a pattern with a character
  the candidate lacks can match; `fuzzy-matcher` and `sublime_fuzzy`, not
  looked into; and a matcher of our own, since the scores are what the
  library is for.

**Across the boundary** there is one stateless call
(`crates/editor-ffi/src/fuzzy.rs`): `editor_ffi_fuzzy_rank` takes the
pattern and the candidates and fills a record with the indices of the
candidates that match, best first, as words. The candidates cross as lists
do, with one string beside the words: their count and the byte length of
each, and every candidate end to end, borrowed for the call. It makes the
adapter for the call and keeps nothing: no handle, no static. Candidates
that cannot be read are one refusal, never a panic.

- **Matching answers in the call, on the thread that asked.** For a
  prompt with at most `Loop.inlineMatches` (250) candidates to match that
  is the editor thread, inside the publish of a scene; for a longer one, a
  pool thread, in a match job of the loop's own, which asks the same call
  as a request of the job port (`JobRequest.fuzzy`, answered by
  `Fuzzy.real`). The call keeps nothing, so either thread is safe.
  Measured once, in a release build: 100,000 candidates of about 40 bytes
  scored in 7.4 ms. Each call also copies the candidates' bytes once, in
  Lean. The prompt benchmark (`concurrency.md`, "Matching off the editor
  thread, measured") has what a key costs: about 0.1 ms over 100,000 on
  the worker, the listing arriving about 50 ms after it; and 49 ms with
  the 100,000 listed inline, as before phase 3.
- **Off the editor thread** (completion's phase 3's decision): a long list
  is matched by running the prompt's style in a job on Lean's task pool,
  over the existing port. nucleo 0.5's worker (`Nucleo` with its injector)
  was rejected:
  1. Matching is a style, a Lean program (`Completion.Style`): orderless
     and config's styles never call the matcher. nucleo's worker could make
     only the fuzzy style asynchronous; a long prompt under any other
     style would still be matched on the editor thread. Running the style
     on the pool covers every style with one mechanism.
  2. The port's rule would be lost: nucleo's incremental matcher is driven
     by a pattern string it parses with its own syntax (`reparse`), and it
     orders by score and index with no "the pattern itself first" rule,
     which `rank` owns.
  3. A second store and a second pool: the injector keeps its own copy of
     the candidates in Rust beside the prompt's, which are editor state
     rolled back with a command; its results arrive through a snapshot that
     is polled (`tick`), which needs a handle across the FFI, a polling
     thread or a timer and an event; its rayon pool competes with Lean's,
     one thread a core; and it would add `nucleo`, `rayon` and
     `parking_lot` to `deny.toml`'s graph.
  4. The pool route reuses the job runner, keys and cancellation, the
     delivery as a command with a scene after it, the job model and the
     driver on the models, and the stateless call; it cost one request of
     the job port.
  What is given up: nucleo's incremental refinement (a longer pattern
  rescans only the last matches) and matching across cores. **Revisit
  when a measured match of the largest list a picker lists (the project
  file picker, the workspace finder, `find-file-in-workspace`: 100,000
  files) takes
  longer than 50 ms on the worker**; the recorded run is at about 50 ms
  from the key to the listing, most of it Lean's own work over the
  candidates.
- **Not built**: a handle that keeps the candidates in the library. Nor
  case folding, normalisation, or highlighting the characters that
  matched.

Tests: the ranking rule on a canned scorer, and the fake and the contract,
in `editor-fuzzy`; the adapter's own cases, its limit and the port's
contract on it, in `editor-fuzzy-nucleo`; the C function's decoding and
one wiring case, in `editor-ffi`. No test pins a score's value.

**Locating a quote** (navigation-and-windows phase 5, for a working set's
ranges found again after their file changed, `review-and-navigation.md`)
is a second question of the same crate, behind a second port
(`crates/editor-fuzzy/src/locate.rs`).

- `Searcher::spans(pattern, text, max_errors)` reports spans of the text
  whose byte-wise Levenshtein distance to the pattern is at most
  `max_errors`, each with its distance; at least one with the fewest
  errors any span of the text has, and none when no span is within them.
- `locate(searcher, pattern, text, near, max_errors)` is what the editor
  asks, and its rule is the crate's: the empty pattern is answered none
  without asking; a reported span counts when it is within the text, both
  ends are character boundaries and its errors are within the limit; the
  answer is the one with the fewest errors, then the start nearest
  `near`, then the earliest, then the longest. **"Fewest errors" is all
  an asker may rest on**: which of several equal spans a library reports
  is its own.
- **A span that cuts a character is dropped, not moved.** Errors are
  counted in bytes, as the library counts them, so on text that is not
  ASCII the library's best span can cut a character, and the answer is
  then a worse span or none. For the editor that is safe: a quote it
  cannot place is shown drifted, never moved wrongly.
- **The fake** is `Scan`: every span whose ends are character boundaries,
  measured one by one. **The contract** is `contract::check_searcher`:
  every span reported is within the text, its claimed errors and the
  limit; the fewest errors reported are an exhaustive oracle's, asked of
  ASCII texts, where bytes and characters agree; nothing is reported when
  the oracle finds nothing within the limit; the pattern where it is
  expected is answered there; an answer's ends are character boundaries;
  and a sweep of generated texts from a fixed seed. It is seen to bite on
  searchers written in its tests: one that claims fewer errors than a
  span has, one that misses the best spans, one that reports past the
  limit, one that reports nothing, and one that reports past the text.
- **The adapter** is `crates/editor-fuzzy-triple-accel` (`TripleAccel`),
  over `triple_accel`, pinned `=0.4.0` (MIT, used unmodified). It asks
  `levenshtein_search_simd_with_opts` with Levenshtein costs, the best
  spans and no anchor, and reports each match as a `Span`; it chooses
  nothing. An empty text it asks of `levenshtein_search_naive_with_opts`
  instead, with the same arguments: on x86 the SIMD search of 0.4.0
  reports no span of an empty text (it never reports the anti-diagonal
  that ends at offset 0, the empty text's only span), which the
  contract's sweep caught on the ubuntu leg, and the scalar search has no
  such gap. The library finds every span within `k` edits with no limit on
  the pattern's length, and its "fewest errors" is exactly what a pure
  model states. On x86 it takes SIMD paths chosen at run time, through
  `unsafe`; elsewhere, Apple silicon included, its scalar path, which is
  O(text × pattern). No triple_accel type is public, and `deny.toml` lets
  no other crate depend on the library. It is held to the port's contract
  and to three cases of its own: one substitution is found with one
  error, a pattern with no span near enough reports none, and an empty
  text reports the empty span exactly when the whole pattern is within
  the errors allowed.
- **Set aside**: `diff-match-patch-rs` 0.5.1, whose `match_main` is
  bitap: it refuses a pattern over 32 characters and scores nearness and
  errors together, which no simple model can state. **Risk**: triple_accel
  is unmaintained (2021). If it measures slow, or an advisory lands, the
  port lets another library (`diff-match-patch-rs`, `sassy`) replace it
  with no change above the port.
- **Across the boundary** it is a second stateless call,
  `editor_ffi_fuzzy_locate` (`crates/editor-ffi/src/fuzzy.rs`): the
  pattern and the text borrowed for the call, the expected offset and the
  limit as scalars, and whether a span was found with its `ByteRange`, as
  `find` answers. It makes the adapter for the call and keeps nothing. A
  pattern or text that is not UTF-8 is answered not found. Lean binds it as
  `Ffi.fuzzyLocate` (`lean/Editor/Ffi/Fuzzy.lean`); one wiring case in
  `crates/editor-ffi/tests/fuzzy.rs`, and two in `ffi-test`'s
  `fuzzyChecks`, an exact place and one substitution after two-byte
  characters.

### Search, as built

Built by the daily-driver floor's phase 3, for `/ ? n N * #` in a buffer.
Two crates are built, and `editor-ffi` links them: its two C functions
(`crates/editor-ffi/src/search.rs`) make the adapter for each call and ask
the rule over a snapshot's pieces, with `editor_text::is_word_character`
as the word class, and keep nothing; no compiled pattern is cached. The
text port's `search` and `matches` (`lean/Editor/Text.lean`, "Search")
reach them through the real binding, and the text model answers literal
patterns alone.

**The pattern is Vim's syntax, parsed by our own parser**
(`crates/editor-search`, `pattern`, no dependencies). The user types Vim's
syntax with its default `magic` option, not the regex library's:

- The most common search in code is a literal with punctuation in it, and
  the two syntaxes disagree on the punctuation. In the library's syntax
  `foo(` is an error and `a|b` matches `a` or `b`; in Vim `( ) | + ? { }`
  are characters and `\( \| \+` are the operators.
- `\<word\>` is what `*` and `#` build, and the library has no such atom:
  its `\b{start}` uses Unicode's word class, not the text's.
- A Vim user types Vim's syntax without thinking.

The parse answers a tree of the crate's own (top-level branches, each with
its `\<` and `\>`, holding a sequence of atoms with their repetition), so
no pattern string in the library's syntax is ever made. The subset built,
with case kept (`ignorecase` is off):

| Typed | Means |
|---|---|
| Any other character, and `\` before one of `\ / . * [ ] ~ ^ $` | That character |
| `.` | Any character but a line feed |
| `[…]`, `[^…]` | A collection, with ranges `a-z`, `]` first literal, and `\\ \] \^ \- \t` inside. None matches a line feed, as in Vim without `\_[`: a range that spans U+000A (`[\t-~]`) is cut around it, and a negated one leaves it out. A `[` with no closing `]` is a literal `[`, as in Vim |
| `*` after an atom; `\+`; `\=` and `\?`; `\{n,m}` `\{n}` `\{n,}` `\{,m}` `\{}`; `\{-…}` | Greedy repetition; one or more; zero or one; counted; and the same lazily. `*` at the start of a branch is a literal `*`, as in Vim |
| `^` at the start of a branch, `$` at its end | The start and the end of a row (before its line feed, or the text's end). Elsewhere each is literal, as in Vim; a group's alternatives have them too |
| `\(…\)`, `\|` | A group, and alternatives (leftmost-first) |
| `\s \S \d \D \w \W \t` | A space or a tab; not one; `[0-9]`; not; `[0-9A-Za-z_]`; not; a tab. A negated class never matches a line feed |
| `\<` at the start of a branch, `\>` at its end | A word starts there; a word ends there. The word class is the text's |

**What is refused**, each with the sentence Vim gives where it has one:
`E54: Unmatched \(`, `E55: Unmatched \)`, `E51: Too many \(` (nine groups
at most, as in Vim), `E64: \+ follows nothing` (and the same for `\=`,
`\?`, `\{`, and `*` after `\<`), `E61: Nested *` and `E62: Nested \+`, `E554:
Syntax error in \{...}`, `E944: Reverse range in character class`, and
for `~`, Vim's answer while no `:s` has run, `E33: No previous substitute
regular expression`. The empty pattern is refused (the editor never sends
one). The rest are refused as `<atom> is not built in a pattern`: a line
feed, `\n` and `\_x` (a match across rows); `\%…`, `\@…`, `\z…` and the
back-references `\1` to `\9`; `\c \C \v \m \M \V`; `[:alpha:]`-style
classes; `\<` or `\>` away from a branch's end; and every other escape.
**No pattern that parses matches a line feed**, and the
rule of which match rests on that.

**The port is an engine** (`Engine::compile`, `Compiled::find`). The
engine is asked to compile a branch's sequence, without its `\<` and
`\>`, which the core checks. What it compiles answers
`find(haystack, from, to)`: the leftmost-first match that starts in
`from..=to`, where `^` and `$` see the text outside the span, and it may
stop looking at the end of the row that holds `to`. The haystack is
`Pieces`, a text as the pieces it is held in, borrowed: a snapshot's
chunks.

**The fake and the contract.** `Literal` is the port's fake: it compiles
a run of literal characters and refuses any other sequence with a
refusal named for it. `contract::check` names each property an engine
breaks, all on literal cases: found at its leftmost occurrence; across the
pieces' boundaries; not found when absent; case kept; a scalar value is
itself alone; an escaped special is a character; a match starts in
`from..=to` and may end after `to`; no match holds a line feed; and a sweep
of generated texts cut into generated pieces, from a fixed seed, against a
naive scan. It is seen to bite on engines written in its tests.

**The rule of which match** is core logic (`search`, `matches`), Vim 9.1's
under its default options (`cpoptions` holds `c`, `wrapscan` on):

- The matches of a pattern in a text are found row by row: in a row, the
  leftmost-first match from its start, then from where each one stopped,
  or one character further after an empty one. No match holds a line
  feed, so this is one walk of the whole text, begun at any row's start.
- `\<` and `\>` are checked by the core with the word class the caller
  hands in (the text's: an ASCII letter or digit, `_`, or any character
  from U+0080 up). A candidate that fails is passed over and the walk
  tries again one character after its start.
- Top-level alternatives are asked one by one: the leftmost wins, the
  earlier on a tie, so `\<foo\>\|\<bar\>` works.
- **Forward** from `p`: the first match that starts after `p`, walking
  from `p`'s row start (`cpo-c`: `abab` in `abababab` from 0 answers 4),
  or else the text's first match, wrapped. **Backward**: the last match
  that starts before `p`, walking each row from its start, from `p`'s row
  upward, or else the text's last match, wrapped. **Matches in a range**:
  those that start in it, walked from its start's row start (`aa` in
  `aaaa` from 1 answers `2..4` only).
- A backward search asks the engine spans within one row, each row once,
  so its cost is a scan of the rows it walks.
- An offset that is not a position, or a range that is not two positions
  in order, is refused.

**The adapter** is `crates/editor-search-regex`: `RegexEngine`, over
`regex-cursor`, pinned `=0.1.5` (MIT OR Apache-2.0), a fork of
`regex-automata`'s engines that searches a discontiguous haystack through
a `Cursor`, which Helix uses over its rope. Its `ropey` feature is off (it
brings ropey 1.x, which only `editor-text` may name); the adapter has its
own cursor over the pieces. `regex-syntax`, pinned `=0.8.11`, builds the
library's `Hir` from our tree. No type of either is public, and
`deny.toml` lets no other crate depend on them, nor on `regex-automata`.

- `.`, a negated collection and `\S \D \W` are classes of every character
  but theirs and a line feed; `\s` is a space or a tab. A collection's
  ranges never hold a line feed (the parser cuts one that spans it), so a
  positive collection is the class of its ranges as they are.
- `^` and `$` are the library's `StartLF` and `EndLF`. A carriage return is
  a character of its row, so in CRLF rows `$` holds after the `\r`:
  `a$` does not match `a\r\n`.
- A pattern too large for the library's limits is refused with
  `E363: pattern uses more memory than 'maxmempattern'`.
- **The library's bug** (0.1.5, seen 2026-11-16): a search whose span
  ends inside a chunk that is not the last can panic. The adapter's
  cursor shows the library no text past the end of the row that holds
  `to`, which changes no answer.
- **Set aside**: `regex` 1.13 and `regex-automata` alone, which search
  one contiguous `&str`, so a search would copy the rope; `fancy-regex`,
  whose look-around could state `\<` and `\>` anywhere but which needs a
  contiguous haystack and has no linear-time bound; `pcre2` and `onig`, C
  libraries; and an engine of our own.

**The limits**:

- `\>` is checked against the match the engine answers, so a branch whose
  end could match fewer characters (`\<x.*\>` on `xy z!`) can miss a match
  Vim finds by backtracking. For `*`, `#` and literal patterns it is
  exact.
- `\<` and `\>` only at a branch's ends.
- No multi-line patterns (`\n`, `\_x`).
- No compile cache: a search compiles its pattern for the call.

Tests: the parser on the table and every refusal, the haystack, the rule
of which match on `Literal` (forward, backward, `cpo-c`, wrap, the word
checks with a class beyond ASCII, rows and CRLF, ranges, empty matches,
and how many questions a long backward search asks), and the contract on
the fake and on engines that break it, in `editor-search`; what only a
regex shows, a sweep that how a text is cut changes no answer, the
library's bug, and the port's contract on the adapter, in
`editor-search-regex`.

### Project search, as built

Built by navigation-and-windows phase 4, for `project-search`: every
match of a pattern under a workspace's root, honouring ignore files, with
open buffers searched in their buffer's text.

**The port is the files under a root** (`crates/editor-grep`, `Files`, no
dependencies). `walk(root, visit)` visits each file under the root by its
path relative to it, depth first, each directory's entries by the bytes of
their names (so `a/b` before `a-c`), leaving out an entry whose name
starts with `.` and one an ignore file excludes, with everything under
each. A root that is not there, not a directory or not readable is a
refusal of its own kind; an entry below it that cannot be read is left
out. `rows(path, holds, visit)` reads a file a row at a time: a row ends
at a line feed, which is not in its text (a `\r` is); the last row is a
row with no line feed, and an empty file has none; rows are numbered from
0 with the byte offset of each start; a row that is not UTF-8 is decoded
lossily. `holds` is asked of each row once, in order, and only the rows it
holds for are visited. A file with a NUL byte is binary, and no row of it
is visited. A visit's `Stop` ends a walk or a read.

**The fake and the contract.** `fake::FakeFiles` is a tree in memory,
built with `.file(path, bytes)` and `.excluded(path)`, the stand-in for an
ignore file; it applies the hidden rule itself. `contract::check` names
each property an implementation breaks, each in a fresh subdirectory made
through a `Ground` the caller supplies (the fake's tree, or `std::fs` in a
temporary directory): the walk's order, hidden entries, excluded entries,
files alone, an empty file, row numbers and offsets, the last row, a
carriage return, lossy rows, `holds` once a row, `Stop`, a binary file, and
the root's refusals. It is seen to bite on implementations written in its
tests. What each ignore file means is not in it, since the fake has none:
the adapter's own tests pin it.

**The rule of a search** is core logic (`editor_grep::search`, or
`Search::prepare` then `Search::run`), over the files port and
`editor-search`'s engine port:

- Before any walk, a root that is not absolute or has a `..` component is
  refused, and so is a pattern that does not parse or that the engine
  refuses, with the sentence `/` says (`E54: Unmatched \(`).
- **One pattern syntax, Vim's, and one match rule.** The pattern is
  compiled once a search (`editor_search::CompiledPattern`, which compiles
  each top-level branch once and is asked of many texts; `matches` and
  `search` of a single text are built on it) and asked of each row as one
  piece, with the text's word class. A row holds when it has a match that
  is not empty; an empty match is never answered. So a match on disk is
  one `/` finds in the buffer, and the `search-match` drawn over the
  results agrees with what was found.
- **An open buffer's text is searched in place of its file** when the walk
  reaches the file's path, compared as spelled: its matches are asked of
  its pieces, rows counted by line feeds, answered with source `Buffer`. An
  overlay the walk does not reach is not searched, so ignore rules hold
  for open buffers too.
- A file that cannot be read, or is binary, has no match; only the root's
  refusal ends a search.
- **Limits**: at most so many files with a match and so many matches. The
  one past a limit is not answered, the walk stops, and the summary says
  it was truncated; a file is cut short at the matches limit.
- `stopped` is asked before each file and each row.

**The service** (`editor_grep::service::Service`, in the shape of the
watch service) owns each search under an id of the caller's, on a thread
of its own that makes its port and engine with a factory. A start returns
at once; the thread refuses what the rule refuses before any walk and
keeps `Started` or the refusal, completing the id. Each `next(id, wait)`
is a read, completed when anything is there to deliver: every file found
and not yet taken, in walk order, up to `bound` matches, a file with more
than `bound` cut into several deliveries under one path, drained when it
is taken. The end (the summary, or the root's refusal) comes in the
delivery that takes the last file, and frees the id. The search waits
while `bound` matches or more are kept and not taken, so memory is bounded
and a slow reader slows its search. `cancel` makes its `stopped` true and
completes nothing more; an id in use is refused; `shutdown` cancels every
search and waits for every thread. **A flush** (`Service::flush`,
deterministic-test-concurrency phase 3) is a wait of the caller's,
completed once the thread of every search started before it has returned:
a cancelled search's bookkeeping goes at its cancel, but its thread may
still be in a read, so each thread holds a ticket until it returns and a
flush waits on the tickets. It is completed at once when no search's
thread runs, keeps no reply, and a cancel withdraws it; shutdown completes
those left. A caller that cancelled its searches and then sees the flush
knows nothing still walks their directories (`Linked.withFiles` with the
target `greps`).

**The adapter** is `crates/editor-grep-ripgrep`: `RipgrepFiles`, over
ripgrep's libraries, each pinned exactly to the newest release on
2026-11-19 (Unlicense OR MIT): `ignore =0.4.34` walks, with
`standard_filters` (hidden entries, `.gitignore` and `.ignore` in the root
and above it, `.git/info/exclude`, the global excludes),
`require_git(false)` (a `.gitignore` is honoured outside a repository),
`follow_links(false)`, entries sorted by the bytes of their names, on the
calling thread; `grep-searcher =0.1.17` reads, with line numbers, binary
detection that quits at a NUL, BOM transcoding, and no memory map; and
`grep-matcher =0.1.9` is the interface of a private matcher that declares
no line terminator, so the reader takes its row-by-row path and hands each
row, without its line feed, to the port's `holds` once. Rows held are kept
and visited when the read ends, so a NUL found in a later block makes the
whole file binary. No type of the three is public, and `deny.toml` lets no
other crate depend on them. `ignore` brings `globset`, which compiles an
ignore file's globs to regexes inside the library; no crate of the
workspace makes a pattern string. Set aside, departing from the phase's
text:

- `grep-regex`: it compiles only a pattern string in Rust's regex syntax,
  so a Vim pattern would have to be printed back from `regex-syntax`'s
  tree, which never happens here; and its `\b` is Unicode's word class,
  not the text's, so `\<foo\>` would find different matches on disk than
  `/` finds in the buffer.
- Running `rg` as a child: a program the app bundle does not ship, and
  output to parse.
- `git ls-files` with the reading in Lean: git workspaces only, and Lean
  has no regex engine.
- `walkdir` alone: no ignore files.

`ignore` reimplements git's rules, where the workspace finder's lister
asks git (`git ls-files`): a file force-added though an ignore file names
it is listed by the finder and left out of a search.

**Across the boundary**, `crates/editor-ffi/src/grep.rs` is the seventh
service behind the completion queue (source 7), in the watch service's
shape: `editor_ffi_grep_start(id, words, strings, snapshots)` takes the
limits, the bound and the lengths as words, the root, the pattern and the
overlays' paths end to end, and a snapshot handle for each overlay, whose
text is cloned (no text copied) and searched as its chunks;
`editor_ffi_grep_next(id, wait)`, `editor_ffi_grep_take(wait, out)`,
`editor_ffi_grep_cancel`, `editor_ffi_grep_pending` and
`editor_ffi_grep_shutdown` forward to the process's one service, over
`RipgrepFiles`, `RegexEngine` and `editor_text::is_word_character`. A
reply is a status (started, each refusal, found), words, a detail and the
paths; a found reply's words are each file's path length, source and
matches, then its end (more, complete or truncated with the counts, or the
walk's refusal). Lean resolves each overlay's `File.Source` to a handle
before it starts, so a snapshot it no longer holds is refused there and
never crosses; the bindings are `lean/Editor/Ffi/Grep.lean`.

**Limits and the deliveries** are the caller's: `project-search` asks for
200 files with a match or 2,000 matches, whichever comes first, and 200
matches a delivery (`packages/project-search/ProjectSearch.lean`). The walk is
single-threaded and sorted, so the results come in a stable order; it is
slower than `rg` on a large tree, and the parallel walker is a later
optimisation, made only on a measurement. A row of a file that is not
UTF-8, or of a UTF-16 file, is decoded or transcoded, so its offsets are
not the buffer's: Lean places the excerpts from the buffer's own text, so
only the counts can differ.

**Tests**: the port's contract on the fake and on implementations that
break it, the rule and the service on the fake, in `editor-grep`; the
contract, every match under a root with real ignore files, the walk's
order, `holds` once a row across blocks and a late NUL, on real files in a
temporary directory, in `editor-grep-ripgrep`; how a start and a reply
cross, in `editor-ffi`; and in Lean, `ffi-test`'s `grepChecks`, the job
port's `grepProperties` against the model, the fake and the real service,
and `contract-test`'s `grepChecks` and `projectSearchChecks`.

The root `clippy.toml` holds the crate's tests, the rule's and
the service's among them, to the fake: no `std::fs`, no `Path` method that
asks the disk, no clock of the machine's, and not the adapter's
constructor.

## Terminal

Decision: libghostty. Its current API, stability, build requirements and
licence have not been checked; doing so is the first step of the terminal
work, and the rest of this section assumes it provides terminal emulation
state the editor can draw itself.

- **Rust**: the pseudo-terminal, the emulator, the cell grid and
  scrollback, and drawing the grid with the editor's own renderer and
  fonts. Output never passes through Lean.
- **Lean gets**: create a terminal (command, size, owner); send input; read
  a range of the screen or scrollback as text (on demand, for evil-style
  copying and search); typed events for title changes, progress reports,
  notifications, bell and exit.
- **Key routing** is Lean. Keys arrive at the editor loop like any others,
  and the keymap decides which go to the program and which to the editor.
  In `edmacs`, routing Escape between the program and evil was the biggest
  daily friction, so "keys go to the terminal" is an explicit, visible
  state with an always-available prefix for window commands.

## Syntax

- **Rust**: tree-sitter parsing on worker threads from text snapshots,
  incremental reparse from the edit log, and running queries over a range.
  Highlights reach the display as a decoration source without passing
  through Lean.
- **Lean gets**: choose the grammar and queries for a mode; map capture
  names to faces; query results as plain rows (for text objects, outlines,
  indentation, tags).

### Syntax, as built

Built by the syntax roadmap's phase 1 (2026-11-16): the port, the
reparse off the editor thread, and the Lean interface with its model; and
by its phase 2 (2026-11-16): highlights, a mode's grammar and capture
faces ("Highlights, as built", below). The language-modes roadmap's
phase 1 (2026-11-16) made each edit deliver its incremental reparse and an
idle refresh restore exactness, gave each grammar a reparse policy, and
restated the contract to match.

**How grammars are loaded.** Two ways, both through the one adapter.

*Compiled in.* Each grammar is a crates.io
grammar crate, pinned exactly (`tree-sitter-rust` 0.24.2,
`tree-sitter-json` 0.24.8, `tree-sitter-md` 0.5.4 and
`tree-sitter-toml-ng` 0.7.0, over `tree-sitter` 0.27.2), or, for Lean,
upstream's own crate vendored unmodified under `vendor/`
(`tree-sitter-lean` 0.2.0, from `Julian/tree-sitter-lean` at `0d28e5d`,
MIT; `vendor/README.md`), whose build compiles
the generated `parser.c` (and the grammar's scanner, if it has one) with
`cc` when Cargo builds the library; the objects end up in
the editor's one Rust archive, the crate the core's build generates
from `editor-ffi` (`libeditor_rust.a`), which Lake links. Lean is vendored because no crates.io crate builds
against the pinned library: the one Lean grammar crate, `tree-sitter-lean4`,
has a normal dependency on tree-sitter 0.25, which cannot coexist with
0.27.2. The workspace excludes `vendor/`, so the copy is a path dependency
whose dev-dependencies never enter the lock, and `mise run c-fmt` leaves its
generated C alone.

*Native libraries, at run time* (the syntax-runtime-grammars roadmap's
phase 2, 2026-11-26). A grammar is registered ("Registering a grammar",
below) from a shared library (`.dylib` on macOS, `.so` on Linux) exporting
`tree_sitter_<name>`: the same generated C, linked as a library rather than
statically. This is how Emacs, Helix and Neovim load grammars. The
adapter's module `native` opens it with `libloading` (pinned `=0.8.9`, the
copy the graph already builds for `ash`, `dlib`, `khronos-egl`, `wgpu-hal`
and `x11rb`), wraps its language function with `tree-sitter-language`'s
`LanguageFn`, and checks the language's ABI version against the pinned
library's `MIN_COMPATIBLE_LANGUAGE_VERSION..=LANGUAGE_VERSION` before any
parser is made. A loaded library is never unloaded: a language, and every
parser and tree of it, points into its code. The editor never finds,
fetches or compiles a grammar: the library's path is named by the user's
config or a package (the roadmap's later phases) and handed in. `unsafe`
is denied across the adapter crate and allowed only at `native`'s three
sites, each with its reason.

Set aside, and why:

- **WebAssembly grammars**, through tree-sitter's `wasm` feature: it brings
  wasmtime, a JIT and hundreds of crates, and a `.wasm` build of each
  grammar to make or fetch. Its sandbox protects against a grammar that is
  not trusted; a native grammar is the compiled C every other editor loads,
  and parses at native speed.
- `tree-sitter-loader`, which finds grammars in directories and compiles
  their C with the machine's compiler, which the editor never does; and a
  parser of our own.

`deny.toml` bans `wasmtime` and `tree-sitter-loader` outright, and lets only
the adapter depend on tree-sitter, the grammars and `libloading`. The grammars are Rust,
for the editor's own language, JSON, which the Lean model reproduces, and
Markdown's two grammars, the inline one as an injected layer ("Injections,
indentation and text objects, as built", below).

**The port** (`crates/editor-syntax`, over `editor-text` alone) is
`Syntax`: the grammars it has, a parser for one, a parse of a snapshot
(handed an old tree that has been told every edit since, it reuses what the
edits left alone), an edit told to a tree, a query compiled or refused as a
value with its kind and offset, a query's capture names, its captures in or
around a range, a tree read as plain `Node`s in pre-order (kind, named,
field, depth, range and points, error, missing), and whether a tree has an
error or a missing node, answered without reading it out, and the reparse
policy a grammar declares (`ReparsePolicy`: `Incremental`, each round reuses
the old tree, or `Whole`, each round parses from scratch), read once by the
core. Two trees are equal when their nodes are. The tree, the parser and
the query are the implementation's own types. `fake::Parens` is the
published fake, a toy grammar of parens and atoms that reparses whole and
declares `Incremental`.

**The contract** (`editor_syntax::contract::check`, over a `Corpus` of a
grammar: texts, pieces random edits insert, a query and its names, bad
queries with their kinds, the kinds of query it ships, a query with `#set!`
settings, and the reparse policy the grammar declares) holds every
implementation to seventeen properties:
the grammar listed and opening a parser; a whole tree (the root reaches
the text's end, each node within its parent on positions with their points,
siblings in order; the root may start after the blanks that lead the text,
as tree-sitter's does); two fresh parses equal; a tree having errors
exactly when one of its nodes is an error or missing, over a corpus with
texts of both; **grammar quality** (`GRAMMAR_QUALITY`, below); queries
refused by kind; capture names in order; a range answering the whole
text's captures that overlap it; and every capture naming one of the
query's and being a node's range, in the core's order; the grammar
shipping a query of each kind the corpus lists, each compiling, and none of
another kind, and an unlisted grammar shipping none (`SHIPPED`); over the
same edits as grammar quality, the shipped highlights of an incremental
reparse of a text without errors equal to a fresh parse's
(`HIGHLIGHTS_AFTER_EDITS`); a parse in ranges reading only the ranges
(`IN_RANGES`); a range's matches, flattened, being its captures, each with
its node's named children (`MATCHES`); each pattern's `#set!` settings
(`SETTINGS`); every tree a round keeps whole, incremental trees of texts
with errors among them (`DELIVERED_WHOLE`); **convergence** (`CONVERGES`,
below); and the grammar declaring the corpus's policy, an unlisted grammar
declaring none, and the core's rounds honouring it: a `Whole` grammar's
never handed an old tree, an `Incremental` grammar's handed one after an
edit (`REPARSE_POLICY`). Each property is seen to bite on an implementation
written to break it, and each such mutant's failures are pinned exactly.
The fake passes it, and the adapter passes it for Rust, JSON, Markdown,
Markdown's inline grammar, TOML and Lean.

- **The edits** are named cases (an insert inside a token, a delete across
  lines, everything deleted, an edit at offset 0 and at the end, a CRLF,
  multibyte text, one transaction of several changes, several transactions
  pulled as one patch) and a sweep of random edit sequences from a fixed
  seed, each ended by its own inverse. Every edit goes through a real
  `Text`, and the tree is told the log's own patch, so this is where
  `Edit::input_edit` is held to tree-sitter. Each fresh parse a reparse is
  compared with is made on a parser opened for the oracle, never the run's
  own, so a parser that remembers cannot hide its own answer.
- **Grammar quality: on a text without errors, an incremental reparse
  equals a fresh parse.** A reparse is compared exactly when the fresh
  parse of its snapshot has no error or missing node, and at least one must
  be compared. How tree-sitter recovers from an error depends on what it
  reuses, and its own randomized tests compare reparses with fresh parses
  only of texts without errors: seen on 2026-11-16, 11 of some 6,700
  incremental parses of random edits of Rust differed from the fresh parse,
  every one with an error, and none of JSON. On sweeps of five times the
  contract's, from three seeds (some 23,000 reparses of Rust and JSON),
  every incremental parse with no error equalled the fresh parse. A grammar
  that fails it ships as `Whole`, promised nothing incremental: Markdown's
  inline grammar, whose reparses of texts without errors differ.
- **The eventual guarantee: incremental now, exactly a fresh parse once the
  text is quiet.** An edit's round keeps its incremental reparse, errors or
  not; once the text has gone the idle interval unchanged, the worker
  parses it whole (the refresh round, below), so the tree delivered equals
  a fresh parse. Neovim, Helix, Zed and Emacs highlight from the
  incremental tree and never check it against a fresh parse; this keeps
  their per-edit behaviour and adds exactness when the text is quiet. Until
  2026-11-16 the core instead dropped an incremental parse with an error
  and parsed the text whole, a second parse for most rounds while someone
  types. `CONVERGES` holds the core to it on the real implementation: a
  real `Session` driven round by round over the named cases and a short
  sweep, then refreshed, delivers a tree equal to a fresh parse, drawn with
  the shipped highlights as a fresh highlight draws them, and a second
  refresh delivers nothing. The criteria of the syntax roadmap's phase 1
  that said the delivered tree equals a fresh parse after every edit are
  restated here to this guarantee.

**What a range answers** is the core's rule (`query::captures_in`), so the
model and every implementation answer alike: the captures whose node
shares a byte with the range, or, when the node or the range is empty,
starts within it, its ends included; each once; by start, the longer
first, then by pattern, then by capture. A range that is not two positions
in order is refused. The port is asked about the range widened by a byte on
each side: tree-sitter leaves out a node that only touches an end of its
byte range, and answers nothing of an empty one.

**A session and the worker.** A `Session` is one text's parse state: its
grammar, its policy and parser, its `Source`, its consumers, the last tree
parsed (the base, delivered or not, and whether it is a whole parse) and
the newest revision it has been told of.

1. A round asks the source for the text as it is now and the patch since
   the base's revision, taken together under the document's lock
   (`Source::latest`, which `editor_ffi::snapshot::Source` implements over
   a snapshot's weak hold on its document's text). A text gone ends the
   session; one at the base's revision needs nothing.
2. With an `Incremental` grammar, a base and a patch that chains from it, a
   clone of the base tree is told each edit of the patch, in order, and the
   text reparsed with it, and the result is kept whatever it holds: there
   is no fallback. Otherwise (a `Whole` grammar, the first parse, a log
   that has forgotten the base's revision, a patch that does not chain) it
   is parsed whole, handed no old tree. The bytes go from the snapshot's
   chunks to the parser; parsing never passes through Lean.
3. **The delivery rule.** The result is the new base. It is delivered only
   if its revision is at least the newest the session has been told of;
   delivering moves that revision to the result's, keeps the result and
   hands it to each consumer. A result older than a revision the session
   has been told of is stale: nobody sees it, and the session is queued
   again. So the revisions delivered only grow, and repeat only for new
   injected layers at the same text or a refresh whose whole parse
   differed.
4. **The refresh round** (`Session::refresh_once`). A text that has moved
   past the base, or has none, gets an ordinary round. A base that is
   already a whole parse needs nothing. Otherwise the text is parsed whole
   and that tree becomes the base; when its nodes equal the base tree's,
   nothing is delivered and no consumer is called, and otherwise it is
   delivered at the same revision through the delivery rule (stale if a
   newer revision has been told by then, and still the next reparse's
   base). The base is compared, not the tree delivered: in this case it is
   the tree delivered, unless a stale result came between, and then the
   text has moved and it is the ordinary round. The comparison reads both
   trees' nodes, once per quiet period, on the worker. The session keeps
   the revision its delivered tree is exact for, which `Session::wait_exact`
   waits on, for tests.

The `Worker` holds a queue of sessions, each in it at most once; a touch
tells a session of a revision and queues it, and the worker takes one out
before its round, so a touch during a round queues it again. It also keeps
a pure schedule of refreshes, each a session, by an id given out once in
the process, and a deadline on a clock port of the crate's
(`editor_syntax::clock::Clock`, with a published `ManualClock`): a touch
whose revision is newer than every one the session was told of, an edit,
sets the session's refresh to the clock's reading plus the interval, in
place of any before, so an edit during the interval postpones it; a touch
at a revision told already (an attach, a change of injections) sets
nothing; and a `Whole` grammar's session is never scheduled. A queued
round runs before a refresh that is due. The loop parks with no deadline
while nothing is queued or scheduled, and until the earliest deadline
otherwise, capped at an hour; a touch, a stop and `Handle::wake` wake it.
The crate starts no thread.

**Locks.** A round holds the session's work lock (its parser and base),
which only the worker takes, and no other lock while it parses: it takes
the document's lock only inside `Source::latest`, and the session's state
lock only to deliver, or to mark the tree delivered exact. A touch takes
the registry's lock, then the session's state lock, then the worker's
queue lock, each let go before the next where it can, and never the
document's: the edit paths touch once the edit is made and the document's
lock let go. Every touch with a newer revision takes the queue lock to set
its refresh, whether or not the session is queued already: one short lock
on the editor thread, which no parse holds. There is no cycle. A consumer
is called under the session's state lock and must not call back into it.

**In `editor-ffi`** the syntax service is one process-wide registry of the
attached documents by key, the tree-sitter adapter, and one worker thread
named `syntax`, started at the first attach. Its idle interval is measured
on the job clock (`timers::Monotonic`, which implements the crate's
`Clock`) and set by Lean through `editor_ffi_syntax_refresh_after`; the
service keeps it, tells the worker of a change, and starts the worker with
it, and until Lean sets it, it is `syntax::REFRESH_AFTER_MS`, 500 ms.
Lean's default, the one users see, is its own
(`Highlight.defaultRefreshDelay`, set in config by `syntaxRefreshDelay`),
sent each time a buffer's major mode with a syntax tree is entered. Every edit path of a document
(a replace, a transaction, an inverse) touches it, and freeing a document
detaches it. A question of captures is refused as not attached for a
document not in the registry, and otherwise forwarded to the document's
session (`Session::captures`), whose rule it is, pinned on the fake: it is
answered at once from the tree the session last delivered, if that tree
is of the snapshot's revision, and is otherwise refused as not parsed, so
the editor thread never waits for a parse; the refusals are checked in the
order not attached, wrong grammar, bad range, not parsed, which the Lean
model reproduces. The wiring tests run on the process's registry, which
the edit paths reach; keys are given out once in the process, so tests in
parallel never share a session.

**In Lean**, `Editor.SyntaxTree` is a port of its own: the grammars,
attaching a text to a grammar, a query compiled, its capture names and its
captures in a range, each refusal a value. Its model knows JSON alone: a
pure parser of a subset of JSON (no escapes, no comments) that builds the
tree `tree-sitter-json` builds, and a subset of the query language that
refuses quantifiers, alternations, anchors, negated fields, predicates and
groupings as unsupported. One contract, whose exact cases are the
library's answers, holds the model and the real binding to the same
properties. It is the seventh sub-port of the editor's port
(`docs/design/lean-runtime.md`, "The editor's port is a composite").

**Registering a grammar** (the syntax-runtime-grammars roadmap's phase 1,
2026-11-26). The port registers a grammar at run time:
`Syntax::register` takes a `GrammarSource` (a native library's path, the
symbol it exports its language under, and an optional declared
`ReparsePolicy`) and answers the registered `GrammarName` or a
`RegistrationRefusal` value: not found, not loadable (no library this
platform can open), unsupported ABI, missing symbol, or unsupported (a
syntax that loads no grammar at run time, as the fake with no table; the
real adapter loads native libraries since phase 2). The source carries no grammar kind:
native libraries are the only run-time form, and a second would be a new
field.

- **The core decides** (`editor_syntax::registry::Registry`, which an
  adapter holds behind a lock and hands only its load step): the name is
  the symbol without its `tree_sitter_` prefix; the policy is the declared
  one, else `Whole`, since a loaded grammar cannot be swept for grammar
  quality when it loads; a later registration of a name replaces the
  earlier one, and a registered grammar replaces a compiled-in one of the
  same name, for parsers opened afterwards, while a parser opened before
  keeps its grammar; a refusal changes nothing; the listing is the
  compiled-in names, then the registered ones in the order first
  registered; each entry keeps its source, so the queries declared beside
  its library can be found. A registered grammar ships no query: its
  queries are read in Lean and handed in as a mode's override.
- **The worker orders it.** The registry is the syntax service's state, so
  in production a registration reaches the syntax only as a request on the
  worker's queue (`Handle::register`, with a reply called once on the
  worker's thread, and `Handle::flush_registrations`, a barrier). Each step
  answers every queued registration, in order and with no lock held, before
  its next round or refresh, so an attach made after an answer opens the
  registered grammar. When the loop ends, by a stop or a panic, every
  registration still queued is answered `None` (`editor_syntax::worker`,
  "Registrations").
- **A service behind the completion queue** (`editor-ffi`'s `grammars`):
  `editor_ffi_grammars_start` queues the registration on the syntax worker
  and returns at once; the worker's answer is kept under the request's id
  and completed from the syntax service's source (6), and
  `editor_ffi_grammars_take` hands it out once as a status, with the name
  lent when registered. A cancel withdraws the wait while the queued
  registration is still worked, and a flush is completed behind every
  registration started before it. In Lean it is a request a job awaits
  (`JobRequest.grammar`, `Grammar.register`, with its data and refusals in
  `lean/Editor/SyntaxTree/Registration.lean` beside the syntax tree
  interface), so the editor thread never waits for it and a command cannot
  make it; the runner's service is `Job.realGrammars`, its fake
  `Job.FakeGrammars` and its model the pure `GrammarRegistry`
  (`lean/Editor/SyntaxTree/Registration/Model.lean`), which the job model
  answers with and the syntax tree model lists, attaches and compiles for.
- **The fake and the contract.** `fake::Libraries` is the fake with a
  table: it "loads" grammars of the fake's shape, each with its own list
  delimiters, from an in-memory table keyed by path, and nothing touches
  the disk. The registration properties (success; the override of a
  compiled-in name, after which the name ships no query and takes the
  source's policy, not the compiled-in grammar's; the default policy; each
  refusal) are a contract of their own, `contract::registration::check`,
  separate from `contract::check`, held against the fake with its table
  and against the real adapter on its fixture library; a syntax that loads
  no grammar runs `contract::registration::check_unsupported`, as the fake
  with no table does. Each property is seen to bite on a broken
  registering syntax.
- **The real adapter loads native libraries** (phase 2, 2026-11-26;
  "How grammars are loaded", above). Its `native` module refuses in this
  order: a path that is not absolute is not found, with nothing read
  (`dlopen` would search the system's paths for a bare name); a path the
  disk says is not there is not found; any other answer of the disk, or a
  file `dlopen` will not open, is not loadable; a symbol the library does
  not export is a missing symbol; a language whose ABI version is outside
  the pinned library's range is an unsupported ABI, refused before any
  parser is made (`native::abi_supported`, pinned with version numbers).
  `register` loads before it takes the registry's lock, so nothing that
  reads the grammars waits for a `dlopen`; in the process the load runs on
  the syntax worker's thread. The library is never unloaded. The fixture
  is `crates/editor-syntax-fixture-ini`, a test-only crate whose build
  script compiles a small INI grammar of ours (generated by the tree-sitter
  CLI 0.27.2, checked in) and its fixture exports into a shared library:
  `tree_sitter_ini`, the grammar, whose name is not compiled in;
  `tree_sitter_json`, the same grammar under a compiled-in name; and
  `tree_sitter_abi_0`, a language of ABI 0. It is a build-script product,
  not a Cargo `cdylib`, because a `cdylib`'s path cannot reach another
  crate's tests on stable Cargo and a Rust `cdylib` does not export a
  static archive's C symbols. On it the adapter keeps
  `contract::registration::check`
  (`crates/editor-syntax-treesitter/tests/registration.rs`) and the syntax
  contract on the INI grammar loaded at run time
  (`tests/contract.rs`), drawn with the highlights query beside the library
  (`Corpus::highlights`, since a registered grammar ships none);
  `editor-ffi`'s `tests/grammars.rs` registers it through the C functions.
  The Lean job contract (`JobContract.grammarProperties`, over a
  `GrammarFixture`) holds the job model and the fake grammar service, each
  given the table that describes the fixture library, and the runner over
  the real service on the built library, to the same answers: the grammar
  registered under `ini` for each policy, a library not there, a missing
  symbol and ABI 0 each refused as itself. `mise run ffi-test` hands
  `contract-test` the library's path, printed by the fixture crate's
  binary.

**Code signing and a loaded grammar** (2026-11-26; shared with the rdm
task `packages-load-native-libraries-at-run-time`).

- **Today.** The app is signed ad-hoc (`codesign --force -s -`, the
  `editorApp` build, `mise run app`), without the hardened runtime, and is
  not notarized (`packaging/macos/README.txt`; `docs/design/lean-runtime.md`).
  Library validation is a protection of the hardened runtime, so it does
  not apply, and `dlopen` loads a grammar library the app did not sign.
- **Notarization** requires the hardened runtime, which turns library
  validation on. That refuses a library not signed by Apple or with the
  app's Team ID, which every package's grammar library is.
- **What notarization must add** for a package's grammar to keep loading
  with no step by the user: the `com.apple.security.cs.disable-library-validation`
  entitlement on the app, or signing each staged grammar library with the
  app's identity when the bundle or the set is built. A library built on
  the user's machine by the user's own set can be covered only by the
  entitlement.
- This phase changes no signing.

### Highlights, as built

Built by the syntax roadmap's phase 2 (2026-11-16).

**The queries ship with the grammar crates.** The port answers
`Syntax::shipped_query(grammar, QueryKind::Highlights)`: the adapter's
table holds each grammar crate's `HIGHLIGHTS_QUERY` (its
`queries/highlights.scm`), so a query is pinned with the grammar it was
written for by the same exact version, under the crate's licence, and an
update is one version bump. A vendored copy could drift from the grammar's
node types. A mode's config may give a query source of its own in place of
the shipped one. Richer third-party query sets (nvim-treesitter's,
Helix's) are set aside: their captures and predicates are written for
those editors. The fake ships `PARENS_HIGHLIGHTS`; the Lean model ships a
JSON query of its own in its query subset, since the library's uses an
alternation the model refuses.

**The highlighter and the highlight rule** (`editor_syntax::highlight`). A
`Highlighter` is a compiled query and a face, or none, for each of its
captures, which Lean's config chose; it is refused (`BadFaces`) unless
there is one entry for each capture name. The rule turns a query's
captures, in the core's order, into spans: a capture whose face is none is
dropped, so it never hides a mapped one; an empty node is dropped; of the
captures of one node the first, the earliest pattern, is kept, as
tree-sitter-highlight does; and the core's order is kept, by start and the
outer node first, so layout, which stacks spans in the order given, draws
an inner node over its outer one. `highlight::fresh` (a whole parse, the
whole text's captures and the rule) is the reference the tests compare
with.

**A language may map a capture the vocabulary lacks.** TOML's shipped
query captures booleans as `boolean`, which the face vocabulary has no face
for, so the `toml` language maps it to `syntax.constant` through its
tree's `captures`, as Rust's `true` and `false` draw (`lean/Editor/Language.lean`).
The same query's first pattern is `(bare_key) @type`, so under the
first-pattern rule every bare key, a table header's included, draws in
`syntax.type`; its `(pair (bare_key)) @property` captures the whole pair,
drawn under the key, the `=` and the value, so `syntax.property` shows only
on a pair's spaces. That is upstream's query as shipped; config may replace
it per language.

`lean` maps three captures the vocabulary lacks: `boolean` to
`syntax.constant`, `character` to `syntax.string` and `namespace` to
`syntax.module`, and maps `variable` to nothing. Upstream's
`(identifier) @variable` comes before its namespace, declaration-name,
import and field patterns, so under the first-pattern rule it would draw
every identifier in `syntax.variable` and hide them all. A capture that
draws nothing is dropped before the rule picks a node's first capture, so
with `variable` drawing nothing the later patterns win: namespace,
section and `end` names draw in `syntax.module`, declaration names in
`syntax.function`, `syntax.type` or `syntax.constructor`, and so on (the
list is in `lean/Editor/Language.lean`'s module docs); every other
identifier draws in no face, in the default ink: as the built-in theme
draws `syntax.variable`, though not the blue the Solarized themes give it. Keywords, literals and comments are unaffected. Lean's query is vendored
with its grammar, from the same upstream commit, so it cannot drift from the
grammar's node types.

**Which tree draws a snapshot** (`Session::highlights`), resolved once a
frame and fixed for it, with the tree delivered last of revision M and a
snapshot of revision N: nothing with no highlighter or no delivery; the
tree itself when M is N; when M is older, the tree carried through the
log's patch from M to N, asked of the session's `Source` (one
`Source::latest`, under the document's lock); and nothing when the text
has moved past N, the log has forgotten M, or M is newer. It takes the
session's state lock, lets it go, and then the source's: never the work
lock a parse holds, so it never waits for a parse.

**Carried through the patch, not interpolated.** A range of N is mapped
back to M (an end inside an edit's new span goes to its old start or old
end), the captures there are drawn by the rule, and each span's parts
outside every edit's old span are moved forward to N; a part inside an
edited range is dropped, so text typed since M is plain until the reparse
is delivered. Every end lands on a position of N. Set aside: editing a
clone of the delivered tree with the patch and querying it against N (Zed's
`SyntaxSnapshot::interpolate`), which draws an insertion inside a token in
the token's face, but rests on where tree-sitter's `Tree::edit` moves
nodes, a rule tree-sitter owns that the contract does not pin and the fake
does not model. Carrying is ours, exact and tested on the fake; the cost is
that typed characters are plain for one reparse.

**Asked only for what is shown.** The highlights are the text's own spans
in layout (`editor_layout::scene::TextSpans`, carried on a `TextRef`), and
layout asks a source only for the bytes of the rows it lays out, in a frame
and in the rows and move queries alike. `editor-ffi` hands layout a
document's session as those spans (`Syntaxes::spans`), from the one
function that makes a `TextRef` of a snapshot (`display::text_ref`), so a
frame and a query of one snapshot see the same spans. There is no
whole-text highlight pass on any thread.

**A delivery is reported.** The first highlighter set on a session
subscribes a consumer (`ParsedNotice`) that pushes one `EventKind::Parsed`
(tag 13) from the library's source, the syntax service's id 6, onto the
editor queue for each delivery. Lean's host hands it to its loop, which
changes no state and publishes a scene, laid out with the new tree: the
old highlights stay until then, and a file is highlighted on open with no
key pressed. An idle refresh whose whole parse differs from the tree
delivered is a delivery and reports once; one that finds no difference
reports nothing. The consumer takes only the queue's lock, under the
session's state lock, which nothing takes the other way round.

**An attach with the grammar a document has keeps its session**, its tree
and its highlighter, so a switch between two modes of one grammar does not
draw the text plain again; another grammar replaces the session and drops
the highlighter, and a detach drops both.

**The C functions** are `editor_ffi_syntax_shipped_query` (a grammar and a
kind's tag in, the source in a `RawText` with a status out) and
`editor_ffi_syntax_highlight` (a snapshot, a query and the faces in, as a
list of strings in the borrowed layout, the empty string none; a status
out: highlighted, not attached, wrong grammar, bad faces). `SyntaxQuery`
holds its query in an `Arc`, so a highlighter outlives the query's handle.
In Lean, a major mode's `syntaxTree` says the grammar, the query's source
and config's capture faces, and setting the mode attaches and highlights
its buffer's text (`lean/Editor/Highlight.lean`).

**Open questions:**

- Cancelling a parse a newer revision has overtaken, with tree-sitter's
  progress callback: a stale parse runs to its end today, and only its
  delivery is withheld.
- A pool of workers, where one thread parses every document in turn.
- A job's wait for a parse, in place of the test-only settle.
- Coalescing the `Parsed` events of a burst of deliveries: one event for
  each delivery today, bounded by the edits, each of which already
  published.
- A fallback of a capture dotted more than once to its longest mapped
  prefix (`a.b.c` to `a.b`): today it falls to its first component only.
- Highlighting again the buffers whose major mode a reload changed.
- Keeping a compiled highlights query per grammar and source across
  buffers, in place of one compiled each time a mode is set.
- Drawing typed text in its token's face before the reparse, by
  interpolating the tree (set aside above).
- Comparing a refresh's whole parse with the tree delivered without reading
  both out (tree-sitter's `changed_ranges`), to add only if the comparison
  is measured to cost.
- Coalescing an idle refresh with the next edit's round, when an edit
  arrives while the refresh parses.

### Injections, indentation and text objects, as built

Built by the syntax roadmap's phase 3 (2026-11-16).

**Where each query comes from.** The port's `QueryKind` is `Highlights`,
`Injections`, `TextObjects`, `Indents` and `Rendered`, and the adapter's
table lists, for each grammar, the queries it ships by kind. A grammar
crate's own query is used wherever it ships one, as phase 2 decided for
highlights:

| Grammar | Highlights | Injections | Text objects | Indents | Rendered |
|---|---|---|---|---|---|
| `rust` | the crate's | the crate's (a macro's or a macro rule's token tree, as Rust, its children included) | ours | ours | none |
| `json` | the crate's | none | none | none | none |
| `markdown` | ours, the crate's block query changed (below) | the crate's, of the block grammar (a fence's code in the language its info string names, and each `(inline)` node as `markdown_inline`) | none | none | ours |
| `markdown_inline` | ours, the crate's inline query changed (below) | the crate's, of the inline grammar (`html` and `latex`, which the service has not, so nothing) | none | none | ours |
| `toml` | the crate's | none | none | none | none |
| `lean` | upstream's, vendored with the grammar | none | none | none | none |

The rendered queries (`queries/markdown/rendered.scm`,
`queries/markdown_inline/rendered.scm`) are a kind of our own, as Rust's
indents and text objects are: which nodes a rendered view of Markdown reads,
its blocks, its spans and the markup it leaves out, each opening with a
comment naming the Lean module that reads it
(`lean/Editor/Markdown/Parsed.lean`). The highlights captures cannot carry
that structure: top-level blocks, table cells and rows, every delimiter to
leave out, a link's destination apart from its text. A declared grammar
reads no `rendered.scm`.

**A text parsed once** (the rich text display roadmap's phase 5).
`editor_syntax::once::parse` parses a text whole with a host grammar, finds
its layers by the injection rule over a table of languages (each a grammar,
the query its layers are answered with and its own injections query,
through `inject::Languages`), and answers each layer, the host first at
depth 0, with its query's captures over the hull of its ranges, uncut. It
keeps nothing. `editor_ffi_syntax_parse_once` is its C function: each pair
it is handed, a grammar's name and a kind, is a language answered with that
grammar's shipped query of the kind; a Markdown host asked with `Rendered`
finds its layers with the rendered injections
(`TreeSitter::rendered_injections`: the block grammar's injections and
`queries/markdown/rendered-injections.scm`, which makes each table cell an
inline layer). The shipped queries it compiles are kept process-wide by
their grammar and source, so a grammar registered over a compiled-in name,
which ships none, never meets a query of the old one. It runs on the
calling thread, the editor thread, and touches no session and no worker:
what the rendered-markdown view asks (`text-and-display.md`, "Rendered
markdown, as built").

`tree-sitter-rust` 0.24.2 ships no `indents.scm` or `textobjects.scm`, so
Rust's are this repository's (`crates/editor-syntax-treesitter/queries/rust/`,
GPL-3.0-or-later), each opening with a comment naming the Lean rule that
reads it, with nvim-treesitter's capture names so a config author can read
them. Third-party query sets are set aside for the reason phase 2 gave:
their captures and directives are written for their own editors' rules
(nvim-treesitter-textobjects' `#make-range!`, nvim's `@indent.align` with
`#set!` metadata, Helix's `#same-line?` and `@outdent`), which tree-sitter's
Rust crate does not evaluate and our rules do not read. Drift is guarded
twice: the contract's `SHIPPED` (every kind a corpus lists compiles), and
real-only Lean checks that the capture names of Rust's shipped indents and
text objects are among the names their rules read. A mode's config may
replace any of the four with a source of its own; an empty source captures
nothing, which turns that part off. The indents query's `>` is a branch
only as a generic list's closing angle bracket (`type_arguments`,
`type_parameters`), never as a comparison leading a continuation row, which
keeps that row's level (the plan review's advice; the Rust indent fixture
has such a row).

**Code being typed: `@indent.open` and `@indent.incomplete`** (language-modes
phase 3). Two capture names of Rust's indents query are ours, not
nvim's: `@indent.open`, an opening bracket the tree did not close (a bare
`{`, `(` or `[` directly in an `ERROR`, or one whose partner is `MISSING`),
which counts its row for every later row a new line opens on, and, for
`=`, for every later row an incomplete node that holds it reaches; and
`@indent.incomplete`, an `ERROR` or a node with a `MISSING` child. A
question of the indents captures that answers an incomplete node is asked
once more from its start (`Indent.widenedStart`, `lean/Editor/Indent.lean`),
so the bare brackets it holds are seen. The bound came from the code
review: `foo(1;` mid-function recovers as `(arguments (integer_literal)
(MISSING ")"))`, a node and not an `ERROR`, and with the `(` counted on
every later row `gg=G` put the function's `}` and every function after it
one level in; bounded by its `arguments`, which ends on its own row, the
rows after it keep their levels. Valid code has neither, so the fixture's
levels and the checks of them are unchanged. Spiked while planning over
`tree-sitter` 0.27.2 and `tree-sitter-rust` 0.24.2: without them,
`fn main() {` at the text's end is `(ERROR fn identifier parameters "{")`
and a new line there got level 0, and `if a {` typed inside a function
above its `}` got one level too few; with them, 26 cases all gave the
expected level, asking a cell either side of the position plus the
widening, and without the widening five of the end-of-text cases were
wrong. The indents query over a whole 4,153-row Rust file takes 4.3 ms in
tree-sitter alone, so a new line asks a narrow range and widens only
inside an error, never the whole text before it.

**A new line's level is asked before the break, so the port gains
nothing.** `RET`, `o` and `O` ask the level of the new row at the position
it opens at, of the text before the line break (`TextId.openingLevel`),
whose tree is the one delivered last. The library's rule that a structural
question is answered only of the revision whose tree is delivered last
(`Session::kept_captures`) stands; carrying the delivered tree's indents
captures through the patch to a newer revision, for a replay that types
and breaks lines in one command, is an open question
([keymaps-and-modes.md](keymaps-and-modes.md), "Open questions").

**Markdown is `tree-sitter-md`'s two grammars.** `tree-sitter-md` 0.5.4
(MIT, the tree-sitter-grammars project's, the one nvim, Helix and Zed use)
is depended on with no features: its `parser` feature only adds a wrapper
over tree-sitter the adapter does not use, and its build compiles both
grammars. The block grammar is `markdown`, of policy `Incremental`: its
6,000 reparses in a sweep on 2026-11-16 all equalled the fresh parse. The
inline grammar is `markdown_inline`, the name the block grammar's
injections query gives each `(inline)` node, so a paragraph's or a
heading's text is an injected layer drawn with the inline grammar's
captures (emphasis, code spans, links). It is of policy `Whole`: in sweeps
of random incremental reparses on 2026-11-16, 598 of 4,000, and 136 of
6,400 in a second, gave a tree other than a fresh parse's with no error in
it, so it fails `GRAMMAR_QUALITY`. A layer is parsed whole each round
anyway, so the policy changes nothing for it as a layer. The block
grammar's highlights query is the repository's,
`crates/editor-syntax-treesitter/queries/markdown/highlights.scm`
(rich-text-display phase 1, 2026-11-27): the crate's block query copied
with its provenance (tree-sitter-md 0.5.4, from nvim-treesitter) and
changed, because the crate's captures every heading as `@text.title`, with
no level, and gives a code block `@text.literal`, the name the inline
grammar gives a code span, so neither a heading's level nor a block apart
from a span could be styled. Ours captures a heading's text by its level
(`@text.heading.1` … `@text.heading.6`, a setext heading 1 or 2), a fenced
or indented code block as `@text.code-block`, a list marker as
`@text.list-marker`, a block quote as `@text.quote` and a pipe table's
header row as `@text.table-header`, and keeps the crate's other captures;
a link reference definition's title is `@text.reference`, a link, where
the crate's gives it `@text.literal`; `tests/highlights.rs` pins them. The
inline grammar's highlights query is the repository's too,
`crates/editor-syntax-treesitter/queries/markdown_inline/highlights.scm`
(the phase's code review): the crate's inline query copied with its
provenance and changed only so a link's title is `@text.reference` beside
the link's text and label, where the crate's gives it `@text.literal`, the
name of a code span, which would draw a title in the code-span face; ours
keeps `@text.literal` for a code span alone, and the crate's other
captures. The default face mapping (`Highlight.defaultFaces`, from
`Face.markupCaptures`) draws these and the inline grammar's captures in the
`text.` faces ([text-and-display.md](text-and-display.md), "The markup
faces"); `punctuation.delimiter` draws in `syntax.punctuation`. A
Markdown tree may say it has an error with no error node the walk shows (a
heading marker that ends the text); its round keeps it as it keeps any
incremental tree.

**TOML is `tree-sitter-toml-ng`'s grammar** (language-modes phase 4,
2026-11-17). `tree-sitter-toml-ng` 0.7.0 (MIT, the tree-sitter-grammars
project's, the continuation of ikatyang's original) ships a highlights
query and no other, so TOML has no injections, indents or text objects: a
TOML buffer's `=` and new lines find no indents query and add nothing. It
is of policy `Incremental`: in a sweep on 2026-11-17, 4,221 incremental
reparses of texts without errors, of random edits to the fixtures under
`tests/syntax/toml/`, all equalled a fresh parse, and its contract passes.
Since every compiled grammar is a language a layer can be injected in, a
Markdown fence whose info string is `toml` is now a TOML layer. The crates
looked at and set aside are in the adapter's `Cargo.toml`.

**Lean is upstream's grammar, vendored** (language-modes phase 5,
2026-11-17): `Julian/tree-sitter-lean` at `0d28e5d`, under `vendor/`, with
the highlights query of the same commit and no other used, so Lean has no
injections, indents or text objects. It is of policy `Incremental`: in a
sweep on 2026-11-17, 6,894 incremental reparses of texts without errors, of
random edits to the fixtures under `tests/syntax/lean/` and to the files of
`lean/Editor/` that parse without errors, all equalled a fresh parse, and
its contract passes. A Markdown fence whose info string is `lean` is now a
Lean layer. Upstream also ships an injections query, which hands doc and
module-doc comments to `markdown`; it is off (see the open questions).

**What the port gains.** `Syntax::matches` (a query's matches, each with
its captures, and each captured node's named children), `pattern_settings`
(a pattern's `#set!`s) and `parse_in` (the tree of the bytes in some ranges
only, parsed whole, nodes keeping the text's offsets and points; the
adapter sets the parser's included ranges and sets them back after). A
leaf of tree-sitter's may run from one range into the next, its lexer going
on at the next range's start, so `IN_RANGES` holds a leaf to starting and
ending in the ranges, not to lying within one; what a leaf holds of a gap is
not the layer's, and a layer's spans are cut to its ranges.

**The injection rule** (`editor_syntax::inject`). Each match of an
injections query over a tree's ranges says one injection: its language,
the text of its first `injection.language` capture, trimmed and lower-cased
in ASCII, or else its pattern's `injection.language` setting; its content,
the ranges of its `injection.content` captures, each node's named children
taken out unless the pattern sets `injection.include-children` (so a
fence's code keeps its punctuation and leaves out a block quote's `> `),
cut to the parent's ranges and made one where they touch. A match injects
nothing with no language, no range left, or a language not known: nothing
aliases a name. A layer's injection over the layer's own ranges makes no
progress and is dropped; the host's over the whole text is a layer, as the
inline text of a Markdown document that is one paragraph is. Each match is a layer of
its own; `injection.combined` is not built.

**Layers in a round.** A session's round finds the new tree's layers, and
each layer's own down to three below the host, each parsed whole in its
ranges by a parser kept for its grammar, on the worker. A tree parsed whole
equals a fresh parse with nothing to prove, and injected regions are small.
The round reads the injections and their generation once, briefly under the
state lock (nothing takes the state lock and then the work lock). When only
the injections changed, the base tree is kept and its layers found again,
and the result is delivered at the same revision when the layers differ
from the base's (by language, grammar, depth and ranges, which fix a
layer's tree); otherwise the round is up to date, a language's new faces
being read when highlights are asked. So the layers a mode's injections
find are drawn with no key pressed, and a mode set over a text with nothing
to inject reports no parse.

**Layers drawn over the host.** A snapshot's highlights are the host's
spans, then each layer's, by depth and then by start: its language's
highlighter's spans of its tree, cut to its ranges and carried through the
patch as the host's are. Layout stacks spans in the order given, so an
injected span is drawn over the host's, and where the injected language has
no face the host's shows through. The faces are one table, the host's
names then each language's, no name twice. A layer whose language is gone,
or is now of another grammar, is not drawn.

**Measured** by hand on 2026-11-16, in a release build on the owner's
machine: a round after an edit of `crates/editor-layout/src/frame.rs`
(138,437 bytes, the largest Rust file in the repository, 392 macro layers)
takes 10.0 ms at the median and 10.8 ms at most over 20 runs, under a
16 ms frame, so reusing a layer's tree across rounds stays an open
question.

**Lean, measured** by `mise run syntax-bench` on 2026-11-17, in a release
build on the owner's machine. Lean's syntax is extensible and the grammar is
a fixed approximation of it: a construct it does not know is an error node,
which the idle refresh corrects once the text is quiet. The largest Lean
file in the repository (`find lean tests -name '*.lean' -not -path
'*/.lake/*' | xargs ls -S | head -1`) was then `lean/ModelTest.lean`, before
the model tests were split into modules: 1,701,630 bytes, 30,504 lines,
1,629 error nodes. Its first parse takes 142.7 ms; a round after an edit
85.0 ms at the median and 87.6 ms at most over 20 runs; the idle refresh (a
whole parse and its compare) 208.1 ms at the median. The round is above a 16
ms frame on this test file; it runs on the worker, off the editor thread,
and the delivered spans are carried meanwhile. The largest file under
`lean/Editor/` (`Ffi.lean`, 180,989 bytes) took about 6 ms a round when the
grammar was chosen. How much of this repository's Lean the grammar parses
(2026-11-17, when it was chosen): 20 of the 52 files of `lean/Editor/` and
65 of all 172 Lean files parse with no error, and 97.5 % of `lean/Editor/`'s
non-space bytes are captured by the shipped highlights query, since an error
node's tokens are still keywords, strings and comments to it. Reusing work
across rounds for files this size is an open question, with this measurement
as its trigger.

**Kept queries.** A session keeps one query of each structural kind it is
given (`Session::keep`), and answers a kept query's names and captures in a
range from the tree delivered (`Session::kept_captures`), refused, in this
order, with `NoQuery`, `BadRange` and `NotParsed`. A structural question
before its reparse is delivered is refused, not carried as highlights are:
an indent level or a text object of a tree that lacks the latest edit would
be wrong, not stale, and the caller keeps the row's indent or finds no
object. An attach with the same grammar keeps the kept queries and the
injections; a detach, or another grammar, drops them.

**The C functions** are `editor_ffi_syntax_inject`,
`editor_ffi_syntax_inject_language` (a language's name, its highlights
query and faces, and its injections query or null),
`editor_ffi_syntax_keep`, `editor_ffi_syntax_kept_names` and
`editor_ffi_syntax_kept_captures`, each with a status of its own; a kind
crosses as a tag, 0 to 3. In Lean, entering a major mode with a syntax tree
injects, gives a language for each grammar, and keeps the text objects and
indents queries (`lean/Editor/Highlight.lean`); the indent rule
(`lean/Editor/Indent.lean`) and the text-object rule
(`packages/evil/Evil/TreeObjects.lean`) are Lean's, over plain rows.

**Open questions:**

- Reusing an injected layer's tree across rounds (measured above).
- Reusing work across rounds for a file of about 1.7 MB, whose round is
  above a frame (Lean, measured above).
- Lean's upstream injections query, which hands doc and module-doc comments
  to `markdown`: off, since each doc comment would be a Markdown layer, and
  its inline layers, parsed whole every round (`lean/Editor/` is about 65 %
  comment bytes), and doc comments already draw in `syntax.comment`.
- Language aliases for injections (`rs`, `jsonc`), and where they are
  configured.
- `injection.combined`: one layer of several matches.
- A structural question asked before its reparse is delivered: a macro or
  `.` that runs a text object right after an edit, a wait for a parse, or
  carrying.
- Text objects and indent levels inside injected layers: they are answered
  from the host tree only today.

## Built in Lean on these services

These were core services in the first design, when the core was Rust. With
Lean owning the process they are compiled Lean packages.

- **The ACP client.** JSON-RPC over a process's stdio, serving the agent's
  requests while the editor's own are pending. See
  [agent-hosting.md](agent-hosting.md).
- **Language-server clients.** Process lifetime, JSON-RPC, keeping the
  server's view of documents in sync with the edit log, request
  cancellation. Completion, hover, rename and the rest are features over
  it.
- **The code index.** Navigation queries (definitions, references, callers,
  symbols) have several possible sources: tree-sitter tags (instant,
  approximate), a language server (precise, live, slow to warm up), a
  precomputed index such as SCIP (precise, whole-repository, stale). One
  Lean interface takes a query and returns rows labelled with their source
  and freshness.
- **Version control, the rdm client, permissions, the agent table.** See
  [review-and-navigation.md](review-and-navigation.md).

If one of these turns out to need help from Rust, the fix should be a
better generic primitive, not a feature-specific service.

## Open questions

- **A long document parsed once off the editor thread.** A text parsed once
  (`editor_ffi_syntax_parse_once`) is answered on the thread that asks: a
  rendered-markdown view parses the whole document on its first render and
  then only each append's tail. A long document's first render would be
  better parsed in a job, its answer applied when it arrives.
- **Threads or an async runtime inside the library.** Lean pulls events, so
  the library needs no scheduler of its own. Plain threads and channels are
  the starting point; an async runtime (tokio) would only be justified by
  the number of open pipes.
- **JSON throughput.** Decided for ACP: an agent's stream is parsed in
  Rust, by the protocol's SDK in the ACP package's crate, which takes the
  child's stream over from the process service ("Handing a streaming child
  to a package's crate, as built"), and Lean gets plain events. A
  language server's stream is still to decide; the same hand-off, with the
  `Content-Length` framing built beside it, would let an LSP client do the
  same.
- **HTTP.** A Lean client, or a small Rust one behind the same pattern.
- **Backpressure** for a process that outpaces its consumer: answered for
  process output, which is held at its bound by not being read, and for
  watches, whose batch past its bound collapses to one missed change.
  Still open for what else a job is handed, its results and events.
- **A write while the child is held.** A job that writes to a child that is
  not reading its standard input, while the child is held at its bound
  because the job is not reading, waits in that write until it is
  cancelled: the write's reply is the truth about delivery, and nothing is
  buffered beyond the pipe. Only that job is stuck, holding no thread, and
  cancelling it kills the child. ACP agents and language servers read their
  input continuously, so the editor's own uses do not meet it; whether a
  write should time out, or be buffered up to a bound of its own, is open.
- **A descendant that leaves its process group.** The group kill reaches a
  child and every process still in its group. A descendant that calls
  `setsid` or `setpgid`, or forks into a session of its own (git's
  `fsmonitor--daemon`, ssh's ControlMaster), is not reached, and outlives
  the editor. Reaching those would take Linux's
  `PR_SET_CHILD_SUBREAPER` or a cgroup; macOS has neither. Whether such
  descendants are in scope of "no process the editor started is left
  running", and if so whether a Linux-only subreaper is acceptable, is the
  owner's to decide; phase 1 builds the group kill only. What is
  guaranteed when such a descendant keeps the child's standard output or
  error open: the editor still quits, because shutdown waits for every
  child to be reaped and its group killed, not for the streams to close;
  and a cancel ends the run once its child is reaped, the job's wait
  ending at once. The contract's escaped-descendant property shows both on
  real processes. What is not: the escaped process is not killed and
  outlives the editor; each of the run's readers stays, detached, holding
  the stream's read end until that process closes it; and a run that is
  not cancelled waits for it, so its output is whole, for as long as it
  holds the stream. Such a descendant that holds a streaming child's
  standard input and does not read it leaves the child's writer blocked in
  `write(2)`, detached, holding the input's write end.
- **A graceful signal before the kill.** Cancel and shutdown send
  `SIGKILL` to the group at once. An agent or a language server may want
  `SIGTERM` and a grace period first, to save what it holds; a grace period
  must still end in `SIGKILL`, so that shutdown cannot hang.
- **Sandboxing**: should the process service be able to run a command in a
  container or other sandbox? Worktrees are not a security boundary.
- **Remote work**: editing over SSH or in a container changes files and
  processes from local calls to a remote agent. Requests as plain data
  keep that possible; nothing more is planned.
- **In-process git**: if a process per query proves too slow for status in
  large repositories, a library can sit behind the same Lean interface.
- **A save that would lose something.** Replacing a file by a rename loses
  its other hard links, a foreign owner, the special mode bits and extended
  attributes. The usual remedy is to write in place where a rename would
  lose one, as Vim's `backupcopy` does, which gives up the guarantee that a
  crash leaves the file whole.
- **File names that are not UTF-8.** The service takes a path as bytes and
  decodes nothing, but Lean's paths are strings, so such a file cannot be
  named from Lean. The route is the text model's escapes, applied to names.
  A watch's delivery carries such a path as bytes, and Lean, until then,
  turns it into missed on the watch's own path.
- **A followed file that is a link.** A file watch is on the name in its
  directory, not on the link's target. A change of what the link holds is
  told as a change of that name; a write to the target, which may be in
  another directory, is not expected to be told. No test looks at either.
- **A watched directory that is removed** is told as removed when the
  platform says so. What follows differs: inotify's watch goes dead, and
  FSEvents goes on following the path. Not pinned by any test.
- **The inotify instance limit.** Each registration is a notify watcher of
  its own, an inotify instance and a thread on Linux, and
  `max_user_instances` (often 128) caps them across every program of the
  user. Sharing applies only to an exact directory and depth. One watcher
  for every registration, with the overlap of a tree and a directory under
  it handled in the adapter (inside one watcher, `unwatch` of one drops the
  descriptor the other uses), would lift the cap; it is not built.
- **A `stop` request**, which would end a watch before its job ends. A
  watch ends only with its job. `lean/Editor/FileWatch.lean` says where
  the request would go.
- **Presence.** A change says what happened at a path, not whether the
  path exists afterwards: a remove and a create inside one window are one
  change with both kinds, and their order is lost. A job that must know
  asks for the file; whether a delivery should say it is open.
- **A change inside the clock's granularity** that keeps the size is not
  noticed by a stamp. A content hash would notice it, at the cost of reading
  the file at every save.
- **A streamed load**, which would not hold the file's bytes whole beside
  the rope; **an override of the binary rule**; and **one slow file holding
  the file service**, whose one thread works requests in order (a thread a
  directory, or a small pool keyed by path, would keep the order that
  matters).
- **The clipboard on Wayland.** The adapter is built without arboard's
  `wayland-data-control` feature: nothing here can run a Wayland
  compositor to see it work, and it is some twenty crates. Without it a
  Wayland session's clipboard is reached through XWayland, and a session
  with no XWayland has none, which the adapter reports as a clipboard
  that cannot be opened. The alternatives looked at (`copypasta`,
  `smithay-clipboard`, `window_clipboard`) each need the window's display
  handle, which would hang the clipboard off the window adapter.
- **The primary selection, and anything on a clipboard but text.** Not
  built. They are for the command loop's clipboard interface to ask for,
  and the port then grows by an argument.
- **What a clipboard keeps once the editor has exited.** On X11 with no
  clipboard manager, nothing: the text is served by the process that
  wrote it (seen under Xvfb). Not addressed.
- **What the empty text reads back as** on macOS: the empty text, or no
  text. Not known, and the contract does not ask.
