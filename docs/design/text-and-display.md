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

All but the last item are built, as the crate `editor-text`: the rope and
the text model (decided 2026-11-12), transactions with the edit log, and
anchors, markers and selections (both decided 2026-11-13). The undo tree
is not.

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

- A text has a *revision*. A new text is at 0, and every accepted
  transaction adds one, however many changes it has and one that changes
  nothing included. A refused one adds none, and changes nothing.
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

**Change sets.**

- A *change set* is an edit as a walk over the whole text: changes that
  retain the next bytes, delete them, or insert text, with lengths in
  bytes. This is Helix's model, and the code is ours. No library fits
  (crates.io, 2026-11-12): `helix-core` is published only as a placeholder;
  `operational-transform` 0.6.1 counts characters over a string and maps no
  position; `xi-rope` 0.3.0 is unmaintained and is deltas over its own
  rope; `diamond-types` and `loro-delta` are CRDTs, which
  [rendering-prior-art.md](rendering-prior-art.md) sets aside; and Zed's
  crates are not published. None counts in bytes over our rope, and the log
  with its points, patches and provenance, which is most of the work, is in
  none.
- It is kept in one *normal form*, by the pushes that build it: no change
  of length zero, no two neighbours of one kind, and where bytes are
  replaced the insert is before the delete. So two change sets that do the
  same thing in the same places are equal as values.
- A change set *fits* a text only when it is for the text's length and
  every boundary between two of its changes is a position. One that stops
  short is refused, not padded with a retain, so a change set built for
  another state of the text is caught where the lengths differ.
- *Compose* is the change set that does one and then another; text the
  first inserts and the second deletes is in neither. *Invert* is the one
  that undoes a change set, given the text before it for the bytes it
  deleted. Composition is associative and the inverse of an inverse is the
  change set, as values.
- A position is *mapped* through a change set with a bias, which says which
  side of text inserted at it the position stays on:

  | Where the offset is | Bias before | Bias after |
  |---|---|---|
  | In retained text, or at its start with nothing inserted there | Moves with the text | The same |
  | Where text is inserted and nothing deleted | Stays before the insertion | Goes after it |
  | At the start of, or inside, a range that is replaced | The start of the replacement | The end of the replacement |
  | At the start of, or inside, a range that is deleted with nothing inserted | The point the range collapsed to | The same |
  | At the end of a deleted or replaced range | After the replacement | The same |

- Mapping through a composition is not always mapping through each change
  set in turn, so a position that must survive several edits is mapped at
  each one. That is what an anchor is.
- Many positions are mapped in one walk of the change set by a *mapper*,
  which keeps its place in it and answers as the mapping of one position
  does, in any order. A text's markers are mapped through it; the display
  pipeline's cache keys are what else it is for.

**Transactions.**

- A *transaction* is a change set and, optionally, the selection before it
  and the selection after it. Applying one is the one way a text changes,
  and it is all or nothing: the changes are made to a clone of the rope,
  which shares the text's nodes, and the clone takes the text's place only
  once the change set and both selections are accepted.
- The checks are made in a fixed order: the change set fits; every end of
  the selection before is a position of the text before; every end of the
  selection after is a position of the text after.
- A *replace* (an insert or a delete at the Lean port) is the transaction
  with that one change and no selection.
- A transaction's selections are of the selection type below, with its
  shape. A transaction carries them and the text holds neither: nothing
  reads a transaction's selections yet; undo will.
- An accepted transaction moves every marker the text holds, and a refused
  one moves none.
- Because a transaction is applied to a clone, an edit copies the nodes
  from the root to a leaf whether or not a snapshot is held: 4,761 bytes
  allocated for one insert into a megabyte of text, where an edit in place
  with no snapshot held was 1,048.

**Anchors and markers.**

- An *anchor* is an offset and a bias. It is mapped at each transaction,
  eagerly, as Emacs moves its markers.
  - Not an id into the text's history, resolved when read (Zed's anchors):
    that needs every inserted run to have an identity, the CRDT structure
    [rendering-prior-art.md](rendering-prior-art.md) sets aside.
  - Not a revision and an offset resolved through the log: the log keeps
    coalesced ranges and no change sets, and forgetting would strand every
    anchor older than the horizon.
