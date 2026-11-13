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

## Files and watching

| Service | Where | Notes |
|---|---|---|
| **Load a file into a rope, save a rope** | Rust | Bytes go straight between disk and the rope. Saves are atomic (temporary file, then rename). Invalid bytes and line endings are preserved. |
| **Small reads and writes, stat, list, rename, remove** | Lean | Lean's own file functions, called from jobs on a dedicated thread, behind the editor's file interface. |
| **Watching** | Rust | Watch a path or tree; events debounced and coalesced. |

As built, loading and saving are whole: the port, its adapter, the logic and
the service behind the completion queue, here, and in Lean the bindings and
the job interface's file requests, which a job awaits
([lean-runtime.md](lean-runtime.md), "Interfaces and models";
[concurrency.md](concurrency.md), "Sharing state", says how a job names a
snapshot). Lean's own interface for small reads and writes, and watching,
are not built.

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

What is built of the window is a first slice, enough to check that the
keyboard reaches Lean:

- **The port** is `editor-platform`'s `Platform`: `run` opens a window as
  its options say and runs it on the calling thread until it is closed,
  handing each thing the window reports to its caller; `close` asks a
  running window to close, from any thread. It grows by data: a new thing a
  window reports is a variant of `Input`, and a new way to open it a field
  of `WindowOptions`.
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
  build on one; the winit adapter maps only a dead key and a bare press so
  far, and producing the rest from winit is the display pipeline's (its
  phase 5). There is no redraw yet. The one option is whether composition
  is allowed.
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
  script, and waits for a close. It records the options it was run with, and
  leaves the composition steps out when composition is not allowed.
  Everything above the port is tested on it, on both sides of the Lean
  boundary.
- **The contract** (`editor_platform::contract`): `Opened` is the first
  input and names the platform; a close from another thread ends the run
  within a bound; nothing is reported once the run has returned; a close
  with no window running is harmless. The check asks for a close before the
  run and then leaves the open window alone for a settling time, so a run
  that an earlier close ends returns with no close asked of it and is
  refused. It is shown to refuse platforms that break each rule.
- **The adapter** is `editor-platform-winit`, over winit, pinned exactly.
  The gate opens no window, so it covers the adapter's translation and its
  refusal to run off the main thread. The adapter is held to the contract by
  an example binary that `mise run linux-window` runs under Xvfb in a
  container and `mise run window-contract` on a desktop.
- **Onto the queue**: `editor-ffi` runs a platform and pushes each input as
  an event from the window source, stamped with the reading of an input
  clock when the window reported it (`crates/editor-ffi/src/window.rs` has
  the table). The window is run by the main-thread service
  ([lean-runtime.md](lean-runtime.md), "Start-up and shutdown").

## Text utilities

| Service | Notes |
|---|---|
| **Diff** | Line and word diff between two texts or snapshots, producing hunks; apply or revert a hunk. Used for gutter marks, for turning an agent's whole-file "old text / new text" into reviewable hunks, and for external reloads. |
| **Search** | Regex and literal search over a rope without copying it; project-wide search on worker threads with streamed results. |
| **Fuzzy matching** | Scoring candidates against a query, for pickers. |

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
- **Backpressure** for a process that outpaces its consumer.
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
- **A change inside the clock's granularity** that keeps the size is not
  noticed by a stamp. A content hash would notice it, at the cost of reading
  the file at every save.
- **A streamed load**, which would not hold the file's bytes whole beside
  the rope; **an override of the binary rule**; and **one slow file holding
  the file service**, whose one thread works requests in order (a thread a
  directory, or a small pool keyed by path, would keep the order that
  matters).
