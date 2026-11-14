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
| Text diff, search, fuzzy matching | Rust | Test 1 |
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
 │  evil · modes · keymaps · themes · minibuffer                │
 │  agents · review · version control · navigation · rdm        │
 │  ACP and language-server clients                             │
 │  editor state · command loop · jobs · config session         │
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
| `editor-text` | Rope, transactions, anchors, kept inverses, edit log, diff. Pure. Built so far: a text over a rope (`ropey`, behind one private module), its revision, snapshots that never change and are shared between threads, positions as byte offsets with rows and points in bytes and in UTF-16, and the bytes of a file in and out with invalid bytes kept; change sets that apply, compose, invert and map a position; transactions, applied all or nothing; and the edit log, with pulled coalesced patches, an origin for each entry, a trace from a range to the entries that wrote it, and forgetting; anchors, the markers a text holds and moves with every transaction, selections with a shape, kept sorted and merged, and what a selection covers; and the kept inverse of every applied transaction, the inverse of a run of revisions applied as one transaction where the text is in the state the run ended in, and dropping kept inverses; a text made from a snapshot; and files: the file port `Fs`, with its published fake and its contract, and loading a file into a text and saving a snapshot over that port, by a temporary file and a rename, refused when the file on disk is not the one expected. It does no I/O of its own. The undo tree is not here: it is Lean (`Editor.UndoTree`). Diff is planned. |
| `editor-fs-std` | The file port's real adapter, over `std::fs`, Unix only. It is a crate of its own so that `editor-text` does no I/O, and so that the adapter's tests are its own: the port's contract in a temporary directory, and how it names the system's errors. Only `editor-ffi` depends on it. |
| `editor-layout` | Layout, pure, over a `Shaper` port it defines, with the port's published fake (`CellShaper`, one glyph per character, a cell per family scaled by a font's size) and contract. A font is named to the port by a spec: family, size, weight, slant, line height. A glyph names the resolved font it is drawn in, an entry of the shaper's table, and carries the offset its outline is drawn at. Built so far: the scene as Rust data, with the definitions of the faces it names; faces, sets of optional attributes, and the precedence by which the faces over a run merge into one font and one paint; the display-layer contract with the tab layer (tabs expanded before shaping; long rows cut into segments) and the wrap layer (the per-text store of laid-out segments); decoration sources (selections, the scene's decorations) merged into runs, lowest layer first; per-segment layout cached and moved through the edit log's patches, rebuilt when a patch is refused, estimated where not laid out; the cells of each visual line, by which positions, cursors and selections are found in any glyph order; the two layout queries; the frame, an immutable value of resolved paints and font ids with a content hash per row, which carries the shaper's table of resolved fonts and its generation, and a view's status fields as one row at its bottom; and counters of the work. It depends on `editor-text` for snapshots, patches and selections. |
| `editor-shape-parley` | The `Shaper` port's real adapter, over Parley and fontique, both pinned exactly; no type of either is public. Built: a font set, of given files as bytes or of the system's fonts; the shaper, one Parley layout for each segment shaped, kept and broken again at another width, with font fallback, ligatures, bidirectional text in visual order and mixed families; the resolved fonts it draws in, described for a rasteriser. Its tests run on the fixture fonts under `tests/fonts` and hold it to the port's contract. It depends on `editor-layout` alone. No library crate depends on it yet: the display handle in `editor-ffi` still runs on the fake, and its one user is a dev-dependency, the renderer's wiring tests. |
| `editor-render` | The `Renderer` port, with what every back end shares, over `editor-layout` alone. The port is one method: a frame and a target in, what drawing it cost out. Beside it: the port's published fake (`RecordingRenderer`) and its contract; the mailbox frames arrive through, where a newer frame replaces one not yet drawn; the scheduler, a pure function of the demands and the time; the rule for which rows of a frame are built again; the frame journal and the counters; the loop that ties them together, with the handle other threads reach it through; and time and waiting as ports, each with a fake. It has no real clock and starts no thread. It is a crate of its own for the reasons `editor-platform` is. |
| `editor-render-wgpu` | The `Renderer` port's real adapters, over one painter of our own: a frame to quads, with a glyph atlas (packed by `etagere`), a glyph cache with a bound, and glyph images rasterised by `swash`. `HeadlessRenderer` lays the quads over a picture in memory on the CPU and needs no GPU; `WgpuRenderer` draws them with `wgpu`, to a target of its own, with no window yet. All four libraries are pinned exactly and none is public. The gate compares the headless adapter's picture of one frame of real text with a reference image, and runs the wgpu adapter on wgpu's no-op back end; a real GPU's picture is compared on demand. It also holds the presentation choice, as a pure function. Nothing depends on it yet. |
| `editor-platform-winit` | The window port's real adapter: it opens one window with winit, on the process's main thread, and translates what winit reports about it into the window port's inputs. No winit type is public. |
| `editor-platform` | The window port, with no dependencies: what a window reports (`Input`), how it is opened (`WindowOptions`), the `Platform` trait, its published fake (`ScriptedPlatform`) and its contract. It is a crate of its own because the fake and the contract belong to the port's owner, and nothing may depend on `editor-ffi`. A key carries its logical key, its physical key (W3C UI Events names) and its modifiers; a pointer its action, position, button and modifiers; a resize the size and scale. The command loop fixed that shape; producing it from winit is the display pipeline's. |
| `editor-proc` | The process and pseudo-terminal service. |
| `editor-ffi` | The static library Lean links: the C functions Lean calls, handles, the event queues, the timer service, the first service behind the completion queue, the file service, the second, which loads and saves on one thread of its own over the file port and is what the job runner's file port is bound to, and the main-thread service, which runs a platform's window onto the editor queue. Two of its handles are text: a document, which is an `editor-text` text behind a lock, made from a string or from a snapshot, and a snapshot, of a document or of a file the file service loaded. A document applies a transaction, answers for its edit log, holds markers, applies the inverse of a run of its revisions and drops kept inverses, and a snapshot says what a selection covers; those are lists, which cross the boundary as words, a buffer of 64-bit numbers. A document has a key, and a snapshot of it carries the key and reaches the document's log and markers. A third handle is the display: `editor-layout` over its fake shaper, which takes a published scene (words, one string and a list of snapshot handles, with the definitions of its faces in the same words when they changed), keeps the latest frame, and answers the two layout queries. The only crate that knows Lean exists. |
| `editor-term-ghostty`, `editor-syntax-treesitter` | Added after the first milestone. |

The Lean package in `lean/` builds the executable with Lake, which runs
Cargo for the static library:

| Part | Contents |
|---|---|
| `Editor.Ffi` | Bindings to the library, and a small C glue file. |
| `Editor` | The interfaces and their models, editor state, the command loop, jobs, the config session. |
| `Editor.UndoTree` | The undo tree: a text's history as a tree of states, in plain Lean over the text interface. Groups, undo, redo, branches, reverting the open group, and the saved state. |
| `Editor.File` | Loading and saving as a job asks for them: the two file requests of the job interface, with their data (a stamp, line endings, what a save expects, the refusals), and a pure model of the files a job reaches. The work is the library's; a file's bytes never pass through a Lean string. |
| Standard library | evil, the minibuffer; later agents, review, version control, the rdm client. |
| `Main` | Wires the real bindings together and starts the loop. |

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