- A *marker* is an anchor or a selection that a text holds, under an id the
  text gives out and never uses again. "Text, undo history, anchors: Rust,
  behind handles" ([lean-runtime.md](lean-runtime.md)), so the text holds
  them. A marker can be read back, put somewhere else or made the other
  kind under the same id, and given up.
- Whose an id is. In `editor-text` an id is a number, and each text numbers
  its own markers: a text has no name there, and its caller holds the text
  itself. The Lean text port is where a text has a name, so there a marker
  id is the text's id and that number, and a text refuses another text's id
  with `noSuchMarker` even where it holds a marker under the same number.
  The port owns that rule (`MarkerId.numberIn?` in `lean/Editor/Text.lean`);
  the model and the real binding both look a marker up through it, and the
  port's contract holds both to it. So an id Lean holds for one text cannot
  read, replace or give up another text's marker.
  - Not one counter for every text: in `editor-text` that is state shared
    by every text in the process, which makes the numbers a test sees
    depend on what else ran, and the model would need a counter of its own
    to match.
- A marker is refused unless it is in the text as it is: an anchor at a
  position, a selection with every end at one. So a marker read back is
  always at positions of the text. That is what "in bounds" means.
- Marking, placing and giving up are not edits: no revision, no log entry.
  A snapshot carries no marker.
- Order: two anchors of one bias never pass each other, and an anchor that
  stays before inserted text never passes one that goes after it and was at
  the same or a later offset. An anchor that goes after and a later one
  that stays before swap when one replacement covers both, or text is
  inserted where both are. No rule could avoid that: a deletion brings the
  two to one point, and a later insertion there must part them by bias.
  Emacs markers of the two insertion types do the same.
- Cost: one transaction costs the ends held plus its changes. The ends are
  sorted by offset and mapped in one walk. Measured: 32 bytes allocated for
  each of ten thousand anchors, on a megabyte of text, beyond what the same
  transaction allocates with none.
