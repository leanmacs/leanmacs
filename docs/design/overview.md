# Overview

## What this is

An Emacs-style editor written in Lean 4. The editor is a Lean program: it
owns the process, the editor state, the command loop and every feature. A
Rust library gives it what Lean is not suited to: text storage, layout,
text shaping, GPU rendering, the window, and process and terminal
management. Emacs has the same shape, with Lisp over a C core.

The editor's own code is compiled Lean. User config is Lean source,
elaborated and run inside the same process, and reloaded live. Compiled code
and config share one runtime and one set of values.

Three things it should be unusually good at:

1. **Working with coding agents**: dispatching them, talking to them, and
   above all reviewing what they produce (plans and code).
2. **Understanding a codebase you did not write**, which is the normal case
   when agents write most of it.
3. **Text rendering** on a par with Emacs (mixed fonts and sizes, inline
   blocks, overlays, bidirectional text) while staying light and responsive.

The research behind (1) and (2) points at one conclusion: dispatching agents
is a solved surface that many tools ship, and the bottleneck is human review
attention. The editor's distinctive value is evidence at review time: which
agent step wrote each edit, comment anchors that survive edits, and views
that bring a plan step, its hunks and the transcript together. An editor
that owns the buffer, the edit log and the renderer can provide these. (The
studies behind this conclusion are few and small; see the research report.)

## Principles

- **Lean decides, Rust executes.** Lean holds the editor's state and makes
  every decision. Rust stores text, lays it out, draws it and runs
  processes, as told.
- **Calls go one way.** Lean calls Rust. Rust never calls Lean: it queues
  events and Lean pulls them. This keeps Lean's runtime the only one that
  schedules editor code.
- **Rust state is reached through handles.** A rope, a terminal or a process
  is a Rust object that Lean holds a reference to. Everything else that
  crosses is plain data.
- **Nothing blocks the window.** Input, painting and the platform event loop
  never wait on Lean code, a subprocess or the filesystem.
- **Ports and adapters on both sides, hand-written fakes** (`AGENTS.md`).
  The Lean editor reaches the Rust library through interfaces it defines,
  each with a pure Lean model. The Rust library reaches fonts, the GPU and
  the operating system through traits, each with a fake.
- **State is data with one writer and one change event.** The parts of the
  `edmacs` agent tooling that survived every rewrite had this shape; the
  parts that were deleted tied identity to windows.
- **No ambient context.** Every event names its subject (which buffer, which
  view, which agent). There is no "current buffer" a handler reads implicitly.

## Where the line falls

Something belongs in the Rust library if any of these holds:

1. It does work per frame, per byte of a stream, or over a whole document:
   layout, shaping, drawing, terminal emulation, parsing, diff, search.
2. It owns an operating-system resource whose lifetime has to be managed:
   the window, the GPU, child processes, pseudo-terminals, file watches.
3. A mature native library already does it: tree-sitter, libghostty, Parley.

Otherwise it is Lean. Within Lean, code is compiled into the executable when
the editor must work without it being loaded from config (the command loop,
default keymaps, evil, the minibuffer) or when it is hot. Everything else
can be interpreted and live-reloaded.

