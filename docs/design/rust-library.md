# The Rust library

What the Rust library provides to the Lean editor, and what the editor
gets from Lean's own runtime instead. The test of this list is whether
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

## What Lean's runtime provides directly

| Service | Notes |
|---|---|
| **Timers and clock** | Lean's async timers. The current time is read through an interface, so tests control it. |
| **Sockets** | TCP, UDP and DNS from Lean's async library: a local listener for agent hook callbacks, and client connections. |
| **JSON** | Lean's own JSON library. Most external tools speak it. |

HTTP with streamed responses (some agents expose it) has no Lean library
that has been checked; see open questions.

## Platform

| Service | Notes |
|---|---|
| **Window and input** | Key, mouse, IME, resize and focus events on the editor queue. |
| **Clipboard** | Read and write. |
| **Notifications** | Post a desktop notification; request attention on the window; keep the machine awake while agents work. |

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
