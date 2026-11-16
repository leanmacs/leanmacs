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
  run's child has its input closed, and a streaming child's is its
  `Streaming`'s, as in Lean, where only `Process.Streaming` has one. The child's
  streams are read with a pull (`Output::read`), it is waited for
  (`Child::wait`) and killed (`Child::kill`). A program is a bare name,
  looked up on the `PATH` the child gets, or an absolute path; the
  environment is the editor's, emptied first if asked, then with variables
  unset and then set. A spawn that fails is a `Refusal`, a kind (not
  found, denied, failed, and the service's own: a relative directory, a
  relative program, shut down) and the platform's words naming the program
  and the directory. The port is pull-based and blocking, so backpressure is the core not
  reading, and a write is held by the pipe it writes to.
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
  never output cut short. An id in use is refused. Cancelling kills the
  group of a running child, drops its result and never completes it.
  Shutdown refuses every later start (as shut down, completed at once),
  cancels every run, kills every group and blocks until every child is
  reaped; it does not wait for a stream to close.
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
  Framing is plain data (`editor_process::frame`): lines split on `\n`, a
  line without its `\n` and keeping a `\r`, the bytes after the last `\n`
  a last line at the stream's end; or raw bytes, whose deliveries end to
  end are the stream. **Coalescing is the reads being pulls**: a read is
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
  ends there the line is its last, delivered whole. The last delivery carries the
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
  and drops the child's waits uncompleted; shutdown cancels every child as
  it does every run. The contract holds the port's input to three more
  properties (a write reaches `/bin/cat` byte for byte, a write to an input
  the child closed is `InputClosed`, a child spawned with no input has
  none to take) and the service to nine more, 26 in all, on real
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
  process's one service, over the real adapter, behind eleven C functions:
  a run (the command as words and one string, as a list of strings
  crosses), a take (a status, words, a detail and both streams), a cancel,
  a shutdown and a readout of what is pending; and for a streaming child an
  open (a run's words after its input and its two framings, with the bound
  for the limit), a read, a write, a close of its input, a take of a wait's
  reply (the same record as a run's result, a delivery's two streams in its
  buffers) and a readout of whether it is held, for tests. In Lean a run is
  a request of the job port (`lean/Editor/Process.lean`, `Process.run`),
  with a pure model that scripts commands; cancelling a job withdraws its
  wait, which cancels the run in the library and so kills the child. The
  headless and window mains call the shutdown before they quit the queues.

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
(`lean/Editor/Files.lean`, the command loop's phase 9;
[concurrency.md](concurrency.md), "Getting results back"): the open command
loads under a limit of 1 GiB, which is the editor's policy and a round
number with no measurement behind it, and the save command expects the
stamp the buffer holds, or whatever is there when it is forced. Nothing
reloads a buffer whose file changed on disk, and nothing follows a buffer's
file with a watch yet: a change is found when a save is asked for.

- **The port.** `editor_text::fs::Fs`, defined by `editor-text` in its own
  terms, with seven methods. `stat` says what is at a path, following links,
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
  nothing. An error is a kind the core decides on (not found, denied,
  exists, not a file, other) and the platform's words.
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
  and its size. The check is shown to bite by fifteen fakes written to
  break one rule each.
- **The adapter.** `editor-fs-std`, a crate of its own: `StdFs` over
  `std::fs`, Unix only, made by the one constructor `StdFs::system()`. A
  write is `create_new` with the permissions set on the open file, then
  synced; a rename syncs the directory and ignores a failure of that. It is
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
- **The service** (`editor-ffi`, `src/files.rs`), in the timer service's
  shape: a load or a save is started with the caller's id and returns at
  once; **one thread works the requests in the order they were started**,
  so two saves of one file land in order; one completion is queued; the
  result is then taken once by its id, as a status, a snapshot handle for a
  load, words and a detail string. Cancelling a request that waits means it
  is never worked; a save being worked reads the flag before it replaces
  the file. The statuses: done, not absolute, not found, not a file,
  denied, binary, too large, changed, no temporary name, failed.
