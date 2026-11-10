# Text and display

The data structures every feature reads, and the path from them to pixels.
All of this is the Rust library. Lean holds handles to buffers' text and
tells the library what each view shows; the library stores, lays out and
draws it.

## Text

- **Rope** with cheap immutable snapshots. Byte, character and line
  indexing, and conversion between byte offsets and (row, column) points.
- **UTF-8**, with invalid bytes in a loaded file preserved so an unedited
  save is byte-identical. Line endings are preserved.
- **Transactions**: change sets (retain, insert, delete) that can be
  applied, composed, inverted, and used to map a position through an edit.
- **Anchors**: positions that move with edits, with a bias for which side of
  an insertion they stick to. Selections, scroll positions, comment
  locations and jump-list entries are all anchors.
- **Selections**: any number, each an anchor and a head, able to express
  evil's character-wise, line-wise and (later) block-wise semantics.
- **Undo tree**, with group boundaries set by Lean (one insert session is
  one step) and selections restored.

Lean reaches these through a text interface that also has a pure Lean
model, so commands can be tested and reasoned about without the library
(see [lean-runtime.md](lean-runtime.md)).

## The edit log

Consumers (layout, parsing, Lean) do not receive each edit. Each asks for
what changed since it last looked and gets one coalesced patch of old and
new ranges, so there is never a backlog. This is Zed's model; see
[rendering-prior-art.md](rendering-prior-art.md).

Every transaction applied to a buffer is recorded with:

- the revision it produced;
- its changes as byte ranges and (row, column) points, which is the shape
  tree-sitter's incremental reparse needs and what layout uses to
  invalidate cached lines;
- its **origin**: a human command, an agent session and tool call, a
  formatter, a reload from disk.

The origin field is the basis of review-time provenance: any range of text
can be traced to the edits that produced it and who made them. Existing
tools attribute per prompt or per commit because they do not own the
buffer; an editor can attribute per edit. It costs one field now and is
hard to add later.

Edits made outside the editor (an agent writing the file directly, a `git
checkout`) arrive as a reload from disk. The library diffs old against new
text and records the result as one transaction, so anchors move sensibly
and the origin can be filled in when the source is known (an ACP tool call
reports the path it wrote).

## Buffers and excerpt buffers

A **buffer** is text plus a name, an optional file, buffer-local values and
modes. The text is a Rust object; the rest is Lean state.

An **excerpt buffer** is a buffer assembled from ranges of other buffers,
each shown under a header, and editable in place: an edit in an excerpt is
an edit to the underlying buffer. One primitive serves search results,
references, diagnostics, an agent's multi-file change, a review queue, a
code tour, and "everything this plan step touched". Zed's multibuffers are
the precedent, and the comprehension research favours bringing code to the
reader over making the reader navigate to it.

Excerpts are held by anchors into their source buffers, so they stay
correct as the sources change. A source can be a file at a past revision
(read-only), which is how a review shows code as it was when reviewed.

## Decorations

Lean describes how text should look; the library merges and draws it.
Decorations come from **sources**, each producing data for a range of a
snapshot. Sources are independent and versioned, so a slow one (syntax
highlighting after a reparse) never blocks a fast one (the selection).

| Kind | Examples |
|---|---|
| Span face | Syntax highlighting, selection, search matches, diff added/removed |
| Inline virtual text | Type hints, an evil pending-operator hint |
| Block between lines | A review comment thread, a hunk's accept/reject controls, a permission prompt, an excerpt header |
| Gutter mark | Diff marks, comment markers, "an agent wrote this" marks, breakpoints |
| Replacement | Folded regions, ligature-like substitutions, inline images |
| Line attribute | Background for the current line, a dimmed unreviewed region |

A **face** is a set of optional attributes (family, size, weight, slant,
colours, underline, strike-through, line height) with a documented merge
order. Faces are named and defined in Lean.

Blocks are laid out by the library from a small layout description that Lean
supplies (text runs, rows, columns, buttons with a command name). They are
not arbitrary drawing code.

## Display layers

Between a buffer's text and what is laid out sit transformations: inline
virtual text, folds, tab expansion, soft wrapping, blocks between lines.
Each is a **layer** with one contract, taken from Zed: given the snapshot
and edits of the layer below, produce its own snapshot and edits, in its
own coordinate type. A position is converted between buffer and display
coordinates by walking the layers. Milestone 1 needs tabs and wrapping;
the others are added as layers without changing the ones below.