- Who holds what, later: a view's selection, a scroll position, a comment's
  place and a jump-list entry are each a marker Lean holds the id of. A Rust
  consumer that holds positions of its own (layout's cache keys) maps values
  with the mapper.

**Selections.**

- A *selection* is one or more ranges, each two byte offsets (an anchor,
  the end that stays, and a head, the end that moves), the index of the
  primary one, and one *shape* for them all: exclusive, inclusive, line or
  block. A Vim state has one shape, so a selection has one.
- It is kept in one form, made by its constructor, which has no text and
  so judges offsets alone:
  - sorted by start, then by end;
  - ranges that overlap are one, from the lowest start to the highest end.
    In the exclusive shape two ranges overlap when the later starts before
    the earlier ends, or both start at one offset: two cursors at one place
    are one, a cursor at the start of a range is in it, and ranges that only
    touch stay two. In the other shapes both ends are on characters, so two
    overlap when the later starts at or before the earlier's end;
  - a merged range points the way the primary did if the primary is one of
    those it is made of, and otherwise the way the first of them did. A
    range with equal ends points forward;
  - the primary is the range the one given as primary ended in.
- A selection is checked against a text in that form. An end of a range
  that merged into another is no end of the selection, so it is not looked
  at: nothing clamps, and nothing is refused for an end that is gone.
- A selection is mapped through a change set by mapping each end as an
  anchor and making the form again, so ranges an edit brought together are
  one. The ends are stored as offsets, and the bias of each follows from
  the shape:

  | End | Bias | So that |
  |---|---|---|
  | Both ends of an exclusive range with equal ends (a bar cursor) | After | Text another author inserts at the cursor is before it |
  | The start of a non-empty exclusive range | After | Text inserted at either edge stays outside the range |
  | The end of a non-empty exclusive range | Before | |
  | Both ends in the other shapes | After | An end is on a character, and stays on it when text is inserted before it |

  The two ends of a non-empty exclusive range are the one pair that can
  pass each other, when everything of the range is replaced at once. The
  range is then a cursor at its mapped start, after the replacement.

**What a selection covers, and how evil maps onto it.**

- The ends of a range say where two cursors are. What is selected is
  computed against a snapshot, as *extents*: ranges of bytes, sorted, with
  those that overlap made one.
- A *cell* is the unit a cursor is on: one character, or a carriage return
  and the line feed after it together. A character is a Unicode scalar
  value, as everywhere at the port, and not an extended grapheme cluster.
  One private module has the rule. A row's *content* is its bytes without
  its line break.

  | Shape | Covers, for a range from `start` to `end` |
  |---|---|
  | Exclusive | `start..end` |
  | Inclusive | From `start` through the cell at `end` |
  | Line | From the start of `start`'s row to the end of `end`'s row, and through its line feed if it has one |
  | Block | For each row from `start`'s to `end`'s, one extent: with the anchor's and the head's columns counted in cells from their rows' starts, from the lower column through the cell at the higher, cut off at the row's content. A row too short for the lower column gives an empty extent at the end of its content |

  | Evil | Representation |
  |---|---|
  | Insert state, Emacs state | Exclusive, a range with equal ends at the bar |
  | Normal state | Inclusive, a range with equal ends at the start of the character the cursor is on |
  | Visual, character-wise (`v`) | Inclusive: the anchor on the character where it began, the head on the character under the cursor, in either order |
  | Visual, line-wise (`V`) | Line, with the same two ends, so the columns survive leaving the state |
  | Visual, block-wise (`C-v`) | Block, the two ends its corners |
  | What a motion gives an operator (`dw`) | Exclusive, or inclusive or line by the motion's type |
  | Several cursors | Several ranges of the state's shape |

- The cases:
  - The last character of a line. In `"ab\ncd"` the cursor at 1 covers
    `1..2`, and the line feed is outside. In `"ab\r\ncd"` the last character
    is still `b`.
  - On the line break, where `v$` puts the head: at 2 in `"ab\ncd"` it
    covers `2..3`, and in `"ab\r\ncd"` it covers `2..4`, both bytes.
  - An empty line. In `"a\n\nb"` the cursor at 2 covers `2..3`, the line
    feed, which is what `v` on an empty line selects. Line-wise there:
    `2..3` too.
  - The end of the buffer. A cursor at the text's length (an empty text, or
    the empty last row of a text that ends in a line feed) covers nothing.
    Line-wise on a last row with no line feed stops at the text's end.
  - A character of several bytes is one cell: in `"a😀b"` the cursor at 1
    covers `1..5`.
  - Block, on `"abcd\nx\nabcd"` from 1 to 9 (columns 1 and 2): `1..3`,
    `6..6`, `8..10`.
- No end is clamped. Evil's rules that are not the representation's stay in
  Lean with the command loop: keeping the normal-state cursor off the line
  break, what each operator does with an extent (whether `dd` on a last row
  takes the line feed before it), `curswant`, and the motions, which must
  move by the same cell.
- Block-wise here is the shape, its two corners and its extent with columns
  counted in cells. On text with no tab and no wide character that is Vim's
  block. What is left is in the open questions.
- No library: anchors and selections are ours, on Helix's model
  ([rendering-prior-art.md](rendering-prior-art.md)). crates.io, 2026-11-13:
  the crates that have selections (`texera-core`, a port of CodeMirror's
  state; `kode-core`, an editor core on `ropey`) bring their own buffer and
  change types. `unicode-segmentation` 1.13.3 and `unicode-width` 0.2.3 are
  not added; the open questions say why.
- Across the boundary a selection's words carry its shape, a marker is
  words in both directions, and extents come back as words. The text port
  has four requests for markers and one question for extents, with thirteen
  and ten properties in its contract.

