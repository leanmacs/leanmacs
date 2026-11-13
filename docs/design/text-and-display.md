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

### As built

The first two items are built (decided 2026-11-12), as the crate
`editor-text`. Transactions, anchors, selections and the undo tree are not.

**Positions.**

- An *offset* is a byte offset into the text's UTF-8. A *position* is an
  offset that is a character boundary within the text, its end included.
  Offsets are the unit at the Lean boundary: Parley, tree-sitter and
  language servers all want bytes or UTF-16.
- A *row* begins at the start of the text and after each line feed. A text
  has one more row than it has line feeds: an empty text has one row, and a
  text that ends in a line feed has an empty last row. A carriage return is
  an ordinary character of its row, so the rows of a CRLF file end in one,
  and a carriage return alone starts no row. This is tree-sitter's rule,
  which the edit log needs.
- A *point* is a row and a column counted from the row's start: in bytes
  (`Point`) or in UTF-16 code units (`PointUtf16`). They are two types, so
  the units cannot be mixed.
- A conversion answers only for a position and clamps nothing: clamping is
  Lean's policy. An offset inside a character or past the end has no point.
  A point in a row the text does not have, past the end of its row, inside
  a character or between the two code units of one has no offset.
- There is no character index. Nothing at the boundary counts in
  characters.

**The text model.**

- A text is always valid UTF-8. The rope, shaping, tree-sitter and a Lean
  string all want that.
- A byte of a loaded file that is not part of valid UTF-8 is kept as one
  reserved character, its *escape*: the byte `b`, always `0x80` or more, is
  the code point `U+10DC00 + b`, in `U+10DC80..U+10DCFF` of Supplementary
  Private Use Area-B. The scheme is Python's `surrogateescape`, moved from
  surrogates, which neither a Rust `str` nor a Lean `String` can hold.
  - In: a valid character is kept, and each byte of an invalid sequence
    becomes its escape. A valid character that is itself in the reserved
    range is kept as its four bytes, each escaped, so the mapping is
    one-to-one.
  - Out: an escape becomes its one byte, and every other character its
    UTF-8.
  - So the bytes of a file loaded and saved unchanged are identical, for
    every file.
- An escape is ordinary text, so a deletion and its undo, a cut and a
  paste, a diff and a transaction carry the byte with no machinery of their
  own. A table of original bytes beside replacement characters would lose
  the byte the first time its character was deleted and restored, because
  edits carry strings.
- What that costs: in a file with invalid bytes, an offset in the text is
  not an offset in the file (an escape is four bytes of text and two UTF-16
  units); a parser or a language server sees an escape as a private-use
  character; a file that validly holds a reserved code point shows it as
  four raw bytes; and a reserved code point given as a string, typed or
  pasted, is saved as one raw byte.
- Line endings are kept as they are. Nothing is normalised on the way in or
  out, so LF, CRLF and mixed files come back byte for byte. Which ending a
  new line gets is Lean's policy, and detecting a file's dominant ending
  belongs with loading it.
- The crate takes bytes and gives bytes. Reading and writing a file is the
  file port's.

**Revisions and snapshots.**

- A text has a *revision*. A new text is at 0, and every accepted edit adds
  one, an edit that changes nothing included. A refused edit adds none, and
  changes nothing. Transactions may make one transaction the unit.
- A *snapshot* is the text at one revision. It never changes, it outlives
  its text, and it is `Send + Sync`. Taking one copies none of the text. A
  snapshot is the only thing a worker thread, a job or the renderer reads:
  a text has one writer and hands out nothing else.