| Component | Where | Why |
|---|---|---|
| Rope, transactions, anchors, kept inverses, edit log, loading a file into a rope and saving one | Rust | Test 1: layout and parsing read them without going through Lean. The inverse of each transaction holds the bytes it removed, which stay in the library, and a file's bytes go between the disk and the rope without passing through Lean |
| Motion primitives: from a position, the next and the previous cell, the starts and ends of words and WORDs, the start, the end and the first non-blank of a line, the ends of the text, and rows up or down at a column; reading one row or a range | Rust | Test 1: a motion walks the rope from the position, so it is as fast on a large file as on a small one, and nothing copies the text out to scan it |
| Which key runs which motion, and every evil rule about one: a count as repetition, the wanted column, keeping a normal-state cursor on its line and off the line break, `cw` and `dw` at a line's end, a motion's type for an operator | Lean, compiled, overridable from config | Policy: each is a composition of the primitives |
| The undo tree, and every undo policy (groups, branches, reverting, the saved state) | Lean, compiled | Policy: a history is a few numbers a node, moved by two requests of the library (apply the inverse of a run of revisions, drop kept inverses); other undo styles are written over the same primitives |
| Buffers, windows, views, modes (the editor's state) | Lean, compiled | The editor |
| The command loop, keymap lookup, self-insert | Lean, compiled | Measured at 6 to 12 µs from key to edit, so there is no reason to split it |
| Commands, keymap contents, evil, the minibuffer | Lean, compiled, overridable from config | Policy |
| Layout, shaping, rendering, the window | Rust | Tests 1 and 2 |
| Faces, themes, decorations (as data) | Lean | Policy. Merging the faces over a run into one font and one paint is layout's, in Rust: it is layout policy, and Lean sends definitions, not resolved runs |
| Terminal emulation, pseudo-terminal, grid drawing | Rust | Tests 1, 2 and 3 |
| Terminal lifecycle, key routing | Lean | Policy |
| Processes, pseudo-terminals, file watching | Rust | Test 2: Lean's own process handling leaves orphans and zombies |
| Timers | Rust, a service behind the completion queue | Every wait of a job then completes one way, the clock is one port with one fake a test can move, and the completion pump is proven before processes depend on it. Lean's own timers (`Std.Async`) run on a loop thread of their own, with no clock a test controls |
| Sockets, small file reads and writes | Lean | Lean's runtime already provides them |
| Text diff, search, fuzzy matching | Rust | Test 1. Fuzzy matching is built: a library behind a port, asked in one call that answers on the thread that asked (`rust-library.md`, "Fuzzy matching, as built"). A list longer than `Loop.inlineMatches` is matched as a job of the loop's own on Lean's task pool, by the same stateless call answered as a request of the job port; nucleo's own worker was considered and rejected (`rust-library.md`, "Fuzzy matching, as built", has why). Search within a text is built the same way: a regex library behind a port of its own, over a snapshot's pieces and copying no text, asked by the text port's `search` and `matches` (`rust-library.md`, "Search, as built"). Project-wide search is not built |
| Tree-sitter parsing and queries | Rust | Tests 1 and 3 |
| ACP and language-server clients | Lean, compiled, over the process service | Lean has real concurrency and JSON; the protocol rules are types |
| Agent table, permission policy, transcript views | Lean | Policy |
| Version control, the rdm client | Lean | Request and response at human speed |
| Jobs, cancellation, owner-scoped lifetimes | Lean | Built on Lean's tasks and promises, not on its async library; see [concurrency.md](concurrency.md) |

## Rules of the boundary

These follow from the principles and hold for every change. Each names
what not to add.

- **Calls go one way.** Lean calls the Rust library. Rust never calls Lean:
  it queues events and Lean pulls them. Don't add a callback from Rust into
  Lean.
- **One crate knows about Lean.** `editor-ffi` exposes the C functions Lean
  binds to. Every other crate is ordinary Rust, built and tested with
  `cargo` alone.
- **What crosses the boundary** is a handle to a Rust object (a rope, a
  process, a terminal), wrapped on the Lean side as an external object with
  a finaliser, or plain data (strings, numbers, structures of them). Never
  a Lean closure or a pointer into Lean's heap.
- **The Lean editor reaches the library through interfaces it defines**, not
  through the bindings directly. Each interface has the real binding and a
  pure Lean model. Editor logic is tested in Lean, run by Lake, against the
  models, with no Rust build.
- **A contract check per interface** runs the same properties against the
  model and the real binding, so the model cannot drift from the library.
- **Commands and jobs are different types.** A command (`EditorM`) may
  change editor state and may not block. A job (`JobM`) may block or await
  and may not change editor state. Don't add an operation that crosses that
  line; see [concurrency.md](concurrency.md).
- **Child processes belong to the Rust process service.** Don't spawn them
  with Lean's `IO.Process`: it never kills or reaps them.
- **An exception from the interpreter ends the process.** A C++ exception
  that Lean's interpreter throws inside a call from compiled Lean into
  interpreted config (a stack overflow, a missing native symbol) is not
  caught, and the process aborts: state cannot be restored cleanly once
  compiled frames are skipped. Don't add a guard, a terminate or signal
  handler, or a C++ source to the glue to catch it; see
  [lean-runtime.md](lean-runtime.md).
- **Config is elaborated behind a port.** `Editor/Config/Elaborate.lean` is
  the only module that imports Lean's elaborator. The config session's
  decisions are plain Lean, tested by `lake test` on fakes, with no
  elaborator.
- **Only modules of the package go under `lean/`.** lean-fmt compiles every
  `.lean` file there. Config fixtures live under `tests/`, and tests write
  their chunks from strings.

## Component map

```
 ┌──────────────────────────────────────────────────────────────┐
 │ Lean (owns the process)                                      │
 │  user config (interpreted, live-reloaded)                    │
 │  evil · modes · keymaps · themes · minibuffer · ex line      │
 │  agents · review · version control · navigation · rdm        │
 │  ACP and language-server clients                             │
 │  editor state · command loop · jobs · config session         │
 │  projects · workspaces · locations                           │
 │  interfaces to the library (real bindings | pure models)     │
 └───────────────┬──────────────────────────────▲───────────────┘
                 │ calls (handles, plain data)  │ events, pulled
 ┌───────────────▼──────────────────────────────┴───────────────┐
 │ Rust library                                                 │
 │  text · edit log · anchors · excerpts      event queue       │
 │  layout · decorations · views (text, grid)                   │
 │  processes · pseudo-terminals · watching   terminal · syntax │
 │  diff · search · fuzzy matching                              │
 └──────┬───────────────────────┬───────────────────────┬───────┘
        ▼                       ▼                       ▼
 platform (winit)         render (wgpu)        child processes
```

## Layout of the code

Rust crates:

| Crate | Contents |
|---|---|
| `editor-text` | Rope, transactions, anchors, kept inverses, edit log, diff. Pure. Built so far: a text over a rope (`ropey`, behind one private module), its revision, snapshots that never change and are shared between threads, positions as byte offsets with rows and points in bytes, in UTF-16 and in cells, and the bytes of a file in and out with invalid bytes kept; change sets that apply, compose, invert and map a position; transactions, applied all or nothing; and the edit log, with pulled coalesced patches, an origin for each entry, a trace from a range to the entries that wrote it, and forgetting; anchors, the markers a text holds and moves with every transaction, selections with a shape, kept sorted and merged, and what a selection covers; the motion primitives, each a walk of the rope from a position by cells, words, WORDs, lines and rows, and reads of one row and of a range; and the kept inverse of every applied transaction, the inverse of a run of revisions applied as one transaction where the text is in the state the run ended in, and dropping kept inverses; a text made from a snapshot; and files: the file port `Fs`, with its published fake and its contract, and loading a file into a text and saving a snapshot over that port, by a temporary file and a rename, refused when the file on disk is not the one expected. It does no I/O of its own. The undo tree is not here: it is Lean (`Editor.UndoTree`). The line diff is `editor-diff`'s, and a word diff is planned. |
| `editor-fs-std` | The file port's real adapter, over `std::fs`, Unix only. It is a crate of its own so that `editor-text` does no I/O, and so that the adapter's tests are its own: the port's contract in a temporary directory, and how it names the system's errors. Only `editor-ffi` depends on it. |
| `editor-layout` | Layout, pure, over a `Shaper` port it defines, with the port's published fake (`CellShaper`, one glyph per character, a cell per family scaled by a font's size) and contract. A font is named to the port by a spec: family, size, weight, slant, line height. A glyph names the resolved font it is drawn in, an entry of the shaper's table, and carries the offset its outline is drawn at. Built so far: the scene as Rust data, with the definitions of the faces it names; faces, sets of optional attributes, and the precedence by which the faces over a run merge into one font and one paint; a scale it is told (`Layout::set_scale`, 1 until then), by which it multiplies a face's lengths, which are logical points, as it asks the shaper for a font, so that a spec the port sees, a frame and the queries' answers are physical pixels; the display-layer contract with the tab layer (tabs expanded before shaping; long rows cut into segments) and the wrap layer (the per-text store of laid-out segments); decoration sources (selections, the scene's decorations, and a text's own spans, a syntax's highlights, asked through the `TextSpans` port a `TextRef` carries, lowest, in frames and queries alike, with the port's published fake `FixedSpans` and contract) merged into runs, lowest layer first; per-segment layout cached and moved through the edit log's patches, rebuilt when a patch is refused, estimated where not laid out; the cells of each visual line, by which positions, cursors and selections are found in any glyph order; the two layout queries; the frame, an immutable value of resolved paints and font ids with a content hash per row, which carries the shaper's table of resolved fonts and its generation, and a view's status fields as one row at its bottom, each on its side, left from the row's start and right ending at its end, with its padding in a box of its face's background, the left side cut where the right begins when both do not fit, and the row as tall as the mode line's line and its vertical padding; and counters of the work. It depends on `editor-text` for snapshots, patches and selections. |
| `editor-shape-parley` | The `Shaper` port's real adapter, over Parley and fontique, both pinned exactly; no type of either is public. Built: a font set, of given files as bytes or of the system's fonts; the shaper, one Parley layout for each segment shaped, kept and broken again at another width, with font fallback, ligatures, bidirectional text in visual order and mixed families; the resolved fonts it draws in, described for a rasteriser. Its tests run on the fixture fonts under `tests/fonts` and hold it to the port's contract. It depends on `editor-layout` alone. `editor-ffi` depends on it: the display of Lean's window mode is laid out over the system's fonts with it. |
| `editor-render` | The `Renderer` port, with what every back end shares, over `editor-layout` alone. The port is one method: a frame and a target in, what drawing it cost out. Beside it: the port's published fake (`RecordingRenderer`) and its contract; the mailbox frames arrive through, where a newer frame replaces one not yet drawn; the scheduler, a pure function of the demands and the time; the rule for which rows of a frame are built again; the frame journal and the counters; the loop that ties them together, with the handle other threads reach it through, which only leaves word (a frame, a dirty mark, a size, a refresh interval, hidden or shown, stop); and time and waiting as ports, each with a fake. A target that is hidden is not drawn on. It has no real clock and starts no thread: `editor-ffi` lends it the clock that stamps input and starts its thread. It is a crate of its own for the reasons `editor-platform` is. |
| `editor-render-wgpu` | The `Renderer` port's real adapters, over one painter of our own: a frame to quads, with a glyph atlas (packed by `etagere`), a glyph cache with a bound, and glyph images rasterised by `swash`. `HeadlessRenderer` lays the quads over a picture in memory on the CPU and needs no GPU; `WgpuRenderer` draws them with `wgpu`, to a target of its own or to a window's surface, which it presents. The window reaches it as the window port's `NativeWindow`, the one type of `editor-platform` it uses, and what is decided about a surface is in one module that makes no call of wgpu's, behind a port of two calls: the handles wgpu is given, the format, the present mode, when the surface is configured, what is done when it gives no texture, and how its picture is read. All four libraries are pinned exactly and none is public. The gate compares the headless adapter's picture of one frame of real text with a reference image, and runs the wgpu adapter on wgpu's no-op back end, which presents to no surface; a real GPU's picture, and a window's, are compared on demand. `editor-ffi` depends on it: the process's window draws with `WgpuRenderer`, and the headless mode's `--render` with `HeadlessRenderer`. |
| `editor-platform-winit` | The window port's real adapter: it opens one window with winit, on the process's main thread, and translates what winit says of it into the window port's inputs and into what the port tells whatever draws in the window. The translation is pure and tested on winit's values: a key's names (W3C names, which winit 0.31 takes from keyboard-types), its text, the modifiers winit last reported, the pointer's position and buttons, the size and scale, the native handles, after which events the display is asked for its refresh rate, and after which the window is read for whether it is in fullscreen (a resize, a change of scale, a move, an occlusion). It carries out requests on the main thread, taken off a channel of its own when the loop is woken, by a pure translation that runs the port's request contract. On macOS it receives the files the system asks the app to open (Finder's "Open With", the Dock), through an application delegate of its own over objc2 (pinned exactly, at the versions winit already resolves to), and holds them until the window has opened. The same delegate answers the system's quit (Command-Q, the Dock, a logout) with `NSTerminateLater` and hands it on, and a pure module (`terminate.rs`) decides what is reported and when AppKit is answered: `QuitRequested` once, a reply of `NO` on `KeepRunning`, and of `YES` on a close, after which AppKit ends the process. On macOS it also builds the menu bar the editor asks for (`Request::Menu`), from a pure plan (`menu.rs`) that decides every selector, tag, key equivalent and role, and reports a command item chosen as `Input::Menu` through a target object of its own (`menu_bar.rs`). That delegate, the menu bar and the reading of the window's corners (`corner.rs`) are the only library code in the workspace that names AppKit. Its loop waits for events and it never asks for a redraw. No winit or objc2 type is public. |
| `editor-platform-arboard` | The clipboard port's real adapter, over arboard, pinned exactly, text only. It needs no window. It keeps one clipboard for its life, since on X11 the text is served by the process that wrote it, and reads a clipboard that holds no text as no text. No arboard type is public, and no test opens a clipboard: its run of the port's contract is an example, on demand. `editor-ffi` depends on it, for the clipboard handle Lean's window mode opens. |
| `editor-fuzzy` | Fuzzy matching, with no dependencies: the `Scorer` port, which a matching library fills, its published fake (`InOrder`) and its contract, and `rank`, the rule that orders the candidates a pattern matches: one that is the pattern first, then by score, then in the order they came. Which candidates match is one rule, the pattern's scalar values in order with case kept, so that the Lean model agrees with the library on every input. |
| `editor-fuzzy-nucleo` | The `Scorer` port's real adapter, over `nucleo-matcher`, pinned exactly. It keeps one matcher and scores with one fuzzy atom, with case kept, nothing normalised and no pattern syntax. No nucleo type is public. Its tests hold it to the port's contract. |
| `editor-diff` | A line diff of two texts as an edit script, with no dependencies: the `LineDiff` port, which a diff library fills, its published fake (`Lcs`, a textbook LCS of lines) and its contract, and the core round it: the common head and tail lines stripped in linear time, the engine asked about the middle only within a line limit (over it the middle is one hunk), the engine's hunks checked, each hunk trimmed to the longest common prefix and suffix that end on a character boundary, and the steps (retain, delete, insert a range of the new text) that walk both texts. A reload of a file applies the script it makes. |
| `editor-diff-imara` | The `LineDiff` port's real adapter, over imara-diff's histogram diff, pinned exactly. No imara type is public. Its tests hold it to the port's contract. Only `editor-ffi` depends on it. |
| `editor-platform` | The platform's ports, with no dependencies. The window port: what a window reports (`Input`), what it tells whatever draws in it (`Canvas`, with the window as the system knows it as plain data, `NativeWindow`), how it is opened (`WindowOptions`), what it is asked (`Request`: enter or leave fullscreen, minimise, a title, keep running, the menu bar as plain data, `menu`), the `Platform` trait, its published fake (`ScriptedPlatform`, which records what it is asked) and its contract, with the request contract held against the fake's pure model (`contract::requests`). The clipboard port (`clipboard`): text in and out, a fake that keeps it in memory, and a contract. It is a crate of its own because a fake and a contract belong to their port's owner, and nothing may depend on `editor-ffi`. A key carries its logical key, its physical key (W3C UI Events names) and its modifiers; a pointer its action, position, button and modifiers; a resize the size, the scale and whether the window is in fullscreen; files to open their absolute paths, in the system's order, always after the window opened. The command loop fixed that shape, and the winit adapter produces it. |
| `editor-process` | Child processes, with no dependencies: the `Processes` port, its published fake (`FakeProcesses`) and its contract, framing (`frame`), and the service above the port (`Service`). The port spawns a command (a program, its arguments, an environment and an absolute directory) as a child leading a process group of its own, with both output streams piped and its standard input closed or, when the spawn asks (`Input::Pipe`), piped and taken as a `ChildInput`, which writes bytes and closes; a child's streams are read with a pull, it is waited for, which ends what is left of its group and reaps it, and it is killed with its whole group. Framing is plain data, for each stream on its own: lines split on `\n`, or raw bytes; and the bound, how many bytes of the stream may have been read and not taken, a line in progress among them. The service runs a command to its end and keeps its exit and both streams, completed through a closure it is given; a command that cannot start is a refusal, a value; a cancel kills the child's group; shutdown kills every group and returns once every child is reaped. It also opens a streaming child, with its input piped or closed and each output stream's framing and bound; then each read, write and close is a wait, completed once through the same closure, whose reply is taken once. A read is a pull, completed by the first reader that makes something deliverable and drained when it is taken, so a job gets at most one delivery a completion-queue turn however fast its child writes. A stream at its bound is not read, so the child is held in its write until a take makes room, with nothing dropped; a line longer than the bound ends the child, its group killed. A write completes once every byte is in the pipe, and is input closed once the child has closed its input or ended. The last delivery carries the exit. It is beside the port, not in `editor-ffi`, so that the contract drives its cancelling, its shutdown and its streams on the real adapter. A descendant that leaves the group is not reached. |
| `editor-process-std` | The process port's real adapter, over `std::process` and rustix, pinned exactly, Unix only: std has neither a wait that does not reap nor a group kill. A write to a child's input never raises `SIGPIPE`, by two calls of `libc`, pinned exactly, that rustix lacks. A child leads a new group; its wait sees the exit without reaping it, kills the group and only then reaps, so no signal reaches a group id that may have been reused. No rustix type is public. It is a crate of its own so that `editor-process` starts no process, and so that the adapter's tests are its own: the port's contract, the service's properties among them, on real processes in a temporary directory, and how it names the system's errors. Only `editor-ffi` depends on it. |
| `editor-watch` | File watching, with no dependencies: the `Watch` port, its published fake (`FakeWatch`, a file system in memory and the registrations on it) and its contract, the coalescing rule (`batch`), a clock of its own with a manual one for tests, and the service above the port (`Service`). The port registers a directory, its entries or its whole tree, and tells each change to a sink as a path and a kind (created, written, renamed, removed, missed); dropping the registration ends it, and once the drop returns the sink is never called again. The coalescing rule is pure: one change a path, a set of kinds, a fixed window from the batch's first notice, and a bound of distinct paths past which the batch is one change, missed, on the watch's path. The service watches a file through the directory it is in, shares one registration among the watches of one directory and depth, and delivers a watch's changes a read at a time, each completed once through a closure it is given and drained when it is taken. It is beside the port, not in `editor-ffi`, so that the contract drives it on the real adapter. Its tests run on the fake and the manual clock. |
| `editor-watch-notify` | The watch port's real adapter, over `notify`, pinned exactly: inotify on Linux, FSEvents on macOS. Each registration is a notify watcher of its own, so registrations are independent; a path is spelled as the caller gave it, though FSEvents reports it canonical; and a gate keeps a dropped registration's sink silent. No notify type is public. It is a crate of its own so that `editor-watch` watches no file, and so that the adapter's tests are its own: the port's contract, the service's properties among them, on real files in a temporary directory. Only `editor-ffi` depends on it. |
| `editor-proc` | The pseudo-terminal service. Planned. |
| `editor-ffi` | The static library Lean links: the C functions Lean calls, handles, the event queues, the timer service, the first service behind the completion queue, the file service, the second, which loads, saves and reads a file's stamp on one thread of its own over the file port and is what the job runner's file port is bound to, the process service, the third, which is `editor-process`'s service over `editor-process-std`, runs a child to its end, and opens, reads, writes and closes the input of a streaming child, and is what the job runner's process port is bound to, through eleven C functions (a run, a take, a cancel, a shutdown and a readout of what is pending, and for a streaming child an open, a read, a write, a close of its input, a take of a wait's reply and a readout, for tests, of whether it is held), a cancelled job's run or child killing the child's group, and which the editor's mains shut down before they quit, so that every child is reaped, the watch service, the fourth, which is `editor-watch`'s service over `editor-watch-notify` on the job clock, watches a file or a directory and delivers its changes a read at a time, and is what the job runner's file-watch port is bound to, through six C functions (a start, a read, a take, a cancel, a shutdown and a readout of what is pending), and which the mains shut down after the process service, the diff service, the fifth, which makes `editor-diff`'s edit script of two snapshots over `editor-diff-imara` on a thread of its own and is what the job runner's diff port is bound to, through four C functions (a start, a take, a cancel and a readout of what is pending), and the main-thread service, which runs a platform's window onto the editor queue. On that arrival path it raises the interrupt flag, a count it keeps, for a press of the key Lean set, and marks that key's event; Lean asks the flag and lowers it. Two of its handles are text: a document, which is an `editor-text` text behind a lock, made from a string or from a snapshot, and a snapshot, of a document or of a file the file service loaded. A document applies a transaction, applies an edit script as one transaction unless it has moved past the script's revision, taking what it puts in from a snapshot rope to rope, answers for its edit log, holds markers, applies the inverse of a run of its revisions and drops kept inverses, and a snapshot says what a selection covers; those are lists, which cross the boundary as words, a buffer of 64-bit numbers. A document has a key, and a snapshot of it carries the key and reaches the document's log and markers. A third handle is the display: `editor-layout` over its fake shaper (the cells display) or over Parley on the system's fonts (the window mode's), which takes a published scene (words, one string and a list of snapshot handles, with the definitions of its faces in the same words when they changed), keeps the latest frame, and answers the two layout queries. It also starts the render thread: `render` holds the session that makes a renderer when a window opens, runs `editor-render`'s loop on a thread of its own with the clock that stamps input, turns what the window tells into words left with the loop, and ends the thread when the window closes. The session is generic over what makes the renderer. A display bound to the process's presenter submits each frame it lays out to the render loop the presenter targets, stamped with the window input it answers, at the scale the window said: the process's window draws with the wgpu renderer, and the headless mode's `--render` session with the CPU renderer. The journal, the counters, whether the loop is at rest and what the window's surface offered are read through C functions, after the window has closed too. A fourth handle is a clipboard, the port's memory clipboard or the desktop's over arboard. One function ranks candidates against a pattern, over `editor-fuzzy` and its nucleo adapter, made for the call and kept nowhere: a list of strings in, as words and one string, and the indices of the matches out. It is called from whichever thread asks, the editor thread or a pool thread, and keeps nothing, so that is safe. The syntax service parses each document attached to it with a grammar, on a worker thread of its own started at the first attach, over `editor-syntax`'s worker and the tree-sitter adapter; every edit path of a document tells it of the edit, and freeing the document detaches it. Its C functions list the grammars, attach and detach a document through a snapshot of it, make and free a query (a fifth handle), list a query's capture names, answer its captures in a range of a snapshot from the tree delivered of that snapshot's revision, answer the query a grammar ships, highlight a document with a query in faces, give a document its injections and the languages they may name, keep a query of a structural kind and answer its captures, and, for tests, wait for a delivery. A highlighted document's session is handed to layout as its text's own spans whenever a snapshot of it is laid out, so highlights reach the display without passing through Lean, and each delivery of its parse is reported as a `Parsed` event on the editor queue. The only crate that knows Lean exists. |
| `editor-syntax` | Syntax trees, over `editor-text` alone: the `Syntax` port, which a parsing library fills (a parser for a grammar, a parse of a snapshot, an edit told to a tree, a query compiled and its captures, a tree read as plain nodes), its published fake (`fake::Parens`, a toy grammar) and its contract, run over a corpus of each grammar; the rule for what a query answers of a range (`query::captures_in`); highlighting (`highlight`: a query and a face for each capture, the rule that turns captures into spans, and spans carried through the edit log's patch); a text's session, which pulls the text and the edit log's patch through a `Source`, reparses incrementally, delivers a result to its consumers only if its revision is the newest told, and says which tree draws a snapshot; and the worker that runs sessions' rounds; injections (`inject`: the rule that finds a text's injected layers from an injections query's matches, layers parsed whole on the worker and drawn over the host's spans, delivered again at the same revision when new injections find new layers); and the structural queries a session keeps, one of each kind (text objects, indents), whose captures are answered from the tree delivered and refused before its reparse. It starts no thread. |
| `editor-syntax-treesitter` | The `Syntax` port's real adapter, over tree-sitter, pinned exactly, with the Rust, JSON, Markdown (block and inline), TOML and Lean grammars compiled in from their crates.io crates, or for Lean from upstream's crate vendored under `vendor/`, each pinned exactly, the queries each crate ships (highlights; Rust's and Markdown's injections), and Rust's indents and text objects queries, written here (`queries/rust/`). No tree-sitter type is public. Its tests hold it to the port's contract for each grammar, over fixtures checked in under `tests/syntax/`. |
| `editor-term-ghostty` | Added after the first milestone. |

The Lean package in `lean/` builds the executable with Lake, which runs
Cargo for the static library:

| Part | Contents |
|---|---|
| `Editor.Ffi` | Bindings to the library, and a small C glue file. |
| `Editor` | The interfaces and their models, editor state, the command loop, jobs, the config session. The command loop runs one input scheme: each key press is stepped through it, and the invocation it yields is looked up in the registry of compiled and config commands and run as a command, which the loop rolls back when it is refused or interrupted. |
| `Editor.UndoTree` | The undo tree: a text's history as a tree of states, in plain Lean over the text interface. Groups, undo, redo, branches, reverting the open group, and the saved state. |
| `Editor.File` | Loading, saving and reading a file's stamp as a job asks for them: the three file requests of the job interface, with their data (a stamp, line endings, what a save expects, the refusals), and a pure model of the files a job reaches. The work is the library's; a file's bytes never pass through a Lean string. |
| `Editor.Files` | The file commands: opening a file into a buffer, saving a buffer to its file, and reloading a buffer from its file as one edit made from a line diff, so the cursor and the markers stay and one undo takes it back, each a command that starts a job and the command the job finishes with, so the editor thread never waits for a file. `Editor.Files.Compiled` registers them and their jobs as compiled code, which the executable ships. |
| `Editor.Workspace` | Projects, workspaces and locations as plain values ([projects.md](projects.md)): a project identified by its normalised `origin`, its common git directory or its root; a workspace, one checkout of it, with its one root, its branch and its location; the table of both, with their stores, in the editor state. `Editor.Workspace.Finder` is the finder, a job over the process and file requests that tries config's roots, git and marker files in that order, with its pure model (`Editor.Workspace.Model`) and its contract (`Editor.Workspace.Contract`). `Editor.Workspace.Attach` gives a buffer its workspace when its file opens, and says it with `workspace-current`; `Editor.Workspace.Compiled` registers the command and the find job, which the executable ships. |
| `Editor.Minibuffer` | The minibuffer's commands and its mode: `minibuffer-accept` and `minibuffer-cancel`, which answer and cancel the open prompt, `minibuffer-next` and `minibuffer-previous`, which move a choice through the candidates the prompt has listed (the candidate list's view, which shows them, is the completion display's, `Editor.Completion.Display`, drawn by the loop, not the minibuffer's), `minibuffer-delete-backward`, which deletes the character before the minibuffer's bar and cancels the prompt when the minibuffer is empty, and the mode the minibuffer's buffer is made with, which fills the roles `activate`, `quit`, `next-item` and `previous-item` with them. A command asks for a string by naming the command that receives the answer, and never waits; the open prompt is editor state, and the minibuffer a buffer and a window of it (`Editor.State`, `Editor.Api`). `Editor.Minibuffer.Compiled` registers the commands and the mode as compiled code, which the executable ships. |
| `Editor.AtPoint` | Completion at point's commands (`at-point-complete`, `-next`, `-previous`, `-tab`, `-backtab`, `-return`, `-quit`, `-triggered`, `-paused`), which ask a buffer's chain of at-point sources (`Editor.Completion.AtPoint`), move a session's choice previewed in its region, accept it and quit it, through `Editor.Api`'s `completeAtPoint`, `previewAtPoint` and `endAtPoint`; the session is editor state (`Editor.State`), kept, listed and closed by the loop. The shipped source is `Editor.Completion.Words`, the words of the open buffers, gathered by a job. `Editor.AtPoint.Compiled` registers the commands and the `words` job as compiled code, which the executable ships, and the Vim scheme binds them in insert state. |
| `Editor.Vocabulary` | The parts of speech of editing as data any input scheme can use: the motion, a name and a function from a position and a count to a raw target; the operator; and the text object, a name and a function from a position, a count and a visual selection's anchor to what it covers. Each is a program that changes nothing. |
| `Editor.Evil` | Vim's states, motions and commands on the editor API: what the Vim scheme's invocations run. Where a cursor may rest in each state, the move command over a table of motions, entering normal state and the visual states, the keys that begin an insert, and typed text. `Editor.Evil.Motions` holds the twenty-eight motions, fifteen composed from the text interface's motion primitives six character finds (`f t F T ; ,`), six searches (`/ ? n N * #`), which ask the text interface's `search`, and `%`, which asks its `unmatched`; `Editor.Evil.Objects` holds the sixteen text objects (`iw aw iW aW`, the quotes and the blocks), ported from Vim 9.1 over the text interface's two pair questions, and the command that sets a visual selection to one; and `Editor.Evil.Compiled` registers the commands as compiled code, which the executable ships, so the editor moves, edits, undoes, repeats and scrolls with no config. `Editor.Evil.Operators` holds the four operators (`d c y`, and `replace`, the visual put no key binds), the rules for what an operator takes, the operate command and `x`; `Editor.Evil.Registers` the unnamed register and the clipboard's, and `p` and `P`; `Editor.Evil.Clipboard` the Edit menu's Cut, Copy, Paste and Select All, reached by the Vim run tables and the Edit menu; `Editor.Evil.Undo` `u` and `C-r`, which place the selection a step of the history hands back; `Editor.Evil.Repeat` dot repeat, which replays the change the Vim scheme hands it; and `Editor.Evil.Theorems`, with `Editor.UndoTree.Theorems`, the proof on the text model that `x` then `u` restores the text. `Editor.Evil.Scroll` holds the seven commands that scroll a view: `C-d` and `C-u` by half the rows the view fits, `C-f` and `C-b` by the rows it fits, and `z t`, `z z`, `z b`, which put the cursor's row at the top, in the middle and at the bottom. |
| `Editor.Scroll` | Where a view's scroll anchor goes: programs over the display interface's two queries, and arithmetic on what they answer. How a view follows its cursor, by the least movement, with the scroll margin; and the anchors a scroll by rows and a scroll to the cursor's row place. It holds no state and keeps nothing of layout: the command loop asks it before each scene, and evil's scroll commands when they run. |
| `Editor.Clipboard` | The clipboard interface: read and write, each refused as a value when there is no clipboard, with its pure model (`Editor.Clipboard.Model`) and its contract (`Editor.Clipboard.Contract`). It is a sub-port of the editor's port, so a command asks it as it asks a text. `Editor.Clipboard.InProcess` is the clipboard of a host with no window, a cell of the process that answers with the model's rule. The adapter to a window system's clipboard is the display pipeline's. |
| `Editor.Fuzzy` | The fuzzy matching interface: which of some candidates a pattern matches, best first, with its pure model (`Editor.Fuzzy.Model`), a subsequence test over the strings' scalar values with the candidates that are the pattern first, its contract (`Editor.Fuzzy.Contract`), and its real binding (`Editor.Fuzzy.Real`), one call into the library. It is a sub-port of the editor's port, so a command and config ask it as they ask a text. It is also answered as a request of the job port (`JobRequest.fuzzy`, `Job.embedFuzzy`). The loop asks it inline for an open prompt's candidates before each scene only at or under `Loop.inlineMatches`; above that, the prompt's style runs in a match job. |
| `Editor.SyntaxTree` | The syntax tree interface: the grammars the library has, attaching a text to a grammar, compiling a query and asking its captures in a range, injections and the languages they may name, keeping a query of a structural kind and asking its captures, each refusal a value, with its pure model (`Editor.SyntaxTree.Model`: a parser of a subset of JSON that builds the tree `tree-sitter-json` builds, and a subset of the query language), its contract (`Editor.SyntaxTree.Contract`), run against the model by `model-test` and against the real binding (`Editor.SyntaxTree.Real`) by `contract-test`; and a grammar's shipped query and highlighting a text with a query in faces. A sub-port of the editor's port, its refusal handed back to a command as a value (`SyntaxTree.lift`). |
| `Editor.Highlight` | The capture-to-face rule (the shipped `syntax.<capture>` default from the face vocabulary, a dotted capture falling to its first component, config's mapping over both) and what setting a major mode with a syntax tree asks of the syntax tree port: attach and highlight the buffer's text, or detach it, a refusal said in the echo area; then its injections, a language for each grammar, and its text objects and indents queries kept. The loop's dispatch runs it. |
| `Editor.Language` | Languages as data: an entry's name, file-name patterns, grammar with the overrides a mode takes, and indent unit; the shipped table (`rust`, `json`, `markdown`); the pure rule that chooses a path's language from a table in precedence order, an exact base name before an extension, config's entries before the shipped ones; and the one generic major mode, `code`, whose text is parsed and drawn as its buffer's language says. Opening a file records its language and sets `code` (`Editor.Files`); config adds and overrides entries with `defineLanguage`. |
| `Editor.Indent` | The indent rules, pure: a row's level (`Indent.rule`, over the captures of the indents query as plain rows), a new line's level at a position (the opening rule, `Indent.openingCounts`) and the widening to an incomplete node; and the decisions `=` and the new-line commands forward to (`Indent.reindent`, `Indent.newLine`, `Indent.breakAt`). The primitives over the text and syntax ports, `TextId.indentLevels`, `TextId.openingLevel` and `TextId.reindentEdits`, each a refusal a value. One level of indentation is `Editor.Language.IndentUnit`, a module of its own so the state requests can name it. |
| `Editor.Evil.TreeObjects` | The syntax tree's text objects, entries of evil's vocabulary (`a-function`, `inner-function`, `a-class`, `inner-class`, `an-argument`, `inner-argument`), and the rule that chooses a node from the text objects query's captures as plain rows (`TreeObjects.choose`). |
| `Editor.Ex` | The ex command line: a prompt whose answer is run as a named ex command. `ex` asks for a line and has the command the line's first word is bound to run after it, as a step of its own, with the rest of the line as its argument; and the commands `quit`, `save-and-quit` and `reload-config`. A command cannot end the process or reload the config: it asks, and the loop hands the request to its host. `Editor.Ex.Line` is a line and an ex binding as data, with the parser; an ex name is bound to a command's name in the registry, by owner, from compiled code and from `setup`. `Editor.Ex.Compiled` registers the commands and the ex names `w`, `e`, `q`, `wq` and `reload` as compiled code, which the executable ships. The ex line's prompt has the bound ex names as its candidates, so a name is completed; an argument is not. Ranges and `!` are not built. |
| Standard library | evil's operators; completion in the minibuffer and its display, and completion at point (built); later agents, review, version control, the rdm client. |
| `Main` | Dispatches the command line: `headless` to the headless mode, `window-check` to the keyboard check, and anything else to the window mode (`Editor/Window/Real.lean`), which wires the real bindings together, the display on the system's fonts and the system clipboard among them, and runs the headless host's editor loop on a file in a window. |

## Milestones

1. **Edit a file**: GUI window, open, edit with evil, save, live config
   reload. Planned in rdm: `workspace-and-ports`, `text-core`,
   `command-loop`, `display-pipeline`.
2. **Syntax**: tree-sitter (`syntax-tree-sitter`).
3. **Agents and review**: the process service, terminal, ACP, the agent
   table, hunk review, version control and the rdm client. Not yet planned
   in rdm; these documents are the input.

## Risks accepted with this design

- **More of the editor is Lean**, which coding agents write less fluently
  than Rust.
- **The build needs workarounds on each platform**, tied to the pinned Lean
  release. On macOS and on Linux: the system compiler in place of Lean's
  bundled one, and a small C entry point so Rust keeps the real main thread.
  How the entry point takes the place of `main` differs: a linker entry
  symbol on macOS, a renamed `main` (`--wrap`) on Linux. Each has a case for
  those two platforms and a compile error with a reason anywhere else
  ([lean-runtime.md](lean-runtime.md), "Build").
- **Unconfirmed**: Windows, which has not been attempted; Linux on x86_64
  and with real keys on a desktop (the gate passes on aarch64 in a
  container, and synthetic keys reach the Lean loop there under Xvfb); and
  an input method's composition on macOS.

  Real keys on macOS are confirmed, by hand on 2026-11-12 with
  `mise run window-check`: key presses, key repeat and releases reach the
  Lean loop, with a median of about 17 µs from a key's arrival in Rust to
  its handling in Lean, and the window takes the keyboard without a click
  when it is started from a terminal in front. Dead keys arrive there
  through composition. Whether they do in a window that was never clicked
  is not settled (rdm task `macos-composition-not-enabled`), and neither an input method that composes a script nor the window with
  composition not allowed has been tried there
  ([concurrency.md](concurrency.md), "Still to verify").
- **The executable is about 180 MB on macOS and 265 MB on Linux**, because
  Lean's compiler is linked in. Linked against Lean's shared libraries it is
  4 MB, which saves disk and nothing else ([lean-runtime.md](lean-runtime.md),
  "Memory and size").

## Open questions

- Which pieces of milestone 3 should be pulled into milestone 1 because they
  change library data structures: excerpt buffers, and the process service?
  The edit log's origin field is already in milestone 1.
- Which features ship compiled and which interpreted, and how a user
  overrides a compiled feature. See [lean-runtime.md](lean-runtime.md).