- **How the tests are kept off the disk.** `editor-text`'s tests, and the
  service's unit tests, run on the fake. That is held by the gate, not by
  review: a `clippy.toml` beside each of the two crates lists `std::fs`,
  the disk-asking methods of `Path`, the working and temporary directory,
  `Command::new` and the adapter's constructor as disallowed
  (`editor-text`'s also the clocks), and `deny.toml` keeps `tempfile` and
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
which has no dependencies; the adapter is `crates/editor-watch-notify`; the
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
  time. The crate's `clippy.toml` refuses `std::fs`, the `Path` methods
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
  dir)`) runs 23 properties, each in a fresh subdirectory of a directory
  its caller owns, and returns the names of those that fail. Twelve are
  the port's: live on return (on 20 fresh registrations, so a race shows
  up); created; written; removed; renamed, under both paths; renamed over
  another entry; a tree's write two levels down; a subdirectory made after
  `watch` returned and a file written in it; spelled as given, for a
  directory registered through a link; independent registrations; a
  dropped registration silent (200 writes right after the drop, then a
  sentinel on a second registration); and the refusals. Eleven are the
  service's, run over `Service` on the watch and the clock the check is
  given: a file watch is told of a write, of a rename over the file, of its
  removal, of its creation, of a write after an atomic save, and of nothing
  beside it; a directory watch of each entry created, written, renamed and
  removed directly inside it, and of nothing deeper; a tree watch of a
  change in a subdirectory; five writes within a window of 300 ms arrive as
  one delivery (`COALESCED`); a cancelled watch's pending read is never
  completed; and after shutdown a start is refused and a pending read never
  completed.
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
    completed at once), cancels every watch, waits for every start in
    flight, and drops every registration; it is idempotent.
  - **A registration is never dropped, and the completion never called,
    under the service's lock.** It is taken out under the lock and dropped
    after: notify's FSEvents drop joins its run-loop thread, which may be
    in the sink waiting for that lock.
  - **Threads**: one timer thread for the service, a short-lived one for
    each start, and the adapter's for each registration.
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
  `NotifyWatch::system` is on `crates/editor-ffi/clippy.toml`'s list, with
  the static its one caller, so the unit tests run on the fake.

  | Function | Does |
  |---|---|
  | `editor_ffi_watches_start(id, words, words_len, path, path_len)` | Three words, the target (0 a file, 1 a directory's entries, 2 a directory's tree), the window in milliseconds and the bound, then the path's bytes, which must be UTF-8. False, starting nothing, for words that spell no start, a path that is not UTF-8, an id in use, or when the system refuses the start its thread |
  | `editor_ffi_watches_next(watch, wait)` | Asks for the watch's next delivery, as the wait `wait`. False for a watch that is not live, one with a read pending, or a wait id in use |
  | `editor_ffi_watches_take(wait, *mut RawWatchReply)` | Fills the record and returns true, or returns false when nothing is kept for the wait |
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
  running window to close, from any thread. It grows by data: a new thing a
  window reports is a variant of `Input`, a new thing it tells the drawer a
  variant of `Canvas`, and a new way to open it a field of `WindowOptions`.
- **What a window reports today** (`Input`): that it opened, with the
  platform's name; the focus gained or lost; a key pressed or released,
  whether it is a repeat, its logical key (a character, a named key, a dead
  key with its character, or unidentified), its physical key and the
  modifiers held, with the text it produced beside them; a step of an input
  method's composition (enabled, a preedit, a commit, disabled); the pointer
  pressed, dragged, released or wheeled, with its position, button and
  modifiers; the frame resized, with its size and scale; and a request to
  close. Named keys and physical keys are W3C UI Events names, as strings.
  The command loop fixed this shape (its phase 1) so that both roadmaps
  build on one, and the winit adapter produces all of it (the display
  pipeline's phase 5). The one option is whether composition is allowed.
- **As the winit adapter maps it.** A key's names are winit's own, which
  winit documents as the W3C values, with three exceptions written out:
  the system key is the named key `Meta` and its codes `MetaLeft` and
  `MetaRight`, and Space is the character it types. A release carries no
  text, and neither does a key whose text winit gives as a control
  character (Escape, Enter, Tab, Backspace): they are known by their
  names. The modifiers are those winit last reported, so on X11 the press
  of Control carries no `control`. A press and a release are where the
  pointer last was; a move with a button held is a drag, carrying the
  button held longest, a move with none is not reported, and being told
  the pointer is where it already was is no move at all; a wheel
  carries winit's delta, in lines or pixels, positive when the content
  moves right and down. A resize is the new size at the scale last known,
  a change of scale a resize at the size last known, and a window reports
  its size straight after it reports that it opened. Touch is not mapped.
- **Fullscreen is the system's, and asks nothing of Lean.** The window
  is made with winit's default attributes, so on macOS it has the green
  button, which puts it into the system's fullscreen on a Space of its
  own. Nothing was written for it: going in and coming out are a burst
  of resizes, and another Space is the window hidden and shown, each of
  which the window already reports and tells its drawer
  ([text-and-display.md](text-and-display.md), "The window, as built").
  The event loop is built without winit's default menu, so there is no
  menu item for it and no shortcut of one. A fullscreen command, which a
  key could be bound to, needs a request from Lean to the window; no
  request of any kind goes that way yet (`Platform` has `run` and
  `close`), and no phase builds one. Nobody has seen a window of ours in
  fullscreen ([concurrency.md](concurrency.md), "Still to verify").
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
  detail and a resize as words beside it (the table in `window.rs`), and
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
  the port is tested on it, on both sides of the Lean boundary.
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
- **The adapter** is `editor-platform-winit`, over winit, pinned exactly.
  The gate opens no window, so it covers the adapter's translation, on
  winit's own values, and its refusal to run off the main thread. winit's
  key event and its event for a change of scale cannot be built outside
  winit, so those two are translated from their parts, and the lines that
  take them apart run only in a real window. The adapter is held to the
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

## Text utilities

| Service | Notes |
|---|---|
| **Diff** | Line and word diff between two texts or snapshots, producing hunks; apply or revert a hunk. Used for gutter marks, for turning an agent's whole-file "old text / new text" into reviewable hunks, and for external reloads. |
| **Search** | Regex and literal search over a rope without copying it; project-wide search on worker threads with streamed results. |
| **Fuzzy matching** | Which candidates a pattern matches, and in what order, for a prompt's candidates and for pickers. Built: "Fuzzy matching, as built", below. |

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
  worker pool, which answers later through a snapshot that is polled;
  `frizbee`, which forgives typing errors, so a pattern with a character
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

- **Matching answers in the call, on the thread that asked.** That is the
  editor thread, inside the publish of a scene. Measured once, in a
  release build: 100,000 candidates of about 40 bytes scored in 7.4 ms.
  Each call also copies the candidates' bytes once, in Lean. The lists
  that ship are the ex names, five of them.
- **Not built**: a handle that keeps the candidates in the library, with
  the library's worker pool and a result that arrives as an event. That
  is what a list of every file in a tree wants, and what the Workers row
  of `concurrency.md` means. Nor case folding, normalisation, or
  highlighting the characters that matched.

Tests: the ranking rule on a canned scorer, and the fake and the contract,
in `editor-fuzzy`; the adapter's own cases, its limit and the port's
contract on it, in `editor-fuzzy-nucleo`; the C function's decoding and
one wiring case, in `editor-ffi`. No test pins a score's value.

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

- **Threads or an async runtime inside the library.** Lean pulls events, so
  the library needs no scheduler of its own. Plain threads and channels are
  the starting point; an async runtime (tokio) would only be justified by
  the number of open pipes.
- **JSON throughput.** Agent and language-server streams are parsed in
  Lean. If that proves slow, framing already happens in Rust and parsing
  could move there, delivering plain values.
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