| Piece | Where |
|---|---|
| The text model, and where an addition goes | The crate docs of `crates/editor-text/src/lib.rs` |
| The rope library, behind a private type | `crates/editor-text/src/rope.rs` |
| A text, applying a transaction, and its revision | `crates/editor-text/src/text.rs` |
| A snapshot and its reads | `crates/editor-text/src/snapshot.rs` |
| Rows and points | `crates/editor-text/src/point.rs` |
| Invalid bytes as escapes | `crates/editor-text/src/bytes.rs` |
| Change sets: the normal form, compose, invert, map, and the mapper | `crates/editor-text/src/change.rs` |
| A transaction, and the selections it carries | `crates/editor-text/src/transaction.rs` |
| An anchor | `crates/editor-text/src/anchor.rs` |
| The markers a text holds and moves | `crates/editor-text/src/marker.rs`, and `Text::mark`, `marker`, `place` and `unmark` in `text.rs` |
| A selection: its shape, its form, and mapping it | `crates/editor-text/src/selection.rs` |
| The cell, and a row's content | `crates/editor-text/src/cell.rs` |
| What a selection covers | `crates/editor-text/src/extent.rs` |
| The edit log: entries, origins, tracing, forgetting | `crates/editor-text/src/log.rs` |
| Edits and patches, and composing them | `crates/editor-text/src/patch.rs` |
| The properties, against a `String` | `crates/editor-text/tests/properties/`: the text in `main.rs`, the laws of change sets in `changes.rs`, the log in `log.rs`, anchors and markers in `anchors.rs`, the selection's form, its mapping and its extents in `selections.rs` |
| What a snapshot, a transaction, a pull and moving markers cost, counted in bytes allocated | `crates/editor-text/tests/snapshot_cost.rs` |
| The text and the snapshot as handles for Lean | `crates/editor-ffi/src/document.rs`, `crates/editor-ffi/src/snapshot.rs` |
| A transaction and the log across the boundary, as words | `crates/editor-ffi/src/transaction.rs`, `crates/editor-ffi/src/log.rs`, `crates/editor-ffi/src/words.rs` |
| Markers and extents across the boundary, as words | `crates/editor-ffi/src/marker.rs`, and `editor_ffi_snapshot_extents` in `snapshot.rs` |
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

### As built

The log is built (decided 2026-11-13), in `editor-text`, and Lean reaches
it through the text port. Layout and parsing do not exist yet, so Lean is
its one consumer; nothing produces an origin yet either, and the reload
from disk above is not built.

**An entry** is one applied transaction: the revision it produced, its
origin, and its edits.

- An *edit* is one changed range, for each run of deletes and inserts
  between two retains of the change set: a span of the text before and a
  span of the text after, each as byte offsets and as points with their
  columns in bytes. An insertion has an empty old span and a deletion an
  empty new one. No text is stored.
- That is four points an edit, not the three tree-sitter takes: in a
  transaction of several changes, a change starts at different points in
  the two texts. The three are derived (`Edit::input_edit`), for edits fed
  to a parser in order: the start is the new start, and the old end is the
  new start moved on by the extent of the old range. This is checked
  against the texts, not against tree-sitter, which is not a dependency
  yet.
- The old points are read from the rope before the changes and the new ones
  from the rope after.

**Origin.**

- An origin is an opaque 64-bit number. It is an argument of applying a
  transaction, not part of the transaction: the inverse of an agent's
  transaction, applied by a person's undo, is the person's.
- The library stores it in the entry and returns it, and no function of the
  library reads it. What a number stands for (which command, which agent
  session and tool call) is a table Lean keeps, where that data lives. A
  number costs eight bytes and no allocation for each keystroke.
- A replace is recorded with 0. The Lean port names that
  `Origin.unattributed`; to the library it means nothing.

**Pulled patches.**

- A consumer asks what changed since a revision and gets one *patch*: edits
  whose old spans are ranges of the text then and whose new spans are
  ranges of the text now, in order, no two overlapping or touching. Changes
  that came to overlap or touch are one edit, and text inserted and deleted
  again in between is in none.
- *A subscriber is a revision* the consumer keeps. Nothing is registered
  with the text, so a subscriber costs the text nothing, nothing is queued
  for it, and there is nothing to release.
