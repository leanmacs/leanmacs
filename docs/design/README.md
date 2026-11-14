# Design documents

Status: **draft**, written before the first milestone. Nothing here is built
except two throwaway prototypes: the Rust-hosts-Lean bridge (commit
`4e57f01`) and the Lean-owns-the-process spike (uncommitted). Each document
ends with its open questions; a decision gets recorded in the table below
and the document updated.

| Document | Covers |
|---|---|
| [overview.md](overview.md) | Goals, principles, where the line between Lean and the Rust library falls, the rules of that boundary, the component map, code layout |
| [concurrency.md](concurrency.md) | Threads, the foreground/background split for Lean code, cancellation, what the Lean runtime requires, reload |
| [lean-runtime.md](lean-runtime.md) | The build, start-up, config and reload, the editor API as interfaces with models, where state lives |
| [keymaps-and-modes.md](keymaps-and-modes.md) | Key handling as a pure pipeline, input schemes, the Vim scheme, modes as records, roles and leader keys, testing keymaps. Partly built: keymaps, input schemes, invocations, key strings, the Vim scheme's grammar with its default states and bindings, and the loop's one scheme with command dispatch and key bindings by owner; the rest is a proposal |
| [text-and-display.md](text-and-display.md) | Text storage, the edit log, anchors, excerpt buffers, decorations, the scene, layout, rendering, view kinds |
| [rendering-prior-art.md](rendering-prior-art.md) | A survey of how Zed, neomacs, Xi, Helix, Lapce and others stay responsive; what we adopt and reject |
| [rust-library.md](rust-library.md) | What the Rust library provides beyond text and display: timers, processes, files, watching, diff, terminal, syntax; and what is built in Lean on top |
| [agent-hosting.md](agent-hosting.md) | Hosting coding agents: ACP, the terminal front end, the agent table, permissions, sessions |
| [review-and-navigation.md](review-and-navigation.md) | Reviewing agents' plans and code, provenance, version control, the rdm client, codebase navigation |

`AGENTS.md` at the repository root holds the working rules (test-first, ports
and adapters, hand-written fakes). These documents say what to build; that
file says how.

## Decisions

