# Design documents

Status: **draft**, written before the first milestone. Nothing here is built
except two throwaway prototypes: the Rust-hosts-Lean bridge (commit
`4e57f01`) and the Lean-owns-the-process spike (uncommitted). Each document
ends with its open questions; a decision gets recorded in the table below
and the document updated.

| Document | Covers |
|---|---|
| [overview.md](overview.md) | Goals, principles, where the line between Lean and the Rust library falls, the component map, code layout |
| [concurrency.md](concurrency.md) | Threads, the foreground/background split for Lean code, cancellation, what the Lean runtime requires, reload |
| [lean-runtime.md](lean-runtime.md) | The build, start-up, config and reload, the editor API as interfaces with models, where state lives |
| [text-and-display.md](text-and-display.md) | Text storage, the edit log, anchors, excerpt buffers, decorations, the scene, layout, rendering, view kinds |
| [rendering-prior-art.md](rendering-prior-art.md) | A survey of how Zed, neomacs, Xi, Helix, Lapce and others stay responsive; what we adopt and reject |
| [rust-library.md](rust-library.md) | What the Rust library provides beyond text and display: processes, files, watching, diff, terminal, syntax; and what is built in Lean on top |
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
| First front end | GUI (winit, wgpu); a terminal renderer can come later as another adapter | 2026-11-09 |
| Lean editor API | Interfaces with a real binding and a pure model, not direct library calls | 2026-11-09 |
| Syntax | Tree-sitter, right after the first milestone | 2026-11-09 |
| Agent protocol | Agent Client Protocol (ACP), with the client written in Lean | 2026-11-09, client placement 2026-11-10 |
| Terminal | libghostty (state of the library to be verified first) | 2026-11-09 |
| Licence | GPL-3.0-or-later | 2026-11-09 |
| Version control | In Lean, over subprocesses; the Rust library supplies text diff only | 2026-11-09 |
| Concurrency | Serialized foreground commands plus background jobs on Lean's task system; cancellation and process ownership built by us | 2026-11-09, revised 2026-11-10 |
| Rendering stack | wgpu on every platform, behind the `Renderer` port. Existing libraries are preferred even when immature (Parley, Vello), each behind a port; we write our own only where none fits | 2026-11-10 |
| Runaway code | Not a design driver: an interrupt flag checked at API calls, no watchdog | 2026-11-10 |
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
