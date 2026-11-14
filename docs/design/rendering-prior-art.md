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
  them. Built: the change set and its mapping; nothing calls the mapping
  yet ([text-and-display.md](text-and-display.md), "Change sets"). (Helix,
  Lapce)
- **Consumers pull coalesced patches.** Each subscriber asks "what changed
  since I last looked" and gets old and new ranges with no text. There is
  never a backlog, and it suits Lean pulling from the library. Built, with
  a subscriber as a revision the consumer keeps
  ([text-and-display.md](text-and-display.md), "The edit log"). (Zed)
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
| Change sets, anchors, selections, kept inverses, the edit log | Ours, on Helix's model |
| The undo tree | Ours, in Lean, over the kept inverses. Helix's is in its core, beside the text |
| Display layers and excerpt buffers | Ours, on Zed's model. The largest piece; nobody ships it separately |
| Shaping, font fallback, line breaking | Parley and fontique |
| The per-line layout cache, hit testing, frame building | Ours, over the shaper |
| Rasterising | `swash`, a library ("The drawing library, as chosen") |
| The glyph atlas, row draw data, drawing | Ours, on wgpu: no published library draws subpixel text ("The drawing library, as chosen"). Packing the atlas is `etagere`, a library |
| Window, terminal, parsing, diff, search, fuzzy matching, watching | Libraries, each behind a port |

## The drawing library, as chosen

Chosen on 2026-11-13, when the display pipeline's phase 4 was planned, and
not yet confirmed by the owner: **an atlas and instanced quads of our own
on wgpu, with `swash` rasterising glyphs and `etagere` packing them**. The
candidates were checked at their current versions against what the
renderer must do, in the order the roadmap gave them: Vello first, a
glyphon-style atlas crate second, our own as the fallback. The fallback
applies because of one requirement: nothing published draws subpixel
text, and subpixel antialiasing is in scope for the renderer from its
first version ("Low-resolution displays", below).

Each claim below is marked **seen** (a spike was run and its output read)
or **read** (in the source or the manifest at the version named). The
spikes were three small binaries in a scratch Cargo project outside the
repository; nothing of them is checked in.