| Decision | Choice | Decided |
|---|---|---|
| Extension language | Lean 4 | Prototype |
| Who owns the process | Lean. The editor is a Lean program; Rust is a library it calls and pulls events from. Rust never calls Lean | 2026-11-10 |
| The split | Rust: text storage, layout, rendering, the window, processes and terminals, parsing. Lean: editor state, the command loop, every feature | 2026-11-10 |
| Editing style | evil (Vim-style modal), written in Lean, from the first milestone | 2026-11-09 |
| First front end | GUI (winit, wgpu). The frame is device-independent, and a cell grid shaper and renderer are built early as test adapters, so a terminal front end stays possible | 2026-11-09, revised 2026-11-11 |
| Lean editor API | Interfaces with a real binding and a pure model, not direct library calls. An interface is a port (requests, and a reply type for each), and a command or a job is a program over it, run against either handler; not type classes | 2026-11-09, representation 2026-11-11 |
| Config session | A pure core over an elaborator port and a source port, with Lean's elaborator behind one adapter. `setup` is a program over a setup port of its own, and a command is the value it registered. A store is a whole-value cell in the editor's state, not a request of the editor's port. Every thread Lean creates has a 64 MiB stack, so runaway recursion in config ends the process quickly | 2026-11-11 |
| Job system | Built on plain tasks and promises, not on Lean's async library: a wait is a promise completed by a completion pump, so a job in a wait holds no thread. Cancellation is not a reply, so a `try`/`catch` cannot resume a cancelled job. A job finishes with a command, which the editor thread runs. Jobs share their owners with the registry, and a reload that installs cancels the old config's jobs. Timers are a Rust service behind the completion queue. The pool keeps Lean's size, one thread a core, and is warmed at start-up | 2026-11-11 |
| Platforms | macOS and Linux build and pass the gate; Linux was run on aarch64 in a container. The system compiler compiles the glue and links on both, and the C entry point takes `main`'s place by a linker entry symbol on macOS and by `--wrap=main` on Linux. Windows has not been attempted. No dynamically linked build: it saves disk and nothing else | 2026-11-12 |
| Window port | A crate of its own, `editor-platform`, with no dependencies: what a window reports as plain data, a scripted fake and a contract. `editor-platform-winit` is the adapter, and only it may name winit. The window is run by the main-thread service onto the editor queue, each event stamped when it was reported, and Lean closes it. A key carries its logical and physical identity and the modifiers, as W3C UI Events names, with the text it produced beside it; a pointer its action, position, button and modifiers; a resize the size and scale | 2026-11-12, identity 2026-11-13 |
| The editor's port | A composite: its requests are a sum of sub-ports (text, display, watch; buffers and windows to come), each reply its sub-port's. The watch port is the interrupt flag and the job clock, so the loop that asks them stays one pure program. A command is `EditorM`, a program over it; a sub-port's programs (`TextM`, `DisplayM`, `WatchM`) are lifted into it automatically, so config written at `EditorM` uses every text operation as it is. A refusal stays a `TextError`, the display's mapped to the text's of the same name, until a sub-port needs more. Each runner's state is the product of its sub-ports' | 2026-11-13 |
| Display contract | Lean publishes a scene of plain data after each command: views by handles (a snapshot, a scroll anchor and selections as markers), faces by name only. Layout answers two queries in the same call, the rows a view shows from its anchor and the position some visual lines away with the goal x passed back; Lean keeps no layout. A model lays text out in fixed-size cells, and one contract holds it and the real binding (over a fake shaper of that cell size) to the same properties. A key, a pointer and a resize cross the editor queue as words beside the event: the layouts are the table in `editor-ffi`'s `window.rs` | 2026-11-13 |
| Rope | `ropey`, pinned at exactly 2.0.0-beta.1: indexed by byte, with rows split by line feed alone and UTF-16 counted in the tree, edits that return an error, and clones that share nodes. One private module of `editor-text` names it. `crop` is the fallback; a summarised tree of our own is left to the display layers | 2026-11-12 |
| Text model | UTF-8 only. A byte of a file that is not valid UTF-8 is kept as one reserved character, `U+10DC00` plus the byte, and saved as that byte, so an unedited save is byte-identical. Line endings are kept as they are. Positions are byte offsets on character boundaries; a row ends at a line feed alone; a point's column is in bytes, in UTF-16 code units or in cells, and no conversion clamps. A snapshot is the text at one revision, immutable and shared between threads, and is the only read view | 2026-11-12 |
| Edit model | Change sets on Helix's model: retain, delete and insert in bytes, in one normal form, for a text of one length. They apply, compose and invert, and map a position with a bias. A transaction is a change set plus optional selections, and applying one, all or nothing, is the one way a text changes and one revision. Ours: no published library counts in bytes over our rope or has the log | 2026-11-13 |
| Edit log | One entry for each applied transaction: its revision, an opaque 64-bit origin whose meaning is Lean's, and its changed ranges with four points each, from which the three tree-sitter takes are derived. Consumers pull one coalesced patch since a revision; a subscriber is a revision the consumer keeps. A range is traced to the entries that wrote it by walking the log. The log is dropped only when Lean forgets up to a revision | 2026-11-13 |
| Anchors and selections | An anchor is an offset and a bias, mapped at each transaction as Emacs moves its markers. A text holds markers, each an anchor or a selection under an id, and moves them all with every transaction it accepts. A selection is ranges of two offsets with one shape (exclusive, inclusive, line, block), kept sorted and merged, with a primary; its ends move as anchors, with biases that follow from the shape. What it covers is computed against a snapshot, in cells: a character, or a carriage return and line feed together. Evil's states map onto the shapes; its rules stay in Lean. Ours, with no library | 2026-11-13 |
| Motions | Motion primitives are questions of the text port, answered in Rust by walking the rope from a position, a cell at a time, so a motion moves over exactly what a selection covers: the next and the previous cell; the start and the end of the next and the previous word and WORD; the start of a line, its end and its first non-blank; the ends of the text; and rows up or down at a column counted in cells, which a point's column can be counted in too. A word character is an ASCII letter, digit or underscore or any character from U+0080 up, a rule the pure model can state: Vim's on ASCII, and not beyond it. One row and a range are read without the whole text. Which key runs which motion, counts, the wanted column and keeping a cursor on a line are evil's, in Lean. Ours, with no library | 2026-11-13 |
| Undo | In two halves. Rust keeps the inverse of every applied transaction and applies the inverse of a run of consecutive revisions as one transaction, where the text is in the state the run ended in; it hands back the selection in force before the run, and deleted text never leaves it. The revision only grows: an undo is a new revision that returns the text to an earlier state. The undo tree is Lean, over those two requests of the text port: groups whose boundaries the caller sets, undo, redo and branches, reverting the open group, and the state last saved. Every undo policy is Lean's, so other undo styles are written over the same primitives. Ours, with no library | 2026-11-13 |
| Files | An `Fs` port that `editor-text` defines, with a published fake and a contract; `editor-fs-std` is its adapter over `std::fs`, a crate of its own, held to the contract by its own tests in a temporary directory. A load reads a file once up to the caller's limit, refuses a binary one, counts its line endings and changes none. A save is a temporary file beside the file and a rename, with the file's permissions, and is refused when the file on disk is not the one that was loaded, unless the caller overrides. One service thread in the library works loads and saves in order, behind the completion queue. The logic's tests make no real file, which the linter and `cargo-deny` hold. In Lean, load and save are requests of the job port, which a job awaits, and a refusal is a value. A job reads a snapshot a command took, by its id, from the table of snapshots the editor thread publishes and alone writes; what a job's load makes is the job's, named by a second kind of id, until the job's command takes it into the store, on the editor thread, and the runtime releases what the job held once that command has run. Ours, over `std`, with `tempfile` for tests | 2026-11-13 |
| Vim scheme | Vim's grammar is one input scheme, pure Lean over a registry of Vim states: a key is bound to a part of speech named by its vocabulary name, a key sequence parses to an edit (a move, an operator over a target, a command), and the edit compiles to an invocation. Counts in any position multiply, and no count is not a count of 1. A register is named after a prefix bound in a keymap. The visual selection is not in the scheme's state: an operator in a visual state is an edit over the selection. Which Vim state a view is in is in the scheme's state, by view, so the next key is looked up in the new state's keymaps with no editor API. A key is walked through the active keymaps and then the state's, as one walk. The last edit that changed text is kept as a value. The default states and bindings are data in a module of their own | 2026-11-13 |
| Syntax | Tree-sitter, right after the first milestone | 2026-11-09 |
| Agent protocol | Agent Client Protocol (ACP), with the client written in Lean | 2026-11-09, client placement 2026-11-10 |
| Terminal | libghostty (state of the library to be verified first) | 2026-11-09 |
| Licence | GPL-3.0-or-later | 2026-11-09 |
| Version control | In Lean, over subprocesses; the Rust library supplies text diff only | 2026-11-09 |
| Concurrency | Serialized foreground commands plus background jobs on Lean's task system; cancellation and process ownership built by us | 2026-11-09, revised 2026-11-10 |
| Rendering stack | wgpu on every platform, behind the `Renderer` port. Existing libraries are preferred even when immature (Parley, Vello), each behind a port; we write our own only where none fits | 2026-11-10 |
| How much we write | No library supplies the editor whole. Libraries cover the rope, shaping, drawing, the window, the terminal and parsing; the edit model, display layers, layout cache and frame building are ours | 2026-11-11 |
| Interface model | Text is the only layout engine: blocks, tables, lists and popups are text; anything else (images, SVG, embedded terminals, nested text views) is a box that text layout places. No widget toolkit | 2026-11-11 |
| Accessibility | Required. The tree is derived from the scene and layout as plain data, behind a port, with AccessKit as the planned adapter | 2026-11-11 |
| Runaway code | Not a design driver: an interrupt flag checked at API calls, no watchdog. The flag is the Rust library's, a count raised as the interrupt key arrives, before it is queued; which key, when it is asked and when it is lowered are Lean's. A command a key runs is asked before each request and stops there, and the loop lowers the flag as it takes the key off the queue | 2026-11-10, flag 2026-11-13 |
| Command dispatch | The loop runs one input scheme for the editor and holds its state. A key press is stepped through it, and the invocation it yields is looked up by name (compiled commands, then config's of the same name in their place) and run with the focused window, its arguments and its keys. A failure goes to the echo area; a refused or interrupted command is rolled back by reverting each undo tree to the state kept before it and putting back each window's markers, and a move in the history is not taken back. Config binds a key sequence to a command name from `setup`, by owner, and a reload replaces config's bindings. A command slower than a threshold is logged | 2026-11-13 |
| Memory | A few hundred megabytes at start-up is acceptable; the target is "not gigabytes" | 2026-11-10 |

Considered and set aside: compiling Lean extensions to WebAssembly (loses
live reload, threads and shared state), and a custom language with its own
type checker on a Cranelift back end (no reusable prover exists as a Rust
library). Running Lean's intermediate code on a runtime of our own remains
a possible later step; config written against the editor API would not
change.

## Evidence

- A research pass on agent hosting, review tooling, the academic
  literature, codebase navigation, rdm, and the lessons from the `edmacs`
  Emacs configuration.
- The spike of this architecture, with measurements.
- A survey of Rust editors and text stacks (rendering-prior-art.md).
- Experiments on the Lean runtime's concurrency behaviour.

The notes and report are local and untracked (`research_notes/`,
`reports/`). Where a design choice rests on them the document says so, and
says when the source was weak. The split between Rust and Lean is reasoning
from that evidence, not something the evidence establishes.