- Patches are composed in coordinates, an offset with its point, by a walk
  over the text between them. Every step is a coordinate plus the extent
  between two later coordinates of one text, which is exact for points;
  nothing is moved backwards across a line. Change sets are not composed
  for this: the log keeps no text, and lengths alone cannot give the points
  of a text that no longer exists.
- Many entries are composed pairwise as a balanced tree. A pull across a
  thousand entries was measured to allocate 957 bytes an entry.

**Provenance.**

- A range of the text as it is now is *traced* to the entries that wrote
  it: it comes back cut into pieces, each with the revision and the origin
  of the transaction that inserted its bytes. Text that was deleted is in
  no piece.
- The log is walked back from its newest entry, carrying the pieces no
  entry has claimed yet. No second structure is kept beside the text, so an
  edit pays nothing for provenance; a trace costs the entries walked times
  the pieces carried, which is a review's price and not a keystroke's.

**The bound.**

- *Forgetting* drops the entries up to a revision and moves the log's
  *horizon* there. It is the log's one bound: the library never drops an
  entry by itself. When to forget is Lean's policy, since Lean knows which
  consumers it has and whether a review is open.
- Behind the horizon a patch is refused, so a consumer that far behind
  reads a snapshot whole and subscribes again. Bytes written at or before
  the horizon trace to "earlier than the horizon", with its revision, never
  to nobody.
- Until Lean forgets, the log grows by one entry a transaction. A thousand
  one-change transactions on a megabyte of text were measured to allocate
  3,651 bytes each, the tree's nodes included; an entry itself is its
  origin and 96 bytes an edit.

Nothing calls forget yet outside tests.

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
- **Who forgets the log, and when.** The log is bounded only by Lean
  forgetting ("The edit log", as built), and nothing does yet. The command
  loop or review decides, knowing which consumers are behind and whether a
  review still needs the provenance.
- **Provenance older than the horizon.** Forgetting loses who wrote the
  older bytes. Whether that is kept somewhere cheaper, such as a run map
  beside the text or a record written when a commit is made, is for review
  to decide.
- **The table of origins.** An origin is a number whose meaning is Lean's.
  The table from numbers to commands, agent sessions and tool calls arrives
  with the command loop and agent hosting.
- **Rebasing a stale transaction.** A transaction built for an older
  revision is refused by its length. The log keeps no text, so it cannot
  supply the change sets to rebase through; the undo history, or the first
  job that proposes an edit, settles where they come from
  ([concurrency.md](concurrency.md)).
- **Points in UTF-16 in an edit.** An edit's points count columns in bytes.
  A language server client converts with the snapshots of the two
  revisions, or the log grows a second pair of points.
- **Extended grapheme clusters as the cell.** A cursor should rest on a
  cluster, and a cell here is a character: a letter and a combining mark
  after it are two. `unicode-segmentation` (1.13.3) was not added because
  what a selection covers is a question of the text port, so the pure Lean
  model must answer it without the Rust library, and UAX #29 in the model
  is out of proportion to what it would buy now. The rule is in one private
  module, and the motions must use the same cell, so it is decided once,
  with the command loop's motions and the display pipeline's shaping, which
  knows clusters, in view.
- **A block's columns by display width, and a block to every line's end.**
  A block's columns are counted in cells. Vim counts them in display
  columns, which needs tab stops (a view's setting) and character widths
  (`unicode-width`, 0.2.3, not added), neither of which exists before the
  display pipeline; and `$` in block-wise visual runs every row to its end.
  Both are additions: a unit for the block's columns, as a point's column
  has one, and a flag.
- **How many markers a text should hold.** Every transaction costs the ends
  held. There is no bound and no policy, and no marker survives a restart.
  The command loop, and whatever holds comments and jump lists, decide.
- **A marker set by a transaction.** A transaction could name a marker to
  set to its selection after. It does not: the author places its marker
  with a second request, and the one writer path stays one argument
  simpler. Undo, which restores a selection, may want it.
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