## Views

A view shows something in a window. There is more than one kind:

| Kind | Content | Notes |
|---|---|---|
| Text view | A buffer or excerpt buffer | The normal case: pixels, variable line heights, wrapping |
| Grid view | A terminal's cell grid | Drawn straight from the emulator's state; never copied into a buffer per frame (the `edmacs` redraw ceiling came from doing exactly that) |
| Table and list views | Rows from Lean state | The agent list, pickers, review queues. Possibly a text view over generated text plus decorations; see open questions |

Windows are arranged in a split tree per frame, held in Lean. A view's
scroll position is an anchor. Layout invariants (for example, a minibuffer
exists) are part of the data model, and operations that would break one
return a typed refusal.

### The scene

After each command Lean publishes a **scene** to the library: the
rectangle of each view, the text snapshot or terminal it shows, its scroll
anchor, its cursors and selections, and the decoration sets that apply.
Rendering works from the last published scene on its own thread, so
painting never waits on Lean. Unchanged parts are sent as the
same handles, so publishing costs in proportion to what changed.

Commands also need answers from layout: the visual line below the cursor,
the position under a mouse click, how many lines fit in a view. These are
synchronous calls into layout, answered in the same call, laying out on
demand if the lines are not cached. Lean never keeps its own copy of
layout. Xi's experience is the reason: an editor core that learned about
layout through messages spent months on scrolling and resize bugs.

## Layout and rendering

- Only visible lines are laid out, one layout object per buffer line.
  Shaping is invalidated by text and font changes, line breaking by width
  changes, and neither by paint-only changes. Cache entries are moved
  through edits, not cleared. Lines not yet laid out are estimated and
  corrected lazily.
- The layout cache is shared: the editor thread's queries and the render
  thread's frames use the same entries.
- Slow work that affects layout (wrapping a huge paste, a reparse) gets
  about a millisecond to finish within the frame; after that the frame is
  drawn from an approximation and corrected.
- Shaping goes through a `Shaper` port (Parley and fontique as the planned
  adapter): font fallback, ligatures, complex scripts, bidirectional text,
  mixed proportional and monospace fonts.
- Drawing goes through a `Renderer` port (wgpu as the planned adapter):
  glyphs rasterised once into an atlas and drawn as quads, plus rectangles.
- Nothing is drawn when nothing changed. Frames are drawn on demand, at
  most one per display refresh, by a scheduler that is a pure function of
  its inputs and so is tested with a fake clock.
- The frame layout hands the renderer is an immutable value, passed through
  a mailbox where a newer frame replaces one not yet presented. It is plain
  data, so it can be recorded and compared in tests.
- Rows carry a content hash, and the renderer reuses the geometry of rows
  that did not change, so scrolling and cursor movement rebuild nothing.

### Headless rendering

`edmacs` shipped visible bugs past about 400 green tests because batch
Emacs has no real layout. Here a headless renderer adapter runs the same
layout code with real font metrics and produces frames with real pixel
geometry, so tests can assert where things are, not only what state says.
A fake shaper with fixed-width glyphs covers unit tests; the headless
adapter covers the cases that depend on real metrics.

## Instrumentation

The library keeps a frame journal (timestamps at input, draw and present
for every frame) and exposes input-to-frame latency, frame time, layout
cache hit rate, counts of rows laid out again, and which ranges of a buffer have been visible in a view
and for how long. The last one supports review: "you have not looked at
these hunks" is a fact the editor can state.

## Open questions

- **Rope choice** (`ropey`, `crop`, or a sum tree in the style of Zed's).
  Display layers, excerpt buffers and decoration interval trees favour a
  sum tree; `ropey` 1.x is indexed by character where the boundary wants
  bytes.
- **Tabs**: Parley has no tab stops. Expand before shaping, use inline
  boxes, or split runs.
- **The other choices the survey left open** are listed in
  [rendering-prior-art.md](rendering-prior-art.md).
- **Table and list views**: a dedicated view kind, or text views over
  generated text? A dedicated kind is faster for long lists; text views
  reuse evil motions and search for free.
- **Block layout language**: how much does Lean get to describe? Text runs
  and buttons are enough for review comments; a diagram needs more.
- **Viewed-range tracking** granularity and whether it is on by default.
- **Large files and long lines**: what is the plan when a single line is
  megabytes?
- **Accessibility**: screen-reader support (AccessKit) has to be designed
  into the view model, not added to the renderer.
