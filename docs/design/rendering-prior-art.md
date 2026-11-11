# Prior art: responsive editing and rendering in Rust editors

A survey of how existing Rust editors and text stacks stay responsive, and
what this editor takes from each. It covers Zed, neomacs, Xi, Helix, Lapce
and Floem, cosmic-text, Parley, Vello, Neovide, and the terminal emulators
that document their latency work.

The survey was done on 2026-11-10 from source and maintainers' writing. The
full notes, with a source per claim and unverified items marked, are local
and untracked (`research_notes/rust-editor-survey/`). Not covered: Rio,
Makepad, Amp, Ghostty's threading, WezTerm's glyph cache.

No surveyed project publishes its own input-to-frame latency. Third-party
measurements put the best terminals at 5 to 7 ms of software latency. Any
number we want to hold ourselves to, we have to measure ourselves.

## The lesson that bears on our architecture

Xi split the editor into a core process and a front end joined by an
asynchronous protocol. Its author's verdict was that this "was not a good
idea". The concrete failures:

- **Scrolling** took months: the front end kept needing lines its cache did
  not hold.
- **Resizing** raced with word wrap and tore.
- **Wrapping was split across the boundary**: the core broke lines while the
  front end measured widths, so every wrap was a round trip.

Lapce was built as the counter-design ("editing logic must be tightly bound
with the UI"), and neomacs keeps layout beside its Lisp for the same reason.

Our split is between two languages in one process, not two processes, but
the hazard is the same: two copies of state kept in step by messages. The
rules that follow from it:

1. **Text and layout live on the same side**, in Rust.
2. **Lean asks layout questions synchronously** and gets the answer in the
   same call: the visual line below the cursor, the position under a click,
   how many lines fit. Lean never keeps its own copy of layout.
3. **Measuring and line breaking are never separated.** Wrap where the
   shaper is.
4. **Edit-time behaviour stays synchronous** (indent, bracket pairing).
   Only derived data (parse trees, highlights, diffs) is computed in the
   background, tagged with the revision it read, and dropped if stale.

neomacs shows the opposite failure: its layout runs on the Lisp thread, so
layout blocks the extension language. Ours runs in Rust, where a command
can query it without the renderer waiting on Lean.

## What each project does

| Project | Text storage | What runs off the main thread | Layout caching | Drawing |
|---|---|---|---|---|
| **Zed** | One copy-on-write summarised tree for the rope and every display layer; snapshots are a reference-count bump | Soft wrap, parsing, language servers; each gets about 1 ms on the main thread first | Two generations keyed by text, fonts, size and width, swapped each frame; only visible rows shaped | Whole scene rebuilt per frame as typed instance lists, sorted into batches; glyph atlas |
| **neomacs** | GNU Emacs buffers reimplemented in Rust | Rendering and animation; layout stays on the Lisp thread | Three fast paths (cursor-only, scroll, local edit); rows carry a content hash | Renderer reuses cached row geometry by hash; a retained texture for cursor-only frames |
| **Helix** | `ropey`; change sets that also map positions | Language servers; parsing is synchronous with a timeout | None (terminal cells) | Terminal; redraws debounced; background work can briefly hold a frame |
| **Lapce / Floem** | A fork of Xi's rope; one delta per edit | Parsing, search; results tagged with a revision | Per line, but cleared entirely on every edit | wgpu through Vello or vger |
| **cosmic-text** | A vector of line strings | Nothing | Per paragraph, with shaping and line breaking invalidated separately; viewport-bounded | Rasterises with swash into an unbounded cache |
| **Neovide** | None (Neovim's grid) | Neovim itself | Shaping cache of 10,000 entries | A retained picture per line, replayed by transform, so scrolling does not reshape |
| **Alacritty** | Terminal grid | Reading the pseudo-terminal | Not applicable | Own frame timer, wake-ups coalesced into a dirty flag, per-line damage |

## Techniques we adopt

### Text

- **Snapshots are all that background work sees.** Workers, jobs and the
  renderer get a constant-time copy. (Zed, Helix, Lapce)
- **One edit value that maps positions**: a change set with a bias, used to
  move selections, marks, diagnostics and cache keys instead of recomputing
  them. Already planned in `text-core`. (Helix, Lapce)
- **Consumers pull coalesced patches.** Each subscriber asks "what changed
  since I last looked" and gets old and new ranges with no text. There is
  never a backlog, and it suits Lean pulling from the library. (Zed)
- **Revision-tagged background results, dropped on mismatch.** No
  operational transforms and no CRDT. (Lapce, Xi's follow-up)

### Display structure

- **Display layers with one contract.** Inlays, folds, tabs, wraps and
  blocks are each a layer that turns the snapshot and edits of the layer
  below into its own snapshot and edits, with its own coordinate type. We
  start with the layers we need and keep the contract. (Zed)
- **A budgeted wait, then an approximation.** Wrap and parse get about a
  millisecond to finish in the same frame. If they do not, the frame is
  drawn from an interpolated result and corrected later. (Zed)
- **Highlights computed for the visible range only**, not stored for the
  document. (Zed)

### Layout

- **One layout object per buffer line**, with shaping invalidated by text
  or font changes, line breaking by width changes, and nothing by
  paint-only changes. (cosmic-text, Floem)
- **Cache entries are moved through edits**, not cleared. Lapce clears its
  whole cache on every keystroke and reshapes the viewport each time.
- **Lines not yet laid out are estimated** as one visual line and corrected
  lazily. (Floem)
- **Whole runs are shaped from the start.** neomacs measured Latin text per
  character and is still locked out of ligatures.
- **Fonts are resolved in layout** and the renderer is handed exact
  identities, with a generation stamp so a stale cache is visible. (neomacs)

### Frames

- **The frame is an immutable value handed over through a latest-wins
  mailbox.** A newer frame replaces an unpresented one. (neomacs)
- **Rows carry a content hash, and the renderer reuses the geometry of
  unchanged rows.** Scrolling and cursor movement do not reshape or rebuild
  glyph runs. (neomacs, Neovide)
- **Instanced quads and a glyph atlas**, from a library where one fits and
  written by us otherwise: glyphs rasterised on the CPU on first use; separate textures for masks, subpixel and colour glyphs; a
  few horizontal subpixel positions in the key; a per-frame generation so
  glyphs in use are never evicted; and a bound on the cache. (Zed, glyphon,
  neomacs)
- **Frames are drawn on demand**: a dirty flag any thread can set, at most
  one draw per display refresh, explicit deadlines for animation, and a
  true wait when idle. The scheduler is a pure function of typed demands
  and the time passed in, so it is tested with a fake clock. (neomacs,
  Neovide, Alacritty)
- **A frame journal from the first day**: timestamps at input, draw and
  present for every frame. (Zed has one; nobody publishes results.)
- **Performance gates count work, not time**: rows laid out again,
  snapshots built. They are stable in CI where wall time is not. (neomacs)

### Terminal

- **Runs of same-style cells are shaped as one line** with a forced cell
  advance, and background rectangles are merged. Output is batched for a
  few milliseconds, with the first event handled at once. (Zed)

## Techniques we reject

| Technique | Used by | Why not |
|---|---|---|
| A CRDT text buffer | Zed, Xi | Pays only for real-time collaboration. Xi's author said it was "not pulling its weight" and leaked into indent, undo and selections. |
| An asynchronous protocol between the core and layout | Xi | See above. |
| A protocol that sends drawing instructions | Neovim front ends | The front end must hoard scrolled-off lines to animate, and cannot place inline or variable-height elements. |
| Wrapping by summed character advances | Zed | Fast, but wrong for ligatures, mixed fonts and complex scripts, which are a goal here. |
| One layout object for the whole document | Parley's `PlainEditor` | Reshapes everything on each keystroke; its maintainers say it is for small inputs. |
| Line storage as a vector of strings; unbounded glyph caches | cosmic-text, Alacritty | Large and varied files. |
| Per-platform native text stacks and renderers | Zed | Three shader dialects and three text systems. We take one portable stack on wgpu; see the risks below. |
| Layout on the extension language's thread | neomacs | A compatibility constraint there, not a choice to copy. |
| Compositing text against an assumed background in the shader | neomacs | Only valid when every glyph sits on a known opaque background. |
| Everything is an excerpt buffer | Zed | A complexity cost on the single-file path. Excerpt buffers stay a separate kind of buffer here. |

## Whole-editor libraries considered

Checked on 2026-11-11: is there a library that supplies the editor from
text to pixels, so that we write less? None fits. Each is an editor widget
inside a UI framework that owns the event loop and the editor state, which
is Lean's role here.

| Candidate | What it offers | Why not |
|---|---|---|
| Zed's `editor` and `multi_buffer` on GPUI | Display layers, excerpts, blocks, inlays: the closest to this design | Not published as libraries. State lives in GPUI entities and GPUI runs the application. |
| gpui-component's code editor | A GPUI widget with tree-sitter and language-server support | The same ownership problem. Folds, excerpts and blocks were not found (weak source: a blog post and the README). |
| Floem's editor view | Rope, per-line layout, wgpu through Vello | Tied to Floem's reactive runtime; clears its layout cache on every edit. |
| cosmic-text's `Editor` with glyphon | Buffer, cursor, selection, shaping, a wgpu atlas | Line storage and caches rejected above; no display layers. |
| Parley's `PlainEditor` | Small text inputs | Rejected above. |

What this leaves us to write, and where a library serves:

| Layer | Source |
|---|---|
| Rope | Library |
| Change sets, anchors, selections, undo tree, the edit log | Ours, on Helix's model |
| Display layers and excerpt buffers | Ours, on Zed's model. The largest piece; nobody ships it separately |
| Shaping, font fallback, line breaking | Parley and fontique |
| The per-line layout cache, hit testing, frame building | Ours, over the shaper |
| Rasterising, the atlas, drawing | Vello, or our own atlas if it cannot meet a requirement |
| Window, terminal, parsing, diff, search, fuzzy matching, watching | Libraries, each behind a port |

## Risks this raises for our planned stack

These are accepted (decided 2026-11-10): wgpu stays, behind the `Renderer`
port, and a less mature library is preferred to writing our own where one
exists. The ports are what make that safe, so each risk below names the
port that contains it.

- **Parley is moving fast**: five breaking releases in six months. It has
  no tab stops, no incremental relayout, and no shipped code editor on it
  except Floem's per-line use. It stays behind the `Shaper` port, pinned,
  used as one layout per line, and tabs are handled by us.
- **wgpu on every platform.** Zed moved its Linux renderer to wgpu in 2026
  but kept Metal and DirectX elsewhere, citing latency and driver
  reliability, and reviewers reported higher GPU memory. Some macOS
  frame-pacing techniques (presenting with the transaction during resize,
  keeping a variable-refresh display from clocking down) are not reachable
  through winit and wgpu as they stand. The `Renderer` port is what lets
  a native back end be added later if measurement says so.
- **Low-resolution displays.** Zed carried complaints about blurry text on
  Linux for years. Subpixel antialiasing and gamma correction have to be
  planned, not added.
- **Vello is young**: its GPU path and its glyph crate are both described
  as immature. It is still the first candidate for drawing and glyph
  caching behind the `Renderer` port. We write our own atlas only if it
  cannot meet a requirement (row reuse, subpixel text, bounded caches).
- **Very long lines** are unsolved in Helix and were a Parley bug until
  recently. Per-line layout needs a bound.

## Choices this leaves open

- **Rope**: `ropey` 1.x is stable but indexed by character and unchanged
  since 2023; 2.0 is in beta, which is not in itself a reason against it. Zed's summarised tree serves text and display
  layers with one structure. The boundary wants byte offsets either way,
  since Parley, tree-sitter and language servers all do.
- **Tabs**: expand before shaping, use inline boxes, or split runs.
- **Height of lines not yet laid out** when wrapping or line heights vary:
  estimate and correct, or lay out ahead in the background.
- **Damage**: redraw a retained scene in full each frame (Warp reports
  1.9 ms), or report damaged regions to the compositor (Alacritty).
- **Present mode and pacing** through wgpu on each platform.