- Every read is a method of a snapshot: its length, rows and points, its
  text in the pieces the rope holds it in (for search, shaping and a
  parser's read callback, with no copy), and its bytes to save.
- No job, worker or renderer reads a snapshot yet. How a job names one is
  an open question below.

**The rope.**

- `ropey`, pinned at exactly 2.0.0-beta.1, with the features for rows split
  by line feed alone and for UTF-16. It is indexed by byte, counts both in
  the tree, has edits that return an error where others panic, and shares
  its nodes between a rope and its clone.
- Against it: it is a beta, and its API can change before 2.0. `ropey` 1.x
  is indexed by character. `crop` 0.4.3 has no fallible edit, does not
  count a last empty row as a line, and has a fix for a data race that is
  in no release; it is the fallback. A summarised tree of our own was set
  aside because libraries fit; the display layers, anchors and decoration
  ranges can have one when they need it.
- One private module of `editor-text` names the library. No type of it is
  public, and `deny.toml` lets no other crate depend on it.

| Piece | Where |
|---|---|
| The text model, and where an addition goes | The crate docs of `crates/editor-text/src/lib.rs` |
| The rope library, behind a private type | `crates/editor-text/src/rope.rs` |
| A text, its edits and its revision | `crates/editor-text/src/text.rs` |
| A snapshot and its reads | `crates/editor-text/src/snapshot.rs` |
| Rows and points | `crates/editor-text/src/point.rs` |
| Invalid bytes as escapes | `crates/editor-text/src/bytes.rs` |
| The properties, against a `String` | `crates/editor-text/tests/properties/` |
| What a snapshot costs, counted in bytes allocated | `crates/editor-text/tests/snapshot_cost.rs` |
| The text and the snapshot as handles for Lean | `crates/editor-ffi/src/document.rs`, `crates/editor-ffi/src/snapshot.rs` |
| The Lean text port, its model, real binding and contract | `lean/Editor/Text.lean`, `lean/Editor/Text/` ([lean-runtime.md](lean-runtime.md)) |

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

### Text is the only layout engine

The library is a text display engine, not a GUI toolkit (decided
2026-11-11). It has no widget tree, no general layout system, no style
cascade and no focus traversal. Everything shown is text, or a box that
text layout places:

- **A block is text**: a small piece of text with faces and clickable
  spans, each span naming a command. It has no rows, columns or buttons of
  its own.
- **Tables, lists and pickers** are text views over generated text.
- **Columns are aligned with align-to stops** in text layout, the one
  primitive this adds. Tab stops are the same mechanism.
- **A popup** (completion, hover, a picker) is a text view in a floating
  rectangle that Lean places against a position it asks layout for.
- **Anything that is not text is a box.**

### Boxes

A box is a rectangle reserved by text layout, inline in a line or between
lines, plus a handle to its content. The content is one of the kinds a
view can show:

| Content | Drawn from | On a cell grid |
|---|---|---|
| Image | A texture, cached by content hash, size and scale | Its label, or a terminal graphics protocol where the front end reports one |
| Terminal grid | The emulator's cell state, as a grid view | Cells passed through |
| Text view | Another buffer, such as an editable comment draft | The same |

Three limits keep a box from becoming a widget:

- **Sizing is one pass.** The available width goes down and the box
  reports a height: the image's own, or a row count Lean sets. Nothing is
  solved for.
- **The library holds no interaction state.** A click is answered by the
  same hit-test query as any other, as a box and coordinates within it,
  and Lean decides what it means.
- **Focus is Lean's.** A terminal in a box takes keys through the same
  explicit "keys go to the terminal" state as one in a window.

Images are raster files or SVG, decoded behind an image port (`resvg` as
the planned adapter for SVG) at the display's scale. SVG generated in Lean
is the way to draw what text cannot: icons, tags, progress bars, diagrams.
Every image carries a label, which is its fallback on a cell grid and its
name to a screen reader.

Web views and video are out of scope: each needs a second compositor.

If a requirement ever calls for sizing rules or widget state in Rust, the
answer is to host the text view inside an existing toolkit on the same
stack (Masonry is built on Parley, Vello, winit and AccessKit), not to
grow our own. That would cost the terminal front end and put a second
owner of interface state beside Lean, so it is a last resort.

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

The agent list, pickers and review queues are text views over generated
text, so evil motions and search work in them. A grid can also appear
inside a text view, as a box.

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
  mixed proportional and monospace fonts. Layout takes every metric from
  this port and assumes nothing about pixels.
- Drawing goes through a `Renderer` port, which takes a device-independent
  frame (see below). The wgpu adapter rasterises glyphs once into an atlas
  and draws them as quads, plus rectangles. Rasterising, the atlas and
  glyph identities are inside that adapter, not in the frame.
- Nothing is drawn when nothing changed. Frames are drawn on demand, at
  most one per display refresh, by a scheduler that is a pure function of
  its inputs and so is tested with a fake clock.
- The frame layout hands the renderer is an immutable value, passed through
  a mailbox where a newer frame replaces one not yet presented. It is plain
  data, so it can be recorded and compared in tests.
- Rows carry a content hash, and the renderer reuses the geometry of rows
  that did not change, so scrolling and cursor movement rebuild nothing.

### The frame is device-independent

The frame carries positioned text runs with resolved faces, rectangles,
cursors and gutter marks, in layout units. It holds no atlas ids, textures
or rasterised glyphs. Which device it is drawn on is decided by the pair of
adapters behind the `Shaper` and `Renderer` ports:

| Front end | Shaper | Renderer |
|---|---|---|
| GUI | Parley, real font metrics | wgpu |
| Cell grid | Cell shaper: advance is the Unicode width, line height is 1 | Writes the frame into a grid of styled cells |
| Headless | Parley, real font metrics | Records the frame; draws nothing |

The cell grid adapter is built early, as a test renderer: a test asserts
on a frame as a grid of text. That keeps the ports honest from the start,
and a terminal front end is then that grid written to a terminal plus a
platform adapter for terminal input. Grid views pass their cells through.

The front end reports **capabilities** as plain data that Lean reads:
proportional fonts, fractional line heights, images, smooth scrolling, and
which key chords it can report. Lean and config read these instead of
assuming pixels. On cells, block heights round up to whole rows, font
sizes collapse to one, and inline images are replaced by their fallback
text.

### Headless rendering

`edmacs` shipped visible bugs past about 400 green tests because batch
Emacs has no real layout. Here a headless renderer adapter runs the same
layout code with real font metrics and produces frames with real pixel
geometry, so tests can assert where things are, not only what state says.
The cell shaper and cell grid renderer cover unit tests; the headless
adapter covers the cases that depend on real metrics.

## Accessibility

Screen-reader support is a requirement (decided 2026-11-11). Because
everything shown is text or a labelled box, the accessibility tree is
derived from the scene and layout, with no second description to keep in
step.

- **The tree is plain data built in the core**, like the frame, and handed
  to an `Accessibility` port. AccessKit is the planned adapter. Tests
  assert on the tree itself.
- **Each text view is a document node** with its laid-out lines as text
  runs, its cursor and its selections. A grid view is a terminal node. A
  popup is a node of its own.
- **Each box is a child node**: an image under its label, a terminal, or a
  nested document.
- **Each clickable span is an actionable node** named by its text.
- **Requests from assistive technology** (focus, activate, move the
  selection, scroll) are events Lean pulls, and Lean handles them as
  commands. The library does not act on them itself.
- **Announcements**: Lean posts text to be spoken, for echo-area messages
  and for state that is otherwise only visual (the evil state, "keys go to
  the terminal").

A cell grid front end is read by the terminal's own screen reader and
needs none of this.

## Instrumentation

The library keeps a frame journal (timestamps at input, draw and present
for every frame) and exposes input-to-frame latency, frame time, layout
cache hit rate, counts of rows laid out again, and which ranges of a buffer have been visible in a view
and for how long. The last one supports review: "you have not looked at
these hunks" is a fact the editor can state.

## Open questions

- **A summarised tree for the display layers.** The rope is a library's
  ("Text", as built). Display layers, excerpt buffers and decoration
  interval trees favour a sum tree in the style of Zed's; whether they get
  one of their own is for the display pipeline to decide.
- **How escape characters are displayed.** A raw byte of a file is a
  private-use character in the text. Until the display draws it as its
  byte, it shows as whatever the font has there.
- **A second row rule.** A language server counts a carriage return alone
  as the end of a line; rows here do not. The rope library can count that
  rule beside this one without the stored text changing. The language
  server client decides whether it is needed.
- **How a job names a snapshot.** The text port names one by an id in the
  editor thread's table, and the job port has no request for one. The
  first job that reads text, which is saving a file, settles it.
- **Tabs**: Parley has no tab stops. Expand before shaping, use inline
  boxes, or split runs.
- **The other choices the survey left open** are listed in
  [rendering-prior-art.md](rendering-prior-art.md).
- **Embedded terminals**: a fixed row count, or growing with output up to
  a cap? And how scrolling the buffer interacts with the terminal's own
  scrollback.
- **Box sizes** on a cell grid: which units Lean states a size in so that
  one description serves pixels and cells.
- **Capabilities**: the exact set, and whether a face or block can name a
  fallback for a front end that lacks one.
- **Viewed-range tracking** granularity and whether it is on by default.
- **Large files and long lines**: what is the plan when a single line is
  megabytes?
- **Accessibility of text not laid out**: only visible lines have layout,
  but a screen reader may want to read past the viewport. Expose the
  viewport and scroll on request, or supply unlaid-out text as well?
- **Accessibility coverage**: what AccessKit supports on each platform,
  and how its text model fits ours, have not been checked.