**Versions** (crates.io, 2026-11-13; read). `wgpu` 30.0.2. `vello`
0.12.0; `vello_gpu`, `vello_cpu` and `vello_common` 0.4.0 with `glifo`
0.5.0 (Vello's sparse-strips renderers and their glyph crate);
`vello_hybrid` 0.2.0 is the old name of `vello_gpu`. `glyphon` 0.12.0, on
`cosmic-text` 0.19.0. `swash` 0.2.10, `etagere` 0.3.0, `pollster` 1.0.1,
`png` 0.18.1. By `cargo tree`, `vello` 0.12.0, `vello_gpu` 0.4.0 and
`glyphon` 0.12.0 all resolve to wgpu 30.0.2, so one wgpu pin agrees with
every current candidate.

| Requirement | Vello sparse strips (`vello_gpu`, `vello_cpu`, `glifo`) | Vello classic (`vello`) | `glyphon` | Ours: atlas and quads on wgpu, `swash` |
|---|---|---|---|---|
| Draws glyphs we shaped, by font bytes, face index, size, coordinates, glyph id and position | Yes (seen, on `vello_cpu` with a fixture font) | Yes (read) | **No**: a text area is a `cosmic_text::Buffer`, shaped by cosmic-text and naming its own font ids; the only other way in is a custom glyph whose bitmap we rasterise (read) | Yes (seen: `swash` rasterised glyphs of three fixture fonts by id) |
| Subpixel (LCD) antialiasing | **No**: nothing in `glifo`, `vello_common`, `vello_cpu` or `vello_gpu` rasterises per channel (read); black text on white through `vello_cpu` gave 331 inked pixels, none with red, green and blue apart (seen) | **No** (read) | **No**: a subpixel mask from swash is "not implemented yet" and treated as a plain mask (read) | Yes (seen: swash's subpixel format gave a mask of a coverage for each channel that differs from the alpha one) |
| Colour glyphs | COLR and bitmaps (read) | Yes (read) | Through cosmic-text and swash (read) | COLR version 0 layers and colour bitmaps; not COLR version 1 (read; not run: no fixture font has a colour glyph) |
| Glyphs rasterised once and reused | An atlas cache exists, off by default and documented as "highly experimental and not recommended for external use"; without it outlines are cached and rasterised every frame (read) | Outline encodings cached; rasterised on the GPU every frame (read) | Yes (read) | Yes, ours |
| A few horizontal subpixel positions | 4 buckets (read) | Not applicable | cosmic-text's bins (read) | 4, ours (seen: the four offsets gave four different masks) |
| Glyphs in use never evicted; a bound on memory | Evicts by age in frames; the eviction settings are not the caller's (read) | No raster cache | Least recently used, skipping glyphs in use; the atlas grows to the device's largest texture (read) | Ours |
| Retained scenes, or draw data kept per row | The scene is rebuilt each frame; no retained fragment in its public API (read) | A scene can be appended to another (read) | Rebuilt each frame (read) | Per-row quads, ours |
| A path for a machine with no GPU | `vello_cpu`: another renderer, sharing the glyph crate (seen) | None: it needs a wgpu device and compute shaders (read) | None | The quads are plain data, composited on the CPU by a few lines of ours |
| Licence | `Apache-2.0 OR MIT` | The same | `MIT OR Apache-2.0 OR Zlib` | `swash`, `zeno`, `yazi`: `Apache-2.0 OR MIT` |

**The swash spike** (seen). On the Noto Sans, Noto Sans JP and Noto Emoji
fixtures: an alpha mask and a subpixel mask for each glyph; four
different images for the four quarter-pixel offsets; a different image
for the Noto Emoji glyph at two places on its weight axis; more ink when
emboldened; a wider image with a 14 degree skew; the same bytes when
asked twice. The checksums it printed were identical on macOS and in the
Linux container, both aarch64. swash's glyph id is 16 bits.

**The wgpu spike** (seen). With no window, a triangle drawn to a 4 by 4
sRGB texture through a shader that blends with two sources (a colour and
a coverage for each channel), read back:

| Where | Adapter | Result |
|---|---|---|
| macOS, the development machine | Metal, with dual-source blending | White text at coverage (1, 0.5, 0) over black is `[255, 188, 0, 255]`: blended per channel, in linear light |
| macOS, asked for a fallback adapter | None: Metal has no software adapter | |
| The gate's Linux image (Debian 13, aarch64) as it is | None: no Vulkan or OpenGL driver is installed | The binary still builds and links with cargo alone; wgpu loads Vulkan and EGL at run time |
| The same image with Mesa's software Vulkan driver installed | Vulkan on llvmpipe, with dual-source blending | `[255, 187, 0, 255]`: one level from Metal's |
| Anywhere, wgpu's no-op back end (its `noop` feature) | A back end that validates every call and draws nothing | The draw passes and reads back zeros; a shader that needs a feature the device was not given is refused with wgpu's validation error |

So wgpu has no software renderer of its own: a machine with no GPU and
no driver has no adapter. That decides how the renderer is tested
([text-and-display.md](text-and-display.md), "The renderer, as built").

**Why ours.** Subpixel text is the requirement none of the three meets.
Two more counts against the first candidate: its glyph atlas is marked
not for external use, with eviction we cannot set, and `vello_gpu` keeps
no scene between frames, so row reuse would be ours anyway. `glyphon`
also brings a second text stack, cosmic-text, and cannot be handed
Parley's glyphs. What is ours is small and plain: glyph keys and an
eviction rule, quads kept per row, one pipeline and one shader. What is
a library's stays a library's: rasterising is `swash`, packing the atlas
is `etagere`, the GPU is wgpu.

**What else was possible.** Vello now and subpixel text later, which the
requirement rules out. `skrifa` (already in the tree under Parley) with
`zeno` in place of swash, which saves a second copy of `skrifa` and
leaves emboldening, colour layers and bitmap strikes to us. Vello for
everything but glyphs, which is two renderers for rectangles. When Vello
gains subpixel text, the `Renderer` port is what lets it in.

**Not checked.** Any x86_64 run. That a real GPU draws a whole frame's
quads as the CPU does: the spike compared one blend of one triangle.
Anything with a window. Colour glyphs from a real font. How hinted
glyphs look on a low-resolution display, which only a person at one can
say. Any timing: nothing was measured for speed.

As built (2026-11-14, the display pipeline's phase 4), in
`crates/editor-render-wgpu`: `wgpu` 30.0.2, `swash` 0.2.10, `etagere`
0.3.0 and `pollster` 1.0.1, each pinned exactly, none public
([text-and-display.md](text-and-display.md), "The renderer, as built").
What the spikes left unchecked and is now seen:

- A whole frame's quads on a real GPU against the CPU compositor. The
  fixture frame of real text, drawn by the wgpu adapter and read back,
  differs from the reference image the CPU compositor drew by at most 1
  of 255 in any channel: in 42 of its 24576 pixels on Metal (an Apple M5
  Max) and in 247 on Mesa's llvmpipe through Vulkan, in the Linux
  container. Run on demand, once each, on 2026-11-14
  ([on-demand-checks.md](../dev-practices/on-demand-checks.md)).
- The Linux build of the pins, and the tests there: the gate passes in
  the container, aarch64, with no GPU driver installed.

Still not checked: x86_64; a colour glyph from a real font; anything
with a window; how the text looks to a person at a low-resolution
display; any timing.

## Present mode and pacing

Decided on 2026-11-14 (the display pipeline's phase 4), and like the
drawing library not yet confirmed by the owner: **`Fifo`, with a frame
latency of 1, on every platform.**

**This is a decision taken by reading. Nothing has been measured.** A
present mode is a property of a window's surface, and a measurement of
one needs a window on a display. The renderer so far draws to a texture
of its own and opens no window, so no surface has been created,
configured or presented to: what follows is what wgpu's source and
documentation say at the pin, and each row says so. The measurements are
the display pipeline's phase 6's, by the steps written down in
[on-demand-checks.md](../dev-practices/on-demand-checks.md), "The present
mode, measured on a window". They may overturn the choice.

**The reasons.**

- `Fifo` is the one mode every back end has: wgpu documents it as
  supported on all platforms, and it is the only mode its OpenGL back end
  offers off Windows.
- It does not tear.
- The editor draws on demand, at most one frame for each refresh of the
  display. `Mailbox` and `Immediate` save latency by dropping or tearing
  frames that arrive faster than the display shows them, and here those
  frames are never drawn.
- A frame latency of 1 is what wgpu's documentation recommends for
  "applications like GUIs doing a small amount of GPU work each frame
  that need low latency". It leaves one refresh for the CPU and the GPU
  together, which is the cost; an editor's frame is small.

**What wgpu 30.0.2 offers, by platform and back end.** Every row was read
in the source at the pin (`wgpu-hal` 30.0.2, `wgpu-types` 30.0.2) on
2026-11-14 and not run: no surface exists to ask.

| Platform, back end | Present modes the back end reports | Frame latency the back end reports | Where it was read |
|---|---|---|---|
| macOS, Metal | `Fifo` and `Immediate` (the second by turning the layer's display sync off) | 1 to 2: the layer's `maximumDrawableCount` is the latency plus 1 | `wgpu-hal/src/metal/adapter.rs` |
| Linux, Vulkan | Whatever the surface reports, of `Fifo`, `FifoRelaxed`, `Immediate` and `Mailbox`. `Fifo` is the mode Vulkan's specification requires of every surface, which is the specification's word and was not read in wgpu | The swapchain's least image count less 1, to its greatest less 1 | `wgpu-hal/src/vulkan/swapchain/native.rs`, `conv.rs` |
| Linux, OpenGL | `Fifo` alone | Reported as 2, and ignored: the back end does not use it | `wgpu-hal/src/gles/adapter.rs` |

Windows has no row: it has not been attempted ([README.md](README.md)).

The modes wgpu names are `Fifo`, `FifoRelaxed`, `Immediate` and
`Mailbox`, and two that pick from those by what is supported,
`AutoVsync` and `AutoNoVsync`. Its documentation says `FifoRelaxed` is
supported on AMD on Vulkan, `Immediate` on most platforms except older
DX12 and Wayland, and `Mailbox` on DX12 on Windows 10, NVidia on Vulkan
and Wayland on Vulkan. The frame latency is a hint, always clamped to
the range the back end reports.

**What a surface's configuration cannot reach**, of the two macOS
techniques the survey found:

- *Presenting with the transaction during a resize.* wgpu-hal's Metal
  back end reads the layer's `presentsWithTransaction` when it takes a
  drawable and presents accordingly, so it honours the property when the
  layer already has it; nothing in a surface's configuration sets it.
- *Keeping a variable-refresh display from clocking down.* wgpu-hal's
  Metal back end has no display link and no frame-rate range: nothing
  about the display's refresh is reachable through it.

**The choice held to the code.** `present::choose` in
`crates/editor-render-wgpu` is the decision as a pure function of the
modes and the latency range a surface offers, with tests: `Fifo` from
Metal's offer, from OpenGL's and from one of every mode, and a latency
of 1 clamped into the range offered. Phase 6 configures its surface from
what that function gives.

## Risks this raises for our planned stack

These are accepted (decided 2026-11-10): wgpu stays, behind the `Renderer`
port, and a less mature library is preferred to writing our own where one
exists. The ports are what make that safe, so each risk below names the
port that contains it.

- **Parley is moving fast**: five breaking releases in six months. It has
  no tab stops, no incremental relayout, and no shipped code editor on it
  except Floem's per-line use. It stays behind the `Shaper` port, pinned,
  used as one layout per line, and tabs are handled by us. As built
  (2026-11-13): pinned at exactly 0.13.0, with fontique at the same
  version, in `editor-shape-parley`, whose crate docs say what to check
  when the pin moves. What the adapter met at that version:
  - Parley is now several crates (`parley` over `parley_engine`,
    `parlance`, `parley_data` and `parley_emoji`), so a source reference
    names the crate as well as the file.
  - It breaks a line at a carriage return alone, at U+2028 and at U+2029,
    even when asked for no width. An editor's rows end at line feeds
    only, so these reach a shaper as content: the adapter hands Parley a
    stand-in of the same length for each.
  - It makes every line at least as tall as the layout's default style,
    as CSS does. One layout per line with font 0 as the default style
    would hold every row to font 0's height: the adapter's default style
    has no height, and every byte states its font.
  - A ligature's glyph belongs to its first character and its later
    characters have none; in a right-to-left run those come first on the
    line, so the adapter places the glyph at the leftmost of them.
  - On Linux fontique links the system's fontconfig at build time unless
    its feature `fontconfig-dlopen` is on, which the adapter turns on, so
    the build needs cargo alone.
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
  as immature. It was the first candidate for drawing and glyph caching
  behind the `Renderer` port, and we were to write our own atlas only if
  it could not meet a requirement (row reuse, subpixel text, bounded
  caches). Checked on 2026-11-13 at its current versions, it cannot meet
  one: neither of its renderers draws subpixel text, and its glyph atlas
  is marked not for external use. So the atlas and the quads are ours
  ("The drawing library, as chosen"); the port still lets Vello in when
  that changes.
- **Very long lines** are unsolved in Helix and were a Parley bug until
  recently. Per-line layout needs a bound.

## Choices this leaves open

- **Rope**: decided 2026-11-12, and no longer open: `ropey` 2.0.0-beta.1,
  behind `editor-text`'s own types
  ([text-and-display.md](text-and-display.md), "Text", as built). What the
  survey found: `ropey` 1.x is stable but indexed by character and unchanged
  since 2023; 2.0 is in beta, which is not in itself a reason against it. Zed's summarised tree serves text and display
  layers with one structure, and whether the display layers get a tree of
  their own is still open. The boundary wants byte offsets either way,
  since Parley, tree-sitter and language servers all do.
- **Tabs**: expand before shaping, use inline boxes, or split runs.
- **Height of lines not yet laid out** when wrapping or line heights vary:
  estimate and correct, or lay out ahead in the background.
- **Damage**: redraw a retained scene in full each frame (Warp reports
  1.9 ms), or report damaged regions to the compositor (Alacritty). As
  built (2026-11-14) the whole frame is drawn on every draw, from quads
  kept per row, and no damage is reported; whether that is enough is for
  the measurements of phase 6.
- **Present mode and pacing** through wgpu on each platform: decided
  2026-11-14, and no longer open as a choice: `Fifo` at a frame latency
  of 1 ("Present mode and pacing", above). It was decided by reading and
  has not been measured; the measurements are phase 6's.
