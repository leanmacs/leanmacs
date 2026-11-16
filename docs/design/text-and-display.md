# Text and display

The data structures every feature reads, and the path from them to pixels.
All of this is the Rust library, but for the undo tree, which is Lean over
two requests of the library. Lean holds handles to buffers' text and tells
the library what each view shows; the library stores, lays out and draws
it.

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
- **Undo**, in two halves (decided 2026-11-13). The library keeps the
  inverse of every applied transaction and applies the inverse of a run of
  them; deleted text never leaves it. The **undo tree** is Lean: a tree of
  states over those two requests, with group boundaries set by the caller
  (one insert session is one step), branches, reverting a failed command,
  the selections to restore, and whether a text is in the state last saved.
  Every undo policy is Lean's, so another undo style is written over the
  same requests.

Lean reaches these through a text interface that also has a pure Lean
model, so commands can be tested and reasoned about without the library
(see [lean-runtime.md](lean-runtime.md)).

### As built

All of it is built. In the crate `editor-text`: the rope and the text model
(decided 2026-11-12), transactions with the edit log, anchors, markers and
selections, and the kept inverses (all decided 2026-11-13). In Lean, over
the text port: the undo tree (`lean/Editor/UndoTree.lean`, decided
2026-11-13).

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
  (`Point`), in UTF-16 code units (`PointUtf16`) or in cells (`PointCells`;
  "Motions, words and WORDs", below). They are three types, so the units
  cannot be mixed.
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
  belongs with loading it. As built (the command loop's phase 9): a buffer
  keeps one line ending, chosen when its file is opened, the file's
  dominant one, or a line feed for a file with no line break and for a
  buffer with no file. It decides one thing: the text a command inserts to
  break a line. One API operation reads it (`Target.insertLineBreak`,
  `lean/Editor/Api.lean`), every command that breaks a line calls that
  operation, and none writes a line feed itself. Nothing else is
  translated: a committed text and a pasted text are inserted as they
  are.
- The crate takes bytes and gives bytes. Reading and writing a file is the
  file port's: `editor_text::fs::Fs`, which the crate defines, with loading
  and saving over it in `editor_text::file`. A load counts the file's line
  endings (line feeds alone, and line feeds after a carriage return) and
  changes none; which is the dominant one is Lean's to say from the counts
  (`File.LineEndings.dominant`, `lean/Editor/File.lean`).
  rust-library.md, "Files and watching", has the port, the adapter and the
  rules as built. From Lean a load and a save are requests a job awaits
  ([concurrency.md](concurrency.md)), and a text is made of what was
  loaded by the text port's `adopt` and `copy`.

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
- A job reads a snapshot: the job that saves one as a file. It names a
  snapshot a command took by the command's id for it, which the file
  service finds in the table of snapshots the editor thread publishes and
  alone writes; and a job that loads a file holds the snapshot the load
  made, under an id of another kind, until its command takes it into the
  store ([concurrency.md](concurrency.md), "Sharing state"). No worker and
  no renderer reads one yet.
- A text can be made from a snapshot (`Text::from_snapshot`): it holds what
  the snapshot holds, at revision 0, with an empty log, no markers and no
  kept inverses, and it shares the rope, so it copies none of the text.
  That is how a loaded file becomes a text, and how a text is copied.

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
  shape. A transaction carries them and the text holds no current
  selection. They are kept, swapped, with the transaction's inverse, and
  applying the inverse hands one back ("Kept inverses", below).
- An accepted transaction moves every marker the text holds, and a refused
  one moves none.
- Because a transaction is applied to a clone, an edit copies the nodes
  from the root to a leaf whether or not a snapshot is held: 6,457 bytes
  allocated for one insert into a megabyte of text, the first, with its
  log entry and its kept inverse (4,761 before a transaction kept its
  inverse), where an edit in place with no snapshot held was 1,048.

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
  text gives out and never uses again. "Text, kept inverses, anchors: Rust,
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
  takes the line feed before it), `curswant`, and evil's motions. The
  motion primitives are the library's and move by the same cell ("Motions,
  words and WORDs", below); evil's motions compose them. Of these the
  resting rule, the wanted column and the motions are built
  ([keymaps-and-modes.md](keymaps-and-modes.md), "Where a cursor rests",
  "The wanted column", "Motions as built"); the operators are not.
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

**Motions, words and WORDs** (decided and built 2026-11-13).

- A *motion* is a question of a text or a snapshot: from a position to a
  position. The library answers it by walking the rope from the position, so
  a motion is as fast on a large file as on a small one, and Lean only
  composes them. Every motion moves by the text's cell, the one a selection
  is counted in, so a step forward moves over exactly what an inclusive
  cursor covers: `l` moves over what `v` selects.
- A *cell start* is a position where a cell starts: every position but the
  one between a carriage return and the line feed after it. The end of the
  text is no cell start. For the position `p` in a text of length `n`:

  | Motion | Answers |
  |---|---|
  | Next cell | The first cell start after `p`, or `n`. It is where the cell at `p` ends |
  | Previous cell | The last cell start before `p`, or 0 |

  - In `"a\r\nb"`: from 1 the next cell is 3 and from 3 the previous is 1;
    from 2, between the two bytes, the next is 3 and the previous 1.
  - A character of several bytes is one step: in `"a😀b"` from 1 the next
    is 5. A letter and a combining mark after it are two cells, so the step
    from the letter lands on the mark; that is the cell's open question.
  - The line break is a cell like any other, so these two cross lines.
    Staying on a line is `h` and `l`'s rule, and evil's.
- What a word is:
  - A *line break* is the cell that ends a row: a line feed, or a carriage
    return and the line feed after it.
  - A *blank* is a space (U+0020) or a tab (U+0009). A line break separates
    words as a blank does.
  - A *word character* is an ASCII letter, an ASCII digit, an underscore, or
    any character from U+0080 up. Every other character is *punctuation*:
    the rest of ASCII, its control characters and NUL included, and so a
    carriage return with no line feed after it.
  - An *empty line* is a row with no content that has a line break. The
    empty last row of a text that ends in a line feed has no cell and is not
    one.
  - A *word* is a longest run of neighbouring cells that are all word
    characters or all punctuation; or the line break of an empty line,
    alone. A *WORD* is a longest run of cells that are not blank; or the
    line break of an empty line, alone. A line of blanks only holds no word.
  - A word *starts* where its first cell starts and *ends* where its last
    cell starts: the position of a cursor on its last character, where `e`
    rests, and not the position after it.

  | Motion, for a word or a WORD | Answers |
  |---|---|
  | Next word start | The first start of a word after `p`, or `n` |
  | Previous word start | The last start of a word before `p`, or 0 |
  | Next word end | The first end of a word after `p`, empty lines not counted, or `n` |
  | Previous word end | The last end of a word before `p`, or 0 |

  - "After" and "before" are strict, so from a word's start the next start
    is the next word's. The next word end passes over empty lines because
    Vim's `e` and `E` do, while `w`, `b` and `ge` stop on one.
  - In `"foo.bar  x"` the words are `foo`, `.`, `bar` and `x`, and the WORDs
    `foo.bar` and `x`: from 1 the next word start is 3 and the next WORD
    start 9; the next word end is 2 and the next WORD end 6.
- Lines and the text:

  | Motion | Answers |
  |---|---|
  | Line start | Where `p`'s row starts |
  | Line end | Where the content of `p`'s row ends: where its line break starts, or `n` in the last row. This is where `v$` puts a head and `A` inserts |
  | Line first non-blank | The first position of the row's content whose character is not a blank; the line end when there is none, so the row's start on an empty line |
  | Text start | 0 |
  | Text end | `n` |

  The position of a line feed belongs to the row it ends. From the position
  between a carriage return and its line feed, the line end is the position
  before it: in `"ab\r\ncd"` the line end is 2 from 0, from 2 and from 3.
- Rows up and down, for `p` in row `r`, with a count and a column:

  | Motion | Answers |
  |---|---|
  | Rows up | In row `r - count`, or the first row when there is none: the position `column` cells from the row's start, or the end of its content when it has fewer |
  | Rows down | The same in row `r + count`, or the last row when there is none |

  - The column is counted in cells from the row's start, as a block's
    columns are, so `j` moves a cursor as a block's corner moves. A point's
    column can be counted in cells too, beside bytes and UTF-16 code units:
    how many cells of its row start before the position. That is how a
    caller learns the column to ask for. In a row whose content has `k`
    cells and that ends in a carriage return and a line feed, column `k` is
    the carriage return's position, column `k + 1` the position between the
    two bytes, and column `k + 2` names none. A row motion never answers
    past the content, whatever the column.
  - A count of 0 stays in the row: "the position at this column of this
    row". A motion past the first or the last row stops there, as Vim's
    `10k` and `10j` do, and is not refused. The empty last row of a text
    that ends in a line feed is a row like any other.
  - Vim's `curswant` is a display column. Tab stops and wide characters are
    the display pipeline's, so the text port's row motions do not answer
    it: a column they take is in cells. Evil's `j` and `k`, since the
    command loop's phase 16, use the row motions only to find the line
    (column 0), and ask the display interface for the column: the move
    query, with no lines to move and the text laid out unwrapped, answers
    the x of the cursor and the position at an x of a line ("The scene",
    as built). The wanted column they keep is that x, which Lean passes
    back and does not compute with
    ([keymaps-and-modes.md](keymaps-and-modes.md), "The wanted column").
    The open question on a block's columns still covers a block.
- At the ends of the text: where there is no such cell or word the answer
  is the end of the text going forward and 0 going back. An operator wants
  the end itself (`dw` on the last word); putting a normal-state cursor
  back on a cell is evil's.
- A motion from an offset that is not a position is refused, whichever
  motion it is, the text's start and end included.
- What is not here and stays evil's, in Lean with the command loop: which
  key runs which motion, a count as repetition, the wanted column and where
  it is kept, keeping a normal-state cursor off the line break and inside
  the buffer, `cw` acting as `ce`, `dw` on a line's last word not taking
  the line break, and a motion's type for an operator.
- Two reads beside the motions, so that a caller need not read the whole
  text: one row's content, which is the row without its line break, and the
  text between two positions. A row the text does not have is refused as no
  position, and a range that is not two positions in order as a bad range.
- As built. In the library a motion is a value of one enum and one method
  of a snapshot answers it; a motion walks the rope from the position, a
  cell at a time, and builds no string and no list. Measured: none of the
  seventeen motions allocates a byte from the middle of a megabyte of text,
  nor does a word motion across a megabyte of blanks in one row; reading
  one row of 36 bytes allocates 164 and a range of 100 bytes 228, the
  string returned as it grows. A column in cells is counted by walking the
  row, so it costs the cells before the position in its row; a row motion
  whose column is not below the row's length in bytes answers the end of
  its content without a walk.
- Across the boundary a motion is a tag, with a count and a column for the
  two motions by rows, a row and a range come back as options of a string,
  and the cells unit of a point's column is a third tag. The text port has
  one question that carries every motion and two for the reads, with seven
  and five properties in its contract, and a property for the column in
  cells of a row that ends in a carriage return and a line feed. The
  contract holds the model and the library to one table written out by
  hand: every motion from every position of one text of four rows.
- The model answers a motion by another route than the library: it lists
  every cell or every word of the text and picks one. Proved on the model:
  a conversion between an offset and a point that answers is undone by the
  other, and so the line start of a line start is itself
  (`TextModel.offsetOf_pointOf`, `TextModel.lineStart_idempotent`).
- What the command loop has under each of the Vim scheme's motion names
  is a composition of these, built by its phase 11 as entries of the
  vocabulary (`lean/Editor/Evil/Motions.lean`;
  [keymaps-and-modes.md](keymaps-and-modes.md), "Motions as built"):
  `left` and `right` are the previous and
  the next cell kept on the line by the line's start and end; `down` and
  `up` the row motions to the line's start, with the column on that line
  asked of the display (the command loop's phase 16);
  `word-forward`, `word-backward` and `word-end` the next start, the
  previous start and the next end of a word, and the `bigword` names the
  same for a WORD; `line-start`, `line-first-non-blank` and `line-end` the
  three line motions; `first-line` and `last-line` a row motion or the
  offset of a point, then the first non-blank. The previous end of a word
  has no default key yet (`ge`, `gE`).
- **Pairs** (built by daily-driver-floor phase 4). Two more questions of
  the text port, beside the motions, answer what Vim's `%` and its block
  and quote objects need (the rules are in `lean/Editor/Text.lean`,
  "Pairs"): the bracket a walk leaves unbalanced (`unmatched`: a kind of
  bracket, which side is sought, a direction and an escapedness; strictly
  after or before the position; the brackets of the other side raise the
  depth; a bracket after an odd number of backslashes is escaped, and
  only the escapedness asked is counted; quotes are characters like any
  other, or, when asked, brackets Vim's default `cpoptions` guesses are
  quoted are passed over, by its guess a line at a time), and the quoted
  string round a position, in its row
  (`quoted`, Vim 9.1's `current_quote` with a backslash escaping the
  character after it). Each answers none where there is nothing, and is
  refused from an offset that is not a position. In the library they are
  two methods of a snapshot in the private module `pair`, which walk the
  rope by characters and build nothing, as a motion does; across the
  boundary a bracket and a quote are tags, and each answers with a status
  of found, not found or refused. The contract holds the model and the
  library to two tables written out by hand and a property from every
  position of texts with and without quotes
  (`TextContract.pairProperties`); since the quote rule is ported twice,
  `contract-test` also compares the library's answer with the model's at
  every position of those texts, for every question the walk can be asked
  (`ContractTest.pairChecks`). What a key makes of
  them is evil's: `%` (`matching-bracket`) and the sixteen text objects
  ([keymaps-and-modes.md](keymaps-and-modes.md), "Text objects as
  built"); the word objects need no pair and are composed in Lean.
- Why this rule for a word character. The pure Lean model answers every
  question of the port without the Rust library, so a character's class has
  to be a rule both sides can state in a line. Rust's
  `char::is_alphanumeric` reads Unicode tables Lean's core does not have,
  and Vim's own classes are a table of some seventy ranges plus emoji. That
  is the reasoning that kept UAX #29 out of the cell. The class of a
  character is one function in one private Rust module and one in the
  model, so a later table replaces both and nothing else. Where the rule
  differs from Vim is in the open questions.
- No library: motions over our snapshot are ours. A crate that has Vim's
  motions brings its buffer or its engine, or reads the text as strings,
  and what a word is must be restated in the Lean model whatever computes
  it in Rust. crates.io, 2026-11-13: `vim-navigation` 0.2.1 reads a slice
  of line strings with a viewport, clamps as a Vim cursor does and classes
  characters with `char::is_alphanumeric`; `vim-line` 7.7.5 reads a `&str`
  for a one-line input; `reovim-module-motions` 0.14.4 is a module of its
  own editor's kernel. `unicode-segmentation` 1.13.3 is not added: its
  words are UAX #29's, which are not Vim's (they split `foo.bar`
  differently and know no WORD), and the model could not hold them.

**Kept inverses** (the Rust half of undo).

- *Two numbers*, as in Vim, Helix and VS Code. The **revision** only grows:
  every applied transaction gets a new one, an undo's included, and the
  log, its subscribers, snapshots and forgetting go on keying on it. A
  **state** is where a text is in its history: undo returns to an earlier
  state at a later revision. The revision, the log and the rope are never
  rewound: consumers hold revisions, and one that named two texts would
  break every one of them.
- *What is kept.* The inverse of every accepted transaction, by the revision
  it produced: the inverse change set, the transaction's two selections
  swapped, and the names of the states before and after it. One direction
  only. An inverse holds the bytes its transaction removed and only the
  lengths of what it inserted, so a transaction that inserts a megabyte
  keeps a few bytes (measured: 1,194,328 bytes allocated to apply it, the
  rope's pieces, against 2.24 megabytes if the transaction were kept too).
  The other direction is made when it is needed: applying an inverse keeps
  *its* inverse, which reads what it is about to remove back out of the
  rope, once (measured: 1,049,980 bytes for the inverse of that insert).
- *Deleted text never leaves the library.* Nothing hands a kept inverse or
  a change set to Lean.
- *A state's name* is the revision of the transaction that first put the
  text there, and 0 for a text as it was made. A transaction names a new
  state; the inverse of a run copies the name the text had before the run.
  A name is given once, to the text one transaction made, so whenever a
  text has a name it holds byte for byte what it held then. Identity is by
  position in the history and never by content: comparing texts costs the
  text, and a text typed back by hand to what it held is a different state
  in every editor.
- *The inverse of a run* of consecutive revisions is applied as one
  transaction, by the path every transaction takes: one new revision, one
  log entry with the origin the caller passes, every marker moved. It is
  **allowed only when the text is in the state the run ended in**, and is
  otherwise refused with nothing changed. A run of one revision is applied
  where it is kept, with no copy (measured: 1,192,664 bytes for the inverse
  of the inverse of that insert, what an insert of the megabyte allocates).
  A longer run's inverses are composed pairwise as a balanced tree
  (measured: 1,738 bytes a revision for a run of a thousand, where
  composing one after the other was about 64,000). Its own inverse is kept
  like any other, so a redo is the inverse of an undo and there is one
  primitive, not two.
- *The refusals*, in order: a revision the text has not reached; a run the
  text keeps no inverse for (it starts at revision 0, is backwards, or
  names a dropped revision); a run the text is not at the end of.
- *What is handed back* is the selection in force before the run: the
  selection before that the run's first transaction carried, or none when
  it carried none. A text holds no current selection, so placing it is the
  caller's. The inverse of an inverse hands back the selection after that
  the run's last transaction carried.
- *The log, a trace and the markers.* The entry's edits are the composed
  change set's. What changed across an edit and its inverse coalesces as
  for any two transactions: nothing for an insert, and one range replaced
  by itself for a delete. A trace names text an inverse restored as the
  inverse's, with its revision and origin, not whoever first wrote it.
  Markers move through the one change set applied and not back to where
  they were: an anchor inside text that was deleted collapsed to a point,
  and is before or after the text when it is put back. That is why the
  selection to restore is handed back and not read from a marker.
- *Dropping.* Lean drops the kept inverses of a run it no longer needs; a
  run, not a prefix, because what a history no longer needs is not one. An
  inverse that names a dropped revision is refused. Dropping and forgetting
  the log are independent: they have different readers. The library never
  drops an inverse by itself.
- *What is unbounded*: one kept inverse for each accepted transaction until
  Lean drops it, each holding the bytes its transaction removed, two
  selections and two state names. A text nobody undoes keeps them all the
  same. Measured: a thousand one-change transactions on a megabyte of text
  allocate 4,017 bytes each with their inverses kept, 3,651 without.
- No library: what is kept is a map of our own inverse transactions and one
  check. `undo` 0.52.0 and `neco-history` 0.2.0 are trees and stacks over a
  caller's edits; with the tree in Lean neither has anything left to do
  (crates.io, 2026-11-13).
- Across the boundary a run is two revisions and an origin a number, what
  an inverse did comes back as words (a revision and the selection, if
  there is one), and a refusal is a status. The text port has two requests
  for them, two refusals and one reply type, with fourteen properties in
  its contract.

**The undo tree** (the Lean half of undo).

- A tree of states over the text port, in plain Lean
  (`lean/Editor/UndoTree.lean`, whose module docs have the rules). It
  imports the port alone: its cases run against the port's model and
  against the real binding. A node holds a few numbers and no text.
- *Told, not wrapping.* The tree is told the text's revision after each
  command; every revision since the last it knew is in its open group, so
  an edit made by something else is absorbed. It is not a gate round
  `apply`, which every other writer of the text would go round. An edit it
  was not told of makes its next move refused by the library with nothing
  changed.
- *Groups.* The caller sets the boundary; a boundary makes the open group a
  node. A node's edge to its parent is one run of revisions, so a group
  undoes as one step: one request, one revision, one log entry.
- *Moves.* Undo, redo and a move to any node cross one edge at a time, each
  by one inverse. The revision a crossing produces is then the edge's run,
  and the run that was crossed is dropped, so an edge holds one kept
  inverse after its first crossing. Undo then a new edit makes a second
  child: the old branch stays. A move that is refused part-way has dropped
  nothing, so the caller's tree stays good.
- *States.* A state is a node, or, while a group is open, a point inside
  it. One state has one name: the revision that first put the text in it
  (for the root, the revision the text was at when the tree was made), and
  nothing else. A node keeps the name of its state, a boundary gives the
  node it makes the name the state had while the group was open, and a
  move to a node puts the text in that node's state: the revision the move
  produced names none. So a state a caller holds means the same point of
  the history whatever boundaries and moves came after it was taken. An
  earlier form named a state by its node and a point inside the group,
  which gave the end of a group one name before its boundary and another
  after; it was replaced on 2026-11-13.
- *Reverting.* A failed command is rolled back by keeping the tree's state
  before it and reverting to it, which may be a point inside an insert
  session's open group: groups need not nest. Reverting the whole open
  group makes no node and leaves nothing to redo. The command loop does
  this for a command a key runs that is refused or interrupted
  (`lean/Editor/Loop.lean`, "Rollback"), with the user's origin, and also
  puts each window's selection and scroll markers back, since a marker
  inside a deleted range does not come back with the inverse. When the
  command set a boundary the kept state is no longer one of the open group
  of the tree it left: the loop then reverts the tree from before the
  command, whose open group is everything the command did, so the steps
  the command closed are not in the history. That tree is good while the
  tree the command left still has each of its edges as it has them
  (`UndoTree.keepsEdgesOf`). When the command moved in the history it is
  not: the loop then reverts the open group alone and leaves the move
  ([concurrency.md](concurrency.md), "Foreground: commands").
- *From commands.* Built by the command loop's phase 8
  (`lean/Editor/Api.lean`, "Undo"), over the buffer's own tree, with no
  new request of the library. A command closes the group
  (`BufferId.closeGroup`), undoes and redoes (`BufferId.undo`,
  `BufferId.redo`): each reads the buffer, tells its tree the text's
  revision, does its part with the user's origin, and records the tree
  that comes back as the buffer's by a request of the editor state. An
  undo and a redo hand back the selection to place, the one from before
  the step's first edit for an undo and from after its last for a redo,
  and do not place it: whose cursor it becomes and in what shape is the
  input scheme's to say. A selection comes back only for an edit that
  carried one, which the API's selection edits do. **Evil places it**
  (`lean/Editor/Evil/Undo.lean`, the command loop's phase 13;
  [keymaps-and-modes.md](keymaps-and-modes.md), "Undo and redo"): `u`
  puts one range of the view's state's shape on the head of what an undo
  hands back, rested by that state's rule, and `C-r` places what a redo
  hands back by the rule of entering a state, so a bar an insert session
  ended with steps back one cell. For the selection an undo hands back to
  be the cursor the user saw, every edit of evil's carries the selection
  from before its command, which is what `Target.replaceCarrying`
  (`lean/Editor/Api.lean`) is for: an edit that carries the two
  selections it is handed, where the selection edits carry the window's
  as it is when they are called. The loop's boundary
  after the event then makes no node, so a move is not itself a step. The
  rollback of a command that moved works from the tree the command
  recorded, since the tree from before does not know of the move and the
  move dropped the inverses that tree's edges cross. The rollback of a
  command that only set boundaries works from the tree from before, and
  takes the boundaries back with the edits. Its cases run on the
  models and on the real binding (`lean/Editor/Api/Cases.lean`: two
  groups undone and redone, each text and each selection as it was).
- *Saved.* The tree keeps the state last marked as saved and answers
  whether the text is in another. A new tree is saved at its root. A
  boundary does not change the answer, whichever of the mark and the
  boundary came first: a save that takes time keeps the state it wrote and
  marks it when it reports, and if that state was the end of a group
  closed in between, it is the group's node. Saving itself is the file
  port's, reached from a job. The route a completed save takes to the mark:
  the command that starts a save keeps the tree's state beside the snapshot
  it hands the job; the job replies with the saved file's stamp or a
  refusal; and the job's command marks that kept state saved on a stamp,
  and keeps the stamp for the next save to expect, or reports the refusal
  and marks nothing. It is built and played by hand as cases on the models
  and on the library (`lean/Editor/File/Cases.lean`), and built as the
  save command (`Files.save`, `lean/Editor/Files.lean`; the command loop's
  phase 9), as follows.
  - *The command* takes the snapshot and keeps the tree's state, starts
    the job `save-file` with them as plain arguments, expecting the stamp
    the buffer holds, and records the save as in flight in the editor
    state: the snapshot and the kept state, on the buffer's file.
  - *The job's command* makes one state request, which ends the save in
    flight: with the stamp the save answered it records the stamp and
    marks the kept state saved, and for a refusal it changes neither. It
    then says `wrote <path>` or the refusal in the echo area.
  - *Why the state keeps the save in flight.* The job's command then asks
    the text store nothing, and a command of state requests alone cannot
    be interrupted or refused: the interrupt key arriving as a save's
    result is delivered cannot leave a file written and a buffer that
    does not know it. And a second save while one is in flight, which
    would expect the stamp from before the first and be refused as changed
    on disk, is refused when it is asked, with a message that says why.
  - *The snapshot is the loop's to release*, once the job's command has
    run to its end, with whatever else a finished command gave up.
  - *A forced save* expects whatever is there. Without it a buffer whose
    file changed on disk could never be saved, since nothing reloads one.
- *Other styles* are written over the same two requests: a linear history
  is two lists of runs; Vim's is this tree with moves by the order nodes
  were made and a time on each; Emacs's records the revision an inverse
  produced as an edit.
- No library: no Lean 4 package is a history tree (Reservoir, 2026-11-13),
  and the tree's moves are our own port's requests.
- *What is unbounded*: the tree's nodes, and so one kept inverse in the
  library for each edge that has been crossed and one for each transaction
  of a group that has not. Nothing prunes the tree.

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
| The cell, forward and back, and what one is (a line break or a character); a row's content, and reading one row | `crates/editor-text/src/cell.rs` |
| What a selection covers | `crates/editor-text/src/extent.rs` |
| What a blank and a word character are | `crates/editor-text/src/word.rs` |
| The motions, and the walks that answer them | `crates/editor-text/src/motion.rs` |
| A point with its column in cells | `PointCells` in `crates/editor-text/src/point.rs` |
| The edit log: entries, origins, tracing, forgetting | `crates/editor-text/src/log.rs` |
| Edits and patches, and composing them | `crates/editor-text/src/patch.rs` |
| Kept inverses: what is kept, the names of states, the inverse of a run | `crates/editor-text/src/inverse.rs`, and `Text::apply_inverse` and `drop_inverses` in `text.rs` |
| The properties, against a `String` | `crates/editor-text/tests/properties/`: the text in `main.rs`, the laws of change sets in `changes.rs`, the log in `log.rs`, anchors and markers in `anchors.rs`, the selection's form, its mapping and its extents in `selections.rs`, kept inverses in `inverses.rs`, every motion at every position and the row read in `motions.rs` |
| What a snapshot, a transaction, a pull, moving markers, keeping an inverse, applying one, a motion and a read of a row or a range cost, counted in bytes allocated | `crates/editor-text/tests/snapshot_cost.rs` |
| That moving markers is one walk of the change set, counted in looks at it (a counter that exists in tests only), bounded by the ends held plus the changes | The unit tests of `crates/editor-text/src/change.rs` (a mapper asked in rising order) and `marker.rs` (markers held out of order) |
| The text and the snapshot as handles for Lean | `crates/editor-ffi/src/document.rs`, `crates/editor-ffi/src/snapshot.rs` |
| A transaction and the log across the boundary, as words | `crates/editor-ffi/src/transaction.rs`, `crates/editor-ffi/src/log.rs`, `crates/editor-ffi/src/words.rs` |
| Markers and extents across the boundary, as words | `crates/editor-ffi/src/marker.rs`, and `editor_ffi_snapshot_extents` in `snapshot.rs` |
| Applying an inverse and dropping inverses across the boundary | `crates/editor-ffi/src/inverse.rs` |
| A motion across the boundary, as a tag, a count and a column; one row and a range as strings; the cells unit | `crates/editor-ffi/src/motion.rs`, and `editor_ffi_snapshot_motion`, `editor_ffi_snapshot_row`, `editor_ffi_snapshot_slice` and `ColumnUnit::Cells` in `snapshot.rs` |
| The Lean text port, its model, real binding and contract | `lean/Editor/Text.lean`, `lean/Editor/Text/` ([lean-runtime.md](lean-runtime.md)) |
| The undo tree, and its cases | `lean/Editor/UndoTree.lean`, `lean/Editor/UndoTree/Cases.lean` ([lean-runtime.md](lean-runtime.md)) |
| A text made from a snapshot | `Text::from_snapshot` in `crates/editor-text/src/text.rs` |
| The file port, and what an adapter's tests are | `crates/editor-text/src/fs.rs` |
| The file port's fake | `crates/editor-text/src/fs/fake.rs` |
| The file port's contract, its ground, and the fakes that break it | `crates/editor-text/src/fs/contract.rs` |
| Loading a file and saving a snapshot over the port, the stamp, the line endings, and the fixtures | `crates/editor-text/src/file.rs`, with its properties in `tests/properties/files.rs` and its costs in `tests/snapshot_cost.rs` |
| The lists that keep the logic's tests off the disk | `crates/editor-text/clippy.toml`, `crates/editor-ffi/clippy.toml`, `deny.toml` |
| The file port's adapter over `std::fs`, held to the contract | `crates/editor-fs-std/` |
| The file service behind the completion queue, and its wiring test on real files | `crates/editor-ffi/src/files.rs`, `crates/editor-ffi/tests/files.rs` |
| A document made from a snapshot, as a handle | `editor_ffi_document_from_snapshot` in `crates/editor-ffi/src/document.rs` |
| The file requests as data, and the model of the files a job reaches | `lean/Editor/File.lean`, `lean/Editor/File/Model.lean` |
| The file requests in the job port, the runner's file port, its fake and its real implementation, and the file properties | `lean/Editor/Job.lean`, `lean/Editor/Job/` ([lean-runtime.md](lean-runtime.md)) |
| The cases that cross the text port and the job port | `lean/Editor/File/Cases.lean` |

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
- The user's own edits are recorded with 1, `Origin.user` (decided
  2026-11-13, by the command loop's phase 2). Every edit the command loop
  makes for an input event, a text commit among them, and every move it
  makes in a buffer's undo tree, carries it. A command run by name chooses
  its own origin: `insert` and `delete` are still `unattributed`. One
  origin for the user is all the editor needs until something else edits a
  text; the rest of the table is open ("The table of origins", below).
- A reload from disk is recorded with 2, `Origin.disk` (decided 2026-11-16,
  by the daily-driver floor's phase 5). It is applied as an edit script
  (`TextId.applyScript`, `lean/Editor/Text.lean`): the line diff of the
  buffer's snapshot and the file's, made off the editor thread
  (`rust-library.md`, "Diff, as built for reload"), applied as one
  transaction with no selection, so anchors and the cursor move through its
  changed ranges by bias, the log has one entry and the undo history one
  step. It is refused when the text has moved past the revision the script
  was made for.

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
  4,017 bytes each, the tree's nodes and the kept inverse included (3,651
  before a transaction kept its inverse); an entry itself is its origin and
  96 bytes an edit.

Nothing calls forget yet outside tests.

## Buffers and excerpt buffers

A **buffer** is text plus a name, an optional file, buffer-local values and
modes. The text is a Rust object; the rest is Lean state.

As built (`lean/Editor/State.lean`, "A buffer's file"; the command loop's
phase 9):

- **What a buffer keeps of a file**: its path, and the stamp the last load
  or save of it answered, which is what the next save expects to find on
  disk. A buffer comes to hold a file by a load, so the stamp is always
  there.
- **Its line ending** is the buffer's own, a line feed unless a file said
  otherwise, because a buffer with no file needs one too.
- **The saved state stays in the undo tree**, and "is it modified" is the
  tree's answer. The buffer keeps no second copy.
- **A path is matched to a buffer by equality of the path string.** Two
  spellings of one file (a symbolic link, `..`, a doubled slash) are two
  buffers. That is safe: once one is saved, a save of the other is refused
  as changed on disk, so neither overwrites the other unnoticed. One buffer
  for each file on disk would need a canonical path, which is the file
  system's to answer and which the file port does not; removing `..` in
  Lean is wrong across a symbolic link. A path is attached to one buffer
  only, so the match has one answer.
- **A buffer's name need not be its file's base name.** A second file with
  a base name a buffer has is called `name<2>`, then `name<3>`.

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

### As built

Of the kinds above, span faces are built, from two sources: the selections
and the decorations a scene carries. The rest are not.

**The decorations a scene carries** have one source built: the matches of
the last search, in the face `search-match` (`lean/Editor/Loop.lean`,
"Decorations"). Each view but the minibuffer's asks its snapshot the
matches of the pattern from the start of its scroll anchor's row through
as many text rows as it has display rows, and one more, which covers every
visible row however the rows wrap; the loop reads them after the follow
has placed the anchor. An empty match is not drawn, and a pattern the
syntax refuses draws nothing. They are always drawn, where Vim's default is
`nohlsearch`, and `:nohlsearch` is not built.

**A face** sets any of nine attributes and leaves the rest unset: a family,
a size, a weight, a slant, a foreground, a background, an underline (a
style and a colour), strike-through and a line height. It is the same nine
in Lean (`lean/Editor/Face.lean`) and in Rust
(`crates/editor-layout/src/face.rs`).

**Lean defines, Rust merges.** Lean holds faces as data and merges nothing:
a theme is an ordered list of definitions, each a name and the attributes
it sets. Layout holds the list last sent and applies one rule to all of it.
Doing the merge in Lean instead would put layout policy in two halves and
make every publish cost the spans.

**The precedence.** Attributes merge one by one. The value of an attribute
of a run is that of the highest layer over the run that sets it:

1. (highest) the selection, drawn in the face `selection`;
2. the scene's decorations of the view, a later one in the view's list over
   an earlier one;
3. (lowest) the face `default`; and where `default` leaves an attribute
   unset, layout's base value: no family, 16 points, weight 400, upright,
   black on white, no underline, no strike-through, and a line height of
   one times the font's own.

The same rule orders definitions: where what is sent defines a name more
than once, a later definition's set attributes are over an earlier one's.
So a theme is overridden by appending to it. A status field's face is over
`mode-line` over `default`, and a cursor's face is over `default`. A name
nothing defines sets nothing. A decoration source added later (syntax
highlighting) states its place in this order when it is added.

**Units.** A colour is one word, `0xRRGGBBAA`. A weight is 1 to 1000, with
400 normal and 700 bold. A line height is a multiple of the font's own, in
64ths, or a length. A size or a line height of 0 is taken as it is, where
a weight outside its range is not: the lines of such a font have no
height, and how many a view shows is layout's rule ("Layout and
rendering", as built, "A row counts as at least a pixel").

**A length a face states is in logical points.** A length is a font size,
a line height stated as a length, or the base size where no face sets one.
It is a whole number of 64ths of a point, so it is exact as a float and
can be hashed. A point is one physical pixel at scale 1: what a window
system calls a logical pixel. It is not the typographic point of a 72nd of
an inch. On macOS the two are the same number; on a Linux desktop a "14
pt" font in another app is 14 × 96/72 pixels at scale 1.

- **Layout multiplies, once.** Layout is told the scale factor of the
  target it lays out for (`Layout::set_scale`; 1 until it is told). The
  faces over a run are merged in points; the font they come to is put at
  the scale and only then asked of the shaper
  (`crates/editor-layout/src/decoration.rs`, `Styles::style`, the one
  place layout asks a shaper for a font). So `size := 14` is 14 physical
  pixels at scale 1 and 28 at scale 2, and looks the same size on both.
- **What is multiplied**: a size, a line height stated as a length, and
  the base size. A product is to the nearest 64th of a pixel, at any
  positive scale, fractional ones among them: 14 points at 1.25 are 17.5
  pixels. A line height that is a multiple of the font's own is not a
  length and follows the size. A face has no padding and no margin; a
  length added to a face later is in points and is multiplied in the same
  place.
- **The shaper port stays physical.** A font a shaper is asked for is in
  physical pixels, so no shaper adapter knows a scale.
- **Lean knows no scale for faces.** A theme and config state points. No
  scale crosses with a face, and Lean multiplies nothing.
- **Everything else is physical pixels**, as before: a scene's size and
  rectangles, a frame's geometry, the answers of the layout queries, and a
  pointer's position.
- **The names are older than the unit.** Lean's `Pixels`, `Pixels.whole`
  and `LineHeight.pixels`, and Rust's `Length::pixels` and
  `LineHeight::Pixels`, keep the names they had when a theme stated
  physical pixels. Their documentation says which unit each is in.

**Themes and config.** `Theme.builtin` defines `default`, which sets every
attribute, and `cursor`, a cursor face for each state of the shipped Vim
scheme (`cursor.normal`, `cursor.insert`, `cursor.visual`,
`cursor.visual-line`, `cursor.minibuffer`), `selection`, `echo-area`,
`minibuffer-prompt`, `mode-line` and `search-match`, which the matches of
the last search are drawn in (below, "Decorations"); its colours are
placeholders. Layout reads three names by itself: `default`, `selection`
and `mode-line`.
`echo-area` and `minibuffer-prompt` are defined and nothing draws them. Any
other name is one a scene names and a theme or config defines, with no
change to layout. A cursor face nothing defines has the default face's
paint, the paper's colour on the paper, and is not seen: so each state the
shipped scheme has gets its cursor face in the built-in theme (the default
face's colours the other way round), and a state config registers needs
config to define its own. Config sets a face in `setup`, `face "name" { … }`; a name is set
once in a `setup`. The theme a display is sent is the built-in one followed
by the installed config's definitions, so a face config sets takes
config's attributes over the theme's, and one it stops setting is the
theme's again at the next reload that installs
([lean-runtime.md](lean-runtime.md), "Config and reload").

Not built: a face naming another as its base; choosing between whole
themes.

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

### As built

The display pipeline's phase 1 built the contract and two layers, in
`crates/editor-layout` (`src/layer.rs`, `src/tabs.rs`, `src/wrap.rs`):

- **The contract** (`Layer`): `sync` takes the snapshot of the layer below
  and the edits that made it, and gives the layer's own snapshot and its
  edits, in its own point type; a point converts down and up, with a bias
  for a point the layer below has no counterpart of. Its module docs say
  where a later layer goes: folds and inline text between the buffer and
  the tab layer, blocks after the wrap layer; none changes a layer below.
- **The tab layer.** Tabs are expanded before shaping (decided in phase 1,
  2026-11-13): a tab becomes spaces up to the next multiple of the tab
  width (8 columns by default), columns counted in characters, so the
  shaper never sees a tab. On a monospace font the glyph after a tab is at
  the stop in pixels; on a proportional font it is at the stop counted in
  spaces, the known limit of the choice. Inline boxes (a relayout pass per
  tab) and runs split at stops (layout breaking lines itself) were set
  aside, and stay possible as the align-to-stop primitive ("Text is the
  only layout engine"). Its points are a row, a segment and a byte column
  of the segment's expanded text. A row's content is its bytes without its
  line feed and without a carriage return before it; the position between
  the two is the row's end.
- **One very long row** is cut into segments of at most 4096 bytes, at the
  last character boundary before each multiple. Each is shaped and broken
  on its own and starts a new visual line, and tab columns restart at it,
  so the rows around a position of a row of N bytes cost the segments they
  touch, not N. The forced visual break every 4096 bytes on such a row is
  the price; an incremental breaker that resumes mid-line needs shaping
  state Parley does not expose.
- **The wrap layer** is the per-text line store: each segment laid out on
  demand, as an immutable entry keyed by row and segment. Its points are a
  row, a segment, a visual line of it and an x. A position at a wrap is the
  start of the later visual line, and only a row's last visual line holds
  the row's end. A visual line that starts inside a tab's spaces starts
  after the tab, so the tab is on the line its first space is on. Every
  visual line holds a position, so each can be scrolled to and moved to: in
  a view narrower than a tab, a line that would be a tab's spaces alone
  with no position on it is not kept and those spaces are not drawn (such
  a line at a row's end holds the row's end and stays).

The round trip of every position through both layers is a property test
(`tests/layers.rs`).

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

#### Views as built

The editor state is one Lean value (`lean/Editor/State.lean`, decided
2026-11-13 by the command loop's phase 2): buffers, windows, one frame, the
echo area, the preedit, and the prompt that is open, if one is.

- A **window** is a view of a buffer, named by the `ViewId` its view has in
  every scene. Its scroll position is an anchor marker of the buffer's text,
  and its selections one selection marker of that text, whose ranges are its
  cursors.
- **A window keeps its wanted column** (`Window.wanted`, built by the
  command loop's phase 11): the column its vertical motions aim for, with
  the offset the cursor was left at when it was kept. The column is the
  line's end, or a goal of the display's: the x a move query passed back,
  in pixels from the start of the cursor's line laid out unwrapped (the
  command loop's phase 16). The state stores that x and nothing computes
  with it. It holds only while the cursor is still there, so
  nothing has to clear it. One state request sets it; showing another
  buffer in the window clears it, and a window a split makes has none
  ([keymaps-and-modes.md](keymaps-and-modes.md), "The wanted column").
- **A view follows its cursor** (built by the command loop's phase 15;
  `lean/Editor/Scroll.lean`, `lean/Editor/Loop.lean`, "Following the
  cursor"). Before each scene, a view whose cursor's row is not among the
  rows it shows has its scroll anchor moved so that it is. The cursor is
  the head of the primary range of the window's selection, and its row is
  the first row the display answers from it.
  - **The policy is the least movement.** A view whose cursor's row is
    shown keeps its anchor. Otherwise the anchor moves just far enough: a
    cursor above the rows shown becomes the first row shown, and one below
    them the last. So a motion of one row off an edge scrolls one row, and
    a jump leaves the cursor at the edge it came in by. Set aside: centring
    after a far jump, which Vim does, and scrolling by more than a row at
    an edge (Vim's `scrolljump`).
  - **The scroll margin** is how many rows are kept between the cursor's
    row and the first and the last row shown. Vim's `scrolloff` is the
    model. It is one number of the editor state
    (`EditorState.scrollMargin`), 0 by default, set by a command
    (`setScrollMargin`). The margin in force is at most half the rows the
    view fits, so a margin of 99 centres the cursor's row, and it gives
    way at the text's start and end. A view that shows its whole text
    keeps the margin as set (below, "How many rows a view has room for").
    Config cannot set it when it loads:
    `setup` registers and runs no command, and there are no settings yet.
  - **Whether the cursor is shown is decided by comparing rows the display
    answered**, never offsets: a position at a wrap is the start of the
    later row, and only a line's last row holds the position at its end.
  - **A view of no height is not asked about**, and a view less than a row
    tall keeps its anchor. The headless host's frame is 0 by 0 until a
    script resizes it, so there nothing follows until then.
  - **The rows are asked with the view's whole height**
    (`Scroll.Area.ofRect`). On the display model and in the headless host
    that is exact. Over real layout a view's status row takes its height
    from the bottom of the view, so the rows query answers one row more
    than the frame shows, and a cursor on the last row answered would be
    behind the status row. Lean cannot learn that row's height ("Open
    questions", "The height of a view's text area"). Nothing here has run
    over real layout: the model's cells are one size.
  - **How many rows a view fits** is asked as the rows it shows from the
    text's start, which are the text's rows when the text is shorter than
    the view. It is right where rows are one height.
  - **How many rows a view has room for is missing**, where its text has
    fewer rows or exactly as many. The display answers the rows shown from
    an anchor and not the view's capacity, so half the rows a view fits is
    half the text's rows when the text is the shorter, and that is not the
    view's middle. A view that shows its whole text from its start
    (`Scroll.Area.whole`: the text has no row after the last row shown
    from there) is therefore treated on its own: `z z` places the text's
    first row, so no row that fits is hidden, and the follow keeps the
    scroll margin as set and not at half the text's rows.
    - **A departure: a text that fills its view exactly is treated as one
      shorter than it.** The two cannot be told apart from what the two
      queries answer: both show the same rows, and there is no row after
      them to ask about. Asking again with other heights would assume the
      height of rows that do not exist. Of the two readings the one taken
      never hides a row that would fit. So in a view its text fills
      exactly `z z` on a row below the middle keeps the anchor at the
      first row, where Vim scrolls, and a margin larger than half the view
      brings such a view back to the text's first row. A text one row
      longer than its view is not affected.
    - A query that answers a view's capacity in rows, or the open
      question's query for a view's text area ("Open questions", "The
      height of a view's text area") if it answers that too, would settle
      it; `Scroll.Area.whole` is what goes when it exists.
- **A view is scrolled by commands** (the command loop's phase 15): by half
  a view, by a view, and so that the cursor's row is at the top, in the
  middle or at the bottom ([keymaps-and-modes.md](keymaps-and-modes.md),
  "Scrolling as built"). A command reads and places its window's anchor
  (`Target.anchor`, `Target.scrollTo`) and asks the display about its view
  with a snapshot it takes and releases (`Target.onArea`). Placing an
  anchor is no edit, and a command that scrolls and fails is rolled back:
  the loop keeps and restores each window's scroll marker.
- **The first window's selection has the shape the input scheme reports**
  of the first view before any key: inclusive under the Vim scheme, whose
  first state is normal state.
- The **split tree** is binary: a leaf is a window or the minibuffer's
  place, and a split divides its rectangle between two children along an
  axis, rows (stacked) or columns (side by side), the first taking half,
  rounded down. A subtree with no view takes no space, and its sibling
  takes all of it, so the minibuffer's place takes none while no prompt is
  open, and the views tile the frame.
- **The minibuffer is a buffer and a window of the state** (built by the
  command loop's phase 10; [concurrency.md](concurrency.md), "Prompts").
  The open prompt is a field of the state (`EditorState.prompt`): its
  label, the minibuffer's view, the asking view and the continuation. The
  minibuffer's buffer is in the next slot, over a text the asking command
  made, with a name no buffer has and the major mode `minibuffer`; its
  window is in the state's windows, with a new view id. So a committed
  text is inserted there, the loop keeps and restores its markers and its
  history, and the scene has its view, with no rule of their own.
  - **The tree does not change.** The minibuffer leaf says where the
    minibuffer's place is, and the prompt says whether one is open and
    which window stands there, so closing a prompt leaves the tree exactly
    as it was. A view id on the leaf was set aside: the open prompt would
    be in two places that an invariant must keep in step. So was a prompt
    kept by the loop, outside the state: a rollback returns the state
    from before a command, and would need a second one for it.
  - **The place takes a strip while a prompt is open.** A split one of
    whose children is the minibuffer's place gives that place 32 physical
    pixels along its axis (`Split.minibufferHeight`), or the whole extent
    when that is less, and its sibling the rest; the views still tile the
    frame. 32 is two rows of a 16-pixel cell, one for the input and one
    for the status line that carries the prompt text. It is a placeholder
    with no font behind it, and it ignores the frame's scale: nothing in
    Lean knows the height of a row, since layout is the display's.
  - **The window commands do not have it.** Removing it, splitting it and
    showing another buffer in it are refused (`ofMinibuffer`), and so is
    showing its buffer in another window: it is closed by answering or
    cancelling its prompt, and only it shows its buffer. Focusing it is
    allowed, so the focus can leave the minibuffer and come back. The last
    window of the tree cannot be removed while a prompt is open: the
    minibuffer's window does not count.
- **The invariants** are over the state's views, the tree's windows and
  then the open prompt's view: the focused window is one of them; there is
  exactly one minibuffer leaf; the views' ids are distinct and are the
  windows'; each window's buffer exists. The operations that can break one refuse
  with a `LayoutRefusal` and the state unchanged: removing a window
  (`onlyWindow` for the last window, `noSuchWindow` for one not in the
  tree), focusing one, splitting one, and showing another buffer in one
  (`noSuchBuffer` for a buffer there is none of, `markersOfAnotherText` for
  a marker that is not of the buffer's text). The minibuffer's place has no
  id, so none can remove it. When the focused window is removed, the focus moves to the first
  window, in drawing order, of the subtree that took its place, or of the
  tree when that has none.
- **A command reaches them as requests** (the command loop's phase 8,
  `lean/Editor/Api.lean`): `ViewId.split`, `close`, `focus` and `show`. A
  split puts the new window second in a split with its source, below it or
  to its right, on the same buffer, with markers of its own; closing it
  gives back the tree from before the split, since a removed window's
  sibling takes the place of their split. A view's id is never used again,
  and a buffer's is not either: buffers are kept in slots, and a removed
  buffer leaves its slot empty.
- **No ambient context**: a handler is given the window it acts on and its
  buffer, never "the current buffer".

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

#### As built

The scene is plain Lean data (`lean/Editor/Scene.lean`, `Scene`):

| Field | What it is |
|---|---|
| `size` | The frame's size, in physical pixels |
| `views` | The views, in drawing order |
| `focused` | The view with the keyboard focus, if any |
| `echo` | The echo area's text |
| `pending` | The pending key prefix, rendered by Lean into a string |
| `preedit` | The input method's preedit text in the focused view, if it is composing |
| `title` | The window's title: the selected buffer's name (`EditorState.title`), the focused window's, or the asking window's while a prompt is open, so it does not become the minibuffer's while a prompt is typed into |

Each view (`View`):

| Field | What it is |
|---|---|
| `id` | The view's number |
| `rect` | Its rectangle in the frame, in physical pixels |
| `snapshot` | The text it shows, as a snapshot handle |
| `scroll` | Its scroll anchor, as an anchor marker of that text |
| `selections` | Its selections, as selection markers of that text; each carries its ranges and its shape |
| `cursor` | Its cursor shape (block, bar, underline, hollow) and the name of the face its cursors take |
| `decorations` | Byte ranges of its snapshot, each naming a face |
| `status` | Its status line: text fields, each naming a face |

Content is named only by handles, never by copied text, so an unchanged
view is sent as the same handles. Faces are names; what they look like is
the display pipeline's. Which cursor a view has is the input scheme's to
say, and which status fields is `Loop.statusOf`'s (below); the scene only
carries them.

**What the faces look like travels with the scene, in the binding.** Lean's
`Scene` and the display interface are unchanged by faces: a scene names
them and nothing more. The display's real binding
(`lean/Editor/Display/Real.lean`) holds the theme and writes its
definitions into the same words and the same string as the scene, after
the views, so a scene and its faces reach layout in one call under one
lock, and no frame is built between the two. They are written only on the
first publish after the theme was set: the words carry a presence, and
absent means "as last published", so a publish costs the faces only when
they changed. The alternatives were a field of the scene or a request of
the display interface, which change the contract the command loop builds
on and its model, and a second C call, which lets a frame be built between
a scene and its faces. The Rust scene (`crates/editor-layout/src/scene.rs`)
is therefore Lean's scene and one field more, the definitions, with none
meaning "as last given". The layout of the words is the table in
`crates/editor-ffi/src/display/wire.rs`.

After a reload that installs, the runtime that owns a display hands the
binding the new theme (`Config.retheme`, `lean/Editor/Config/Display.lean`).
The headless host does, through its display's `setTheme`: the real
binding's in the window mode and under `--render`, and nothing for the
recorder.

The theme takes effect at the next publish, and that publish is sized in
it too. `Loop.publish` asks the display's heights before it lays out the
views, and the heights depend on the faces (`mode-line`, `echo-area`, the
default size), so the binding's heights answer defines a theme still to
be sent in layout first, by itself (`editor_ffi_display_define`, which is
`Layout::define`): the heights, and the rows queries the views follow
their cursors by, are then in the faces the frame is laid out in, the
first frame after a re-theme and the very first frame too. The theme
stays to be sent, and still travels with the scene; layout takes the same
definitions again as no change. `ConfigTest.faceChecks` checks it: after
a reload that makes `mode-line` taller, `agree`, with no event between,
finds the rows query and the frame agree.

Lean publishes the scene and asks layout's two questions through the
display interface (`lean/Editor/Display.lean`): the rows a view shows from
its scroll anchor, and the position some visual lines above or below a
position, with the x it aimed for passed back for the next move. Its model
(`lean/Editor/Display/Model.lean`) lays text out in fixed-size cells, for
tests. Its contract (`lean/Editor/Display/Contract.lean`) holds the
model and the real binding to the same properties, the real binding over a
fake shaper whose glyphs all have the cells' size.

The one place the model's layout rule runs outside a test is a host with no
window, which has no layout to ask: the headless host's display is a
recorder (`lean/Editor/Display/Recorder.lean`) that keeps the last scene
published and answers the two queries with the model's rule over the
library's snapshot. The contract holds it too, over real snapshots. An
editor with a window asks the real binding every time.

**The model's layout rule and what the contract says of a column** (the
command loop's phase 16, for evil's `j` and `k`).

- **The model**: a tab takes the cells up to the next multiple of 8,
  counted from its line's start, and a wide character takes two cells.
  Which characters are wide is the model's own list of East Asian blocks,
  not Unicode's table; an emoji is not in it and is one cell. A character
  is of the row its first cell is in. Until phase 16 every character was
  one cell, so the model and real layout, whose tab width is 8 by default,
  disagreed about a tab and no property said so. The recorder answers with
  the same rule.
- **Three properties were added to the contract**, which the model, the
  recorder and the real binding hold, the real binding unchanged:
  - a move of no lines that is given a goal goes to that x of its row, and
    to the row's end past its last character, and the goal a move with no
    goal passes back is its position's own x: so the move query also
    answers "the position at this x of this row";
  - a width wider than any machine word holds wraps no line, so a row is a
    line of the text and a move goes from line to line;
  - a tab reaches to the next multiple of eight cells: the character after
    it is eight cells in, and a move that aims inside the tab lands on the
    tab.
- **No property has a wide character.** How wide a character is drawn is
  the shaper's, and the fake shaper the contract runs over makes every
  glyph one cell. The model's wide characters are pinned on the model
  alone (`ModelTest.displayChecks`), and so is what a tab or a wide
  character does at a wrap.
- **The property of the tab names a tab stop of 8.** When a view has a
  setting for its tab width, the property names the default.

**Who asks the two questions** (the command loop's phase 15). Until then
nothing did. Now the loop asks them before each scene, to have each view
follow its cursor, and evil's scroll commands ask them when they run
("Views as built", above). Both ask through `lean/Editor/Scroll.lean`,
which keeps nothing of an answer between two questions. No request and no
property was added to the display interface for it.

**Publishing**, as the command loop does it (`lean/Editor/Loop.lean`,
decided 2026-11-13 by its phase 2):

- Once a frame exists, a scene is published after every event the loop
  handles, whether the event changed the state or not: an input event, a
  driver's request, a reload's install, a job's command, any of which may
  have edited a text a view shows. A queue's quit ends the loop and
  publishes nothing. A window's close request is a quit by `q`'s rule: it
  publishes a scene, and ends the loop only once the editor can leave.
- Before the scene is made, each buffer's undo tree is told its text's
  revision and its group is closed, so what one event edited is one step of
  the history. **But for a buffer in an insert session** (built by the
  command loop's phase 11): while a view of the buffer is one the input
  scheme reports as in a session, its group is left open, so what is
  edited in the session is one step
  ([keymaps-and-modes.md](keymaps-and-modes.md), "Insert sessions").
- A view whose buffer's text is at the revision it was last shown at keeps
  the same snapshot; otherwise a new one is taken, and views of one buffer
  share it.
- **Then each view follows its cursor** (built by the command loop's phase
  15; `Loop.followed`), after the views are made and before the scene is
  published. After the views, because a question of layout names a
  snapshot, and making the views is what takes one of a text that changed:
  the follow asks with each view's own snapshot and rectangle, and takes
  and releases nothing. Before the publish, so the anchor is in place when
  a display resolves the scene's markers. The scene names the anchor's
  marker and not its offset, so the scene's value does not change.
  - It runs after every event, so a resize, a committed text and a job's
    command are followed as a key's command is, and a command that failed
    is followed from the cursor its rollback put back.
  - Every view is followed, not the focused one alone: an edit through one
    window moves the cursor of another window on the same buffer.
  - It is the loop's own program and is not guarded: the interrupt flag
    never stops a scene.
  - **Its refusals are dropped.** A view whose marker was given up, or
    whose snapshot was released, is not followed, and nothing is said: the
    echo area keeps what the command that lost the marker was told.
  - A view that keeps its anchor costs two text requests and two display
    requests a scene; a view of no height costs none.
- Once the scene is published, each snapshot the previous scene named that
  this one does not is released. So a scene's handles are alive while it is
  the last one published, and a real binding resolves them when it is
  published.
- Publishing is not refused. It asks the store for each buffer's revision,
  for a snapshot of a text that changed and to release snapshots, and a
  command can release a text or a snapshot the state names, since their
  ids are plain indices. A buffer whose text refuses keeps its history as
  it was and its views are left out of the scene, and the refusal is in the
  echo area of the state and of that scene, as a refused handler's is. A
  refused release, which comes after the scene is published, is in the
  echo area of the next. So what a handler's refusal wrote in the echo
  area reaches a scene even when its cause refuses the publish too, and a
  host is not left with a refusal to drop. The state's layout is not
  touched: a well-formed state stays well formed.
- **A view's cursor is the one the input scheme reports of the view**
  (`InputScheme.report`, built by the command loop's phase 11), in the
  scheme's state after the last key: under the Vim scheme the cursor shape
  of the view's Vim state, in the face `cursor.` followed by the state's
  name (a block in `cursor.normal`, a bar in `cursor.insert`). A scheme
  that says nothing of a view gives it a bar in the face `cursor`. A view
  has no decorations until later phases choose them. The focused view is
  named only while the frame has the keyboard focus, and the preedit is
  the input method's text for it.
- A view's status line (`Loop.statusOf`) is the fields the input scheme
  reports of the view and then its buffer's (`Loop.status`, built by the
  command loop's phase 9): the buffer's name in the face `status.name`,
  and, while the buffer is modified, the text `[+]` in the face
  `status.modified`. Under the Vim scheme the scheme's is one field, the
  name of the view's Vim state in the face `status.state`, so the line
  reads `normal`, `scratch`. "Modified" is the presence of the field in
  the face `status.modified`: a buffer that is not modified has no such
  field, not one with an empty text. Whether a buffer is modified is its
  undo tree's answer, and it is right in a scene because every tree is
  told its text's revision before the scene is made; a buffer is modified
  while its group is open, so during an insert session. The scene's shape
  did not change.
- **While a prompt is open the minibuffer's view is a view of the scene**
  like any other (built by the command loop's phase 10), where the
  minibuffer's place is in drawing order: its snapshot is the input typed
  so far, its selection the cursor in it, and it is the focused view while
  it has the focus.
  - **The prompt text is its status line**: the prompt's label,
    in the face `minibuffer.prompt` (`Loop.statusOf`, `Loop.promptFace`),
    with no name, no modified field and none of the scheme's fields. Its
    cursor is the one the scheme reports of it. A view's status line is the
    loop's to fill, so the scene's shape did not change, and neither did
    the Rust scene on the display pipeline's branch, which lays a view's
    status out as one row at the bottom of its rectangle.
  - **A prompt's candidates are fields of that status line** (built by the
    command loop's phase 14; `Loop.promptStatus`). After the label comes
    one field for each candidate the typed text matches, every one, in
    the fuzzy matcher's order, in the face `minibuffer.candidate`
    (`Loop.candidateFace`); the chosen one, if one is chosen, is in
    `minibuffer.chosen` (`Loop.chosenFace`) instead. With nothing listed,
    and for a prompt with no candidates, the line is the label alone.
    - So which candidates match, their order and which is chosen are in
      the scene as data that exists: no field was added to the scene, and
      nothing of the Rust scene, its wire form or the display's binding
      changed.
    - A face nothing defines sets nothing, so the fields draw as the rest
      of the line does until a theme or config defines the two names. No
      theme defines them yet.
    - **How a line of many fields draws in a window has not been seen**:
      it is one row, and a list longer than the row is wide is cut by
      whatever lays the row out (the display pipeline's phase 6).
    - Set aside: a field of the scene for the candidates, which is the
      display contract, with a Rust half that is the display pipeline's;
      and a view of their own over generated text, which is where a long
      list should go ("Tables, lists and pickers"), and needs a buffer, a
      window and a place in the split tree made and unmade with the
      prompt. The listing in the editor state is what such a view would
      show.
  - **The input is the whole text of the minibuffer's buffer.** So the
    answer is that text, the initial value is what the text is made with,
    and a motion to the start of the line is the start of the input. The
    label as the first characters of the text was set aside: the text
    store has no read-only range, so a command could move into the label
    or delete it, and the answer would have to be cut out of the text.
  - **A field of the scene for the prompt** is the cleaner contract, and
    was set aside for now: it needs the same field in the Rust scene and
    its binding. It is open whether to make that change when the display
    pipeline draws the minibuffer.
- The pending prefix is the keys the loop's input scheme reports as
  pending, as a key string (`C-x`): empty once a sequence completes and
  after an unbound key ([keymaps-and-modes.md](keymaps-and-modes.md), "The
  loop runs one scheme"). The headless `scene` line does not print it.

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
- Shaping goes through a `Shaper` port (Parley and fontique are its real
  adapter, `editor-shape-parley`): font fallback, ligatures, complex
  scripts, bidirectional text, mixed proportional and monospace fonts.
  Layout takes every metric from this port and assumes nothing about
  pixels.
- Drawing goes through a `Renderer` port, which takes a device-independent
  frame (see below). The wgpu adapter rasterises glyphs once into an atlas
  and draws them as quads, plus rectangles. Rasterising and the atlas are
  inside that adapter, not in the frame. The frame names the font each
  glyph is drawn in, resolved in layout, with a generation stamp so a
  stale cache is detectable; it never names an atlas.
- Nothing is drawn when nothing changed. Frames are drawn on demand, at
  most one per display refresh, by a scheduler that is a pure function of
  its inputs and so is tested with a fake clock.
- The frame layout hands the renderer is an immutable value, passed through
  a mailbox where a newer frame replaces one not yet presented. It is plain
  data, so it can be recorded and compared in tests.
- Rows carry a content hash, and the renderer reuses the geometry of rows
  that did not change, so scrolling and cursor movement rebuild nothing.

### As built

The display pipeline's phase 1 built layout in `crates/editor-layout`, and
put it behind a handle for Lean in `editor-ffi` (`src/display.rs`). Its
phase 3 built the real shaper in `crates/editor-shape-parley`, and made
the port and layout able to say what a real shaper says. The facts of each
part are in the module docs; these are the decisions.

- **The `Shaper` port** shapes one segment, with its font runs, into a kept
  value that breaks into visual lines at a width; measuring and breaking
  stay one operation behind it, and a width change breaks the kept value
  again without shaping. Its published fake, `CellShaper`, gives each
  character one glyph of its font's advance and line height and breaks
  greedily at characters, the Lean display model's rule, so the real
  binding passes the display contract by construction; it is also what the
  display handle still runs on (the real adapter is linked by nothing
  yet, below), and it is the "cell shaper" of the table below. Its
  published contract check
  (`shaper::contract`) holds the fake and every real adapter to nine
  properties that leave the breaking policy open. Two of them are what
  layout relies on of a line and the fake could never break: a line's
  glyphs are in order from its left edge, whatever the order of their
  clusters, and nothing in a text forces a break. A segment holds no line
  feed, and every other character is content: a carriage return alone,
  U+2028 and U+2029 reach a shaper, since a row is split at line feeds
  only, and stay on their line.
- **A glyph says where it is drawn and in which font.** A glyph has a pen
  position and an advance, which positions are found by, and an offset
  from the pen position and the baseline, which only a renderer reads.
  The offset counts to the right and down: a glyph drawn left of its pen
  position, or raised above where it would be, has one less than nothing.
  The font it is drawn in is not the font its run asked for: a character
  the font asked for lacks is drawn in a fallback, and two specs that
  differ in line height are one font. So there are two kinds of id. A
  spec's id is what a run asks for and what metrics are asked about; a
  resolved font's id is what a glyph carries, an index into the shaper's
  table of resolved fonts (`Shaper::resolved`). An entry is one face of
  one font file at a size, with what a rasteriser needs: the bytes, a
  number for the file so two entries are compared without reading bytes,
  the face's index, the variation coordinates, and whether bold or a
  slant is synthesised. Every glyph names an entry of the table as it was
  when its line was shaped; within one generation of the shaper the table
  only grows and an entry never changes. One id space for both was set
  aside: it gives one number two meanings. The fake draws a spec's glyphs
  in the resolved font of the spec's number, with no bytes.
- **The real shaper is `editor-shape-parley`**, over Parley and fontique,
  both pinned at exactly 0.13.0. No type of either is public: `deny.toml`
  lets only the adapter depend on Parley, and only the adapter and
  Parley's own crates on fontique. It builds one Parley layout for each
  `shape` call, which is one segment of one row, keeps it, and breaks it
  again at another width without shaping; it never uses `PlainEditor` or
  a layout of a whole document, which shape everything again on each
  edit. So a row costs a layout for each of its segments that is shaped,
  which a wiring test counts against layout's own counters. Layouts are
  quantised: a line's height and baseline are whole pixels, and advances
  are the font's own. A font's metrics are those of a space shaped in it.
  A glyph's offset is Parley's as it is: Parley's counts to the right and
  down too, having turned over the font's own, which counts up.
  **It is linked by nothing yet.** The display handle stays on the fake:
  Lean's display contract passes over the fake by construction and has no
  way to name fonts, and a display over real fonts needs a constructor
  that says which, whose first user is the renderer. Whoever first needs
  real metrics through the handle wires it (the pipeline's last phase;
  the renderer's headless tests can lay out over the adapter in Rust).
- **Where fonts come from is one seam, a font set.** A set of given files
  holds exactly the fonts handed to it as bytes, with the system's fonts
  off, a default family and fallback families by name; every test uses
  it, over fixture fonts checked in under `tests/fonts`, so what a test
  sees depends on the text and those bytes alone. The system's set is
  the fonts of the machine, with the system's monospace family as the
  default and the system's own fallback by script and for emoji; no test
  may call it, and its check is on demand (`mise run shaper-system`). A
  character is looked for in the family its run's spec names, then the
  default family, then the set's fallbacks in order, and where none has
  it, it is the first family's missing glyph. A port for font sources was
  set aside: it would be a port inside an adapter for one decision.
- **A line is as tall as the fonts on it.** Parley makes every line at
  least as tall as a layout's default style, as CSS does. Left alone,
  that would hold a row in a small font, or in a font of size 0, to the
  height of font 0, whichever font the theme's default face is. So a
  text's default style has no size and no line height, and every byte
  states its font; an empty text, which has no byte, takes its run's
  font, so an empty row is as tall as the font it would be typed in. One
  limit follows from Parley: a line always holds its baseline, so a line
  height in pixels under about three quarters of the size gives a line a
  little taller than was asked, and only a size of 0 gives a line of no
  height.
- **Direction.** A line's glyphs are in visual order, as the Unicode
  bidirectional algorithm orders them, and the base direction of every
  line is left to right: a line that starts in Hebrew still starts at the
  left edge with its Hebrew run reordered, as a code editor shows it,
  where taking the direction from the text would make it a right-to-left
  paragraph. The fast path for a line with no right-to-left character is
  Parley's own, which skips bidirectional resolution for such a text at
  that base direction; the adapter adds none, since it reads clusters
  back the same way either way.
- **Breaking is the shaper's.** Parley breaks at words by the Unicode
  rules; a word wider than the view breaks inside itself, so a line fits
  or holds one cluster, and spaces at a wrap count toward the width and
  wrap. A break never falls inside a ligature. So real rows differ from
  the Lean display model's, which breaks at characters, and that model's
  contract is run over the fake, not over this adapter.
- **A carriage return alone, U+2028 and U+2029 break no line.** Parley
  breaks at each even with no width, and the port says they are content.
  The adapter hands Parley a stand-in of the same length in bytes for
  each, a space for a return and U+FFFD for a separator, so every offset
  stays true. The stand-ins only keep the line whole; what such a
  character looks like is the open question of how escapes are drawn.
- **Positions, cursors and selections are found by cells**, not by a
  line's glyphs as they are listed. A real shaper lists a right-to-left
  run's glyphs in the reverse of the text, draws two characters with one
  glyph (a ligature), and makes one cluster of several glyphs and several
  characters (a letter and its mark). For each visual line layout derives
  its cells: the glyphs of one cluster are one box, the box holds the
  characters from its cluster's offset to the next cluster's, and each
  character has an even share of it, as a browser places a caret inside
  a ligature. The x of a position, the position an x aims for, the goal x
  of a move, a cursor's box and a selection's areas are read from them:
  a cursor on one character of a ligature of two is half the glyph wide,
  and a selection that crosses a change of direction is an area for each
  stretch of the row it covers. The cell stays text storage's, a
  character, so a cursor can still stand between a letter and its
  combining mark, drawn at the even split. On the fake a cell is a glyph
  and every answer is what it was.
- **A font is named by its spec.** `FontSpec` is the port's term for a
  font: a family, a size, a weight, a slant and a line height. A shaper
  gives each spec an id (`Shaper::font`): equal specs one id, different
  specs different ids, for the shaper's life, with the default spec font
  0. A run names its font by that id, so no glyph and no cache comparison
  carries a spec, and the table from an id to its spec is the adapter's.
  The fake's rule for a spec: a family has a cell at the base size of 16
  pixels, a font's advance and own line height are that cell times its
  size over the base size, and weight and slant change no geometry but
  are still another id.
- **What is font and what is paint.** Of a face's attributes the family,
  the size, the weight, the slant and the line height are the font a run
  is shaped in; the line height is among them because it changes a row's
  height. The foreground, the background, the underline and
  strike-through are paint, and never reach the shaper.
- **The scale.** A face's lengths are logical points ("Decorations", as
  built, "A length a face states is in logical points"). Layout holds a
  scale, 1 until `Layout::set_scale` tells it another, and multiplies in
  one place: `Styles::style` puts the font a stack of faces resolves to at
  the scale (`FontSpec::scaled`: the size and a line height stated as a
  length, each to the nearest 64th of a pixel) as it asks the shaper for
  the font's id. The `Shaper` port, its fake, its contract and the real
  adapter are unchanged and in physical pixels. A frame and the answers
  of the queries are in physical pixels at the scale last set, so a
  query after a change of scale answers at the new one with no frame
  between.
  - **In the cache key, as the font.** A kept row is used again only with
    the font runs it was shaped with, and a font's id is the shaper's for
    the physical spec. At another scale every run is in another font, so
    each kept row is shaped again when a frame or a query next reaches
    it, and the status row likewise. Nothing has a scale stored on it.
    Two things are not keyed by a font and are handled by hand: the
    styles kept by stack of faces are dropped on a change, and the base
    font is found again. A theme of 28 points at scale 1 and one of 14 at
    scale 2 share their rows.
  - **What the counters show.** Over the frame after a change of scale
    alone, `shaped` grows by the rows the view shows and `reused` by
    none; over the same frame once more, `reused` by those rows and
    `shaped` by none. Setting the scale a layout already has shapes
    nothing. The status row is no segment and is not in the counters: the
    fake's count of bytes shaped shows it shaped again
    (`tests/counters.rs`).
  - **Where no window exists the scale is 1**, which is the identity: the
    spec handed to the shaper is the spec the faces resolve to. So the
    headless display, Lean's display contract, `tests/display/
    frame.expected` and the renderer's reference image are what they
    were, and no fixture changed.
  - **No rounding of layout's own.** Any positive scale is taken,
    fractional ones among them, and a row is as tall as the shaper makes
    a line of the font. On the fake that is exact and linear: at scale 2
    every length is twice (`tests/scale.rs`). On the real shaper a line's
    height and baseline are whole pixels, by Parley's own quantising at
    the physical size, so a row at scale 2 is twice a row at scale 1 to
    within a pixel: 14 points of the fixture's Noto Sans are rows 19, 24,
    28 and 38 pixels tall at scales 1, 1.25, 1.5 and 2, with line widths
    in exact proportion (seen in a spike, pinned by no test).
  - **Who tells layout the scale** is whoever owns the layout. So far
    that is one caller outside tests, the window example's editor thread
    ("The window, as built"). The display handle Lean publishes to is
    never told one and lays out at 1 (open questions, "A scene published
    from Lean at its window's scale").
- **Decorations.** A source gives the spans of a range of a snapshot and is
  asked only for the rows laid out. Selections and the scene's decorations
  are the first two; a range with equal ends of an exclusive, an inclusive
  or a block selection is a cursor and gives no span, so a cursor move
  changes no row, while a line-wise range covers its rows whatever its
  ends, so one with equal ends highlights its row. A span names its face
  by an id interned from its name, which stays inside layout. Spans are
  collected lowest layer first, the selections' last, so the faces over a
  run are a stack, and the run's font and paint are what the stack
  resolves to by the precedence ("Decorations", as built). Shaping runs
  split only where the font changes. No source is asked for a segment's
  fonts while no face but `default` sets a font attribute.
- **Caches.** An entry keeps its shaped value, the font runs and the
  shaper's generation it was shaped under, and its breaks at one width:
  text and font changes shape again, a width change breaks again, and a
  paint-only change does neither. Faces need no invalidation of their own:
  a face whose font attributes change resolves to another font id, so the
  rows drawn in it are shaped again and no other, and a face whose paint
  changes resolves to the same id, so its rows are reused. A change of
  `default`'s font shapes every row. Entries are moved through the edit log's
  patches, pulled through the view's snapshot, and not cleared; when the
  patch is refused (behind the horizon, or the text is gone) the text's
  state is rebuilt from the snapshot at hand, and a snapshot older than
  what is kept is laid out in a scratch state, so the cache never moves
  backwards. Patches and not the mapper, because entries are keyed by rows,
  which patches give directly.
- **Storage is sparse**: a map of the rows laid out, not a summarised tree.
  A row not laid out counts as one line of the default height until it is;
  a publish drops entries farther than four view heights from every view of
  their text, and the state of every text it does not name. A tree waits
  for a layer that needs sums over a whole text (folds, a scroll bar).
- **The queries** lay out whatever they reach, in the same call, from the
  same entries the frame uses, with the selections and decorations of the
  last frame that showed the text, in the faces as they are now.
- **A row counts as at least a pixel.** The rows a view shows are those
  that fit its height whole, and in that count a visual line is at least
  one pixel tall, whatever height the shaper gave it. So a frame or a rows
  query lays out at most a row for each pixel of its view, and never the
  text from the anchor to its end, which is what lines of no height would
  otherwise come to: they all fit. Lines have no height in a font of size
  0, and on the fake in one of a line height of 0, set by `default` or by
  the face of a decoration or of the selection, and wherever a shaper
  reports none (the real shaper reports none for a size of 0, and a few
  pixels for a line height of 0 at another size); the
  shaper's contract holds only the default font's lines to a height. The
  rule is layout's because the cost is: one walk
  (`crates/editor-layout/src/query.rs`, "The rows that fit") gives the
  frame and the rows query their rows, and it is bounded whatever a face
  or a shaper says. Nothing refuses or changes a size or a line height of
  0, neither the wire nor Lean's binding: that would be a second owner of
  the rule and would bound nothing, since a size of a 64th of a pixel
  makes lines as flat. Only the count changes: a row keeps the height the
  shaper gave it, so in a frame a row of no height is that tall and the
  next row starts where it does. A move counts visual lines, so no height
  changes what it costs.
- **The frame** is a plain immutable value (`Send + Sync`): per view, the
  rows from the anchor's visual line, as many as fit whole, each with its
  glyphs shared with the store, its runs and a content hash; the cursor at
  the head of every range of every selection; and selection areas. A row's
  runs cover its glyphs exactly and a selection's area is as wide as the
  glyphs it covers, so a tab whose spaces cross a soft wrap takes its faces
  and its selection on both rows, over the spaces each holds. A test
  compares a frame as text (`Frame::describe`), and one fixture frame
  (`tests/display/frame.expected`) is compared from Rust and, through the
  real binding, from Lean.
- **The frame carries resolved values and no face.** A run carries its
  paint (a foreground, a background, an underline with its style and
  colour, strike-through), and neighbouring runs of one paint are one run;
  an underline with no colour of its own takes the run's foreground. A
  glyph carries the id of the font it is drawn in. A cursor carries the
  paint of the face the scene names for it over `default`: its background
  is the cursor's colour, and its foreground the glyph's under a block
  cursor. A view carries `default`'s background and the selection's, for
  its selection areas. A row's hash covers its glyphs with their fonts
  and offsets, its runs with their paint, its height and its baseline,
  relative to the row's start; a cursor is no part of a row, so moving it
  or changing its face changes no hash. A font's id is its shaper's,
  given in the order it first drew a glyph in each, so two frames are
  compared, as text or as values, only from layouts handed the same
  scenes and faces in the same order.
- **The frame carries its fonts and a generation.** Beside its views a
  frame holds the shaper's table of resolved fonts and the shaper's
  generation, both read once the views are laid out, so every glyph of
  the frame names an entry of the table it travels with. That is how
  whatever draws frames gets exact font identities with a generation
  stamp, with no call back into the shaper, which the render thread may
  not make: it keys what it keeps by font id and glyph id, and drops it
  all when a frame of another generation arrives. Fonts are compared by
  what they name, never by their bytes. The frame still holds no atlas
  id and no rasterised glyph, and `Frame::describe` prints neither the
  generation nor the table. The `Renderer` port that takes these frames
  was made later, in a crate of its own ("The renderer, as built").
- **The mode line.** A view with at least one status field has a status
  row: its fields' texts one after another with no separator, each in its
  face over `mode-line` over `default`, shaped as one unbroken line
  through the `Shaper` port, at the bottom of the view's rectangle. A tab,
  a carriage return or a line feed in a field is shaped as a space. The
  row is exactly the mode line's line height, rounded up to a whole
  pixel, whatever height its line was shaped at, and the view's text rows
  are those that fit whole in the whole pixels that remain (display
  pipeline phase 6). A view whose rectangle reaches the frame's bottom
  edge and that has a status field has a status row of the message
  height instead, the taller of `echo-area` and `mode-line`: that row is
  the minibuffer's bottom row. A view with no status field is laid out
  across its whole rectangle, at the bottom edge or not. `Layout::heights`
  answers the three heights, text, status and message, so a caller that
  asks the rows query at a view's height less its bottom row is answered
  with the rows the frame shows. The row is kept per view and
  shaped again only when its text or its font runs change. The
  alternatives were to draw it over the last text row, which hides rows,
  or outside the view's rectangle, for which the scene has no rectangle.
- **Counters** count segments shaped, broken and reused, each once per call;
  every cost claim above is pinned by one.
- **The binding.** A document has a key and a snapshot carries its
  document's key and text, held weakly, so layout pulls patches and reads
  markers through the snapshot handle it is given, and Lean's binding needs
  only the read half of its table of snapshots. A published scene crosses
  as words, one string and a list of snapshot handles; markers cross by
  number and are read in the snapshot's document as it is when the scene
  arrives, each on its own. The definitions of the faces cross in the
  same words and string, behind a presence ("The scene", as built); words
  that spell no face are refused, and the frame, the scene and the faces
  published before stay. Who writes the cache, and when a resize is
  shown, is open: [concurrency.md](concurrency.md), "Sharing state".

### The renderer, as built

The display pipeline's phase 4 built the renderer in two crates: the port
and what every back end shares in `crates/editor-render`, and the real
adapters in `crates/editor-render-wgpu`. The facts of each part are in the
module docs; these are the decisions. None is confirmed by the owner yet
(tasks `display-pipeline-renderer-port-owner` and
`display-pipeline-text-core-pitfalls`).

Phase 4 started no thread and opened no surface, and its plan and this
section gave both, with the real clock, to phase 6. Phase 5 built all
three, because a window that draws needs them ("The window, as built",
below): `editor-ffi` starts the render thread and lends the loop the
clock that stamps input, and the wgpu adapter presents to a window's
surface. Phase 6 joined Lean to them, inside the library: a display bound
to the process's presenter (`render::Presenter`, `Display::present_to`)
submits each frame it lays out to the render loop the presenter targets,
stamped with the oldest window input taken off the editor queue since the
last publish (`events::take`), so the journal measures `present − input`
from a key's arrival in Rust. The window's session puts its handle in the
presenter at `Opened` and takes it out at `Closing`; the headless mode's
`--render` session (`render::headless`, over `HeadlessRenderer`) does the
same at start and stop; the latest session's handle stays readable after
it ends, for the journal, the counters and whether its loop is at rest
(`RenderHandle::resting`). The window's display lays out over Parley on
the system's fonts (`editor_ffi_display_new_system`). The presenter is a
value every user is handed; the one process-wide instance is reached only
by the C functions, so no Rust test shares it. A display that is not
bound submits nothing.

- **The `Renderer` port is `editor-render`'s.** It is a crate of its own,
  which depends on `editor-layout` alone, for the reasons the window port
  is: the fake and the contract belong to the port's owner, nothing may
  depend on `editor-ffi`, and `editor-layout` reads no clock and starts no
  thread while the render loop has both. The port is one method that
  takes data and returns data: a frame and a target (a size in physical
  pixels and a scale) in, and out whether it presented and what it cost
  (rows built and reused, glyph images rasterised, reused, evicted and
  skipped, the atlas's bytes). It grows by data: a field of the request
  or of the answer. Reading pixels back is not on the port.
- **What every back end shares is written once, there.** The mailbox
  (one slot; a newer frame replaces one not yet taken, and the stamp kept
  is the older). The scheduler, a pure function of the demands and the
  time passed in. Which rows are built again (`RowCache`: one payload for
  each distinct row hash of the frame last drawn, text rows and status
  rows alike, built only for a hash not held, and begun again under
  another generation or scale). The frame journal and the counters,
  filled by the loop from what a draw returns. Time is a port there, in
  nanoseconds, with a fake a test sets; the crate has no real clock.
- **The loop draws on demand.** A demand is a frame that is not the one
  shown, a dirty mark, a new size or scale, or an animation deadline that
  has come. A frame equal to the one shown, the same value or an equal
  one, is no demand: nothing is drawn. There is at most one draw for each
  refresh interval, which is data: the window tells how often its display
  refreshes, and the interval is the loop's default until it does. With
  no demand the render thread waits on a condition variable with no
  deadline. A resize draws the frame shown again on the new target at
  once, without waiting for Lean. A draw that fails to present leaves
  its demands, and is tried again a refresh later. A target the loop is
  told is hidden is not drawn on at all: what is asked is kept, and one
  draw serves it when the target is shown. A draw whose renderer finds
  the target hidden, when nobody had said so, leaves its demands too and
  is tried again when the loop is next told anything, not a refresh
  later (`Drawn::hidden`).
- **The fake and the contract.** `RecordingRenderer` records every
  request and draws nothing. The contract is nine properties of what a
  renderer says it built: a first frame builds every row; the same frame
  again, a frame that differs only in its cursor and another size at the
  same scale build none; a frame that differs in one row, and one
  scrolled by a row, build that row alone; another generation builds
  every row; rows are counted once for each distinct hash; a frame of no
  views is presented. Both real adapters run it.
- **The drawing is ours: one painter, two devices.** No published
  library draws subpixel text
  ([rendering-prior-art.md](rendering-prior-art.md), "The drawing
  library, as chosen"). The painter turns a frame into a list of quads,
  rectangles of whole pixels that are filled with a colour or read a
  rectangle of a glyph atlas, in drawing order: per view its background,
  each run's background where it is not the view's, the selection areas,
  the glyphs, underlines and strike-throughs, the status row, the
  cursors. A row's quads are kept by its hash, relative to its own start.
  Behind the painter is one of two devices, which only blend the quads:
  the CPU compositor (`HeadlessRenderer`) and wgpu (`WgpuRenderer`). So
  the two adapters are the same code down to the quads and the atlas's
  bytes, and differ in the blend of one quad, which is one function and
  one shader that state the same arithmetic.
- **Where a glyph goes.** At its `x` plus its `dx` across, rounded to a
  quarter of a pixel, and at its row's top plus the baseline plus its
  `dy` down, each rounded to a whole pixel: a baseline is a whole pixel.
- **The glyph cache.** A glyph image is kept by resolved font id, glyph
  id, one of 4 horizontal bins of a quarter pixel, and the kind asked
  for. There are three kinds, each in atlas pages of its own format:
  masks (one coverage a pixel), subpixel masks (a coverage for each of
  red, green and blue) and colour images. An image is pinned by every
  kept row that draws it, and rows are kept for the frame last drawn, so
  a glyph on screen is never evicted; only unpinned images are let go,
  the one unused for longest first. The pages may come to a budget of
  bytes (64 MiB unless a setting says otherwise); past it, unpinned
  images go first, and if what is in use alone needs more, the page is
  added, counted, and given back at a later draw. A frame of another
  generation empties the cache. What cannot be drawn is counted: a glyph
  of a font with no bytes (the fake shaper's), a glyph id past 16 bits,
  an image larger than a page. Rasterising is `swash`, packing the pages
  is `etagere`.
- **Text is blended over what is under it, in linear light.** For each
  of red, green and blue, `out = text × coverage + under × (1 −
  coverage)`: nothing is composited against an assumed background. The
  target holds sRGB values and blending is in linear light, so half
  coverage of white on black is 188, not 128. On a GPU a coverage for
  each channel is dual-source blending; an adapter without it is given
  plain masks and one coverage, and says so.
- **The weight of text matches the platform's: on macOS, Core Text's.**
  The owner's decision (2026-11-14, rdm task
  `editor-render-text-lighter-than-core-text`): match the platform's
  font rendering as closely as possible. On macOS the window's text is
  drawn to Core Text's weight; Linux and every other target keep
  linear-correct rendering, the outlines as they are, until a later
  task decides otherwise.

  How heavy text is drawn is a field of the renderer's settings,
  `Settings::weight`: a contrast, which raises the coverage of dark text
  on a light ground (`blend::adjusted`, on the CPU and in the shader
  alike), and a dilation, which draws each stem that many pixels
  thicker than its outline (swash's `embolden`, in the rasteriser, so
  the GPU reads the same atlas). The default, `Weight::LINEAR`, is 0
  and 0, and draws every byte as before. The macOS setting is
  `Settings::core_text()`: `Weight::CORE_TEXT`, a contrast of 0.1 and a
  dilation of 0.8 px, with hinting off, as the fit chose. The program
  picks it where it wires the renderer: `editor-ffi`'s example `window`
  asks `cfg!(target_os = "macos")` and nothing in the renderer or the
  core names a system. Whatever later makes the editor's own renderer
  applies the same rule.

  Why. Seen by the owner on 2026-11-14: the window in Menlo 14 pt at
  scale 2 beside TextEdit in Menlo Regular 14 pt at 100%, the same
  size, but TextEdit "much heavier". The first measurement held the
  renderer to ratios read off the owner's screenshot (1.49 times the
  dark pixels, 1.09 times the ink), and no single cause reached them.
  Those ratios are superseded: the 1.09 most likely counted the
  window's `#f8f8f8` ground, and TextEdit draws black on white, so part
  of that gap was the colours. The target is now Core Text's own
  drawing of the sentence `the window draws this`, from the fixture
  font at 14 pt on a bitmap of scale 2, black on white, with font
  smoothing on (`tests/coretext/sentence.png`, captured on demand by
  `mise run coretext-reference`; its README says how). The renderer
  draws the same sentence through its CPU path, each glyph at Core
  Text's pen position, black on white, and both are counted the same
  way: *dark* is the pixels below 128, *ink* how far below the white
  ground the pixels are, summed.

  | Drawing | Dark | Ink | Dark / Core Text | Ink / Core Text |
  |---|---|---|---|---|
  | Core Text, smoothed: the target | 1891 | 503470 | 1.000 | 1.000 |
  | Core Text, not smoothed (for comparison) | 1638 | 429519 | 0.866 | 0.853 |
  | The default, `Weight::LINEAR`, hinted | 1321 | 362857 | 0.699 | 0.721 |
  | macOS, `Settings::core_text()` | 1910 | 499078 | 1.010 | 0.991 |

  The fit swept the contrast from 0 to 1 and the dilation from 0 to
  0.8 px in steps of 0.1, with hinting on and off, and took the point
  whose larger miss of the two counts was least: 0.010. Many points
  come within a few hundredths, trading contrast for dilation (a
  contrast of 1 with 0.5 px, hinted, misses by 0.012), so the
  constant is one good point of a shallow valley, not a unique one. The
  earlier candidates' directions still hold and are pinned: dilating
  the outline, raising the coverage, blending on sRGB values and
  drawing black on white each add ink. Even without smoothing Core Text
  draws about a fifth more ink than the default; smoothing adds about
  as much again.

  The caveats. The font is Noto Sans Mono, a stand-in for Menlo, whose
  licence keeps it out of the repository. It is fitted at one size,
  28 px. The dilation is a fixed number of pixels, where Pathfinder
  reads Core Text's stem darkening as growing with the size below about
  25 px ("Risks", in [rendering-prior-art.md](rendering-prior-art.md);
  read, not verified): at other sizes the match is not measured (rdm
  task `editor-render-weight-at-other-sizes`). The target is Core Text
  drawing offscreen into a bitmap, not TextEdit on screen. Beside
  TextEdit, by eye, the owner saw on 2026-11-14 that the window in Menlo
  14 pt is as heavy as TextEdit in Menlo Regular 14 pt at 100%, not
  lighter, compared in Menlo by the example `window` with `--family
  Menlo` (the display's scale not stated). Some of the
  spacing, and maybe the `w`, are not quite the same as TextEdit's: rdm
  task `editor-render-glyph-spacing-and-shape-vs-core-text`.

  Pinned in `crates/editor-render-wgpu/src/weight_tests.rs`: the macOS
  setting within a tenth of both counts, and no worse than its
  neighbours on the grid and the default; the counts are printed by
  `cargo test --locked -p editor-render-wgpu --lib weight_tests --
  --nocapture`, and two runs print the same. That the GPU draws what
  the CPU draws at the macOS weight is checked on demand, by `mise run
  render-gpu` and `mise run linux-render`.
- **Antialiasing is a setting, and by default follows the scale:**
  subpixel masks below 2 physical pixels to a logical one, plain masks
  from 2 up. The order of a display's colour stripes cannot be asked of
  the window system, so it is a setting too (red, green, blue unless
  told otherwise). Hinting is a setting, on by default and off at the
  macOS weight (`Settings::core_text()`). A renderer says which
  kind of mask its last draw asked its glyph images in (`masks()` on
  both adapters: plain, or subpixel with the order of the stripes; none
  before a first draw). It is what the draw did, kept as it did it, and
  not the rule applied again by a caller; the kind says itself for a
  person, so nothing downstream matches on it. The window example prints
  it for each draw, which is how a change of antialiasing between two
  displays is seen.
- **The scale changes what the renderer sizes, and nothing else.** A
  frame is in physical pixels and so is a target. What the renderer
  itself sizes is `max(1, round(scale))` pixels thick: an underline, a
  strike-through, a bar or underline cursor, a hollow cursor's edge.
  Rows built at one scale are built again at another. A theme's lengths
  are multiplied by the scale in layout, before shaping ("Layout and
  rendering", as built, "The scale"), so a frame reaches the renderer
  already at its target's scale, and the renderer multiplies nothing in
  it: nothing is scaled twice.
- **A ligature across a change of paint** is drawn whole in the paint of
  its first byte: a glyph has one cluster, and the painter paints a
  glyph by the run that holds it.
- **How it is tested.** wgpu has no software renderer of its own: a
  machine with no GPU and no driver has no adapter, and the gate runs on
  such machines. So the gate draws with the CPU compositor, and compares
  one frame of real text with one reference image, `tests/render/
  frame.png`, within 2 of 255 a channel; and it runs the wgpu adapter on
  wgpu's no-op back end, which validates every call (the shader, the
  pipeline, every draw, inside an error scope) and draws nothing. What a
  real GPU draws is compared with the same image on demand
  ([the-gate.md](../dev-practices/the-gate.md),
  [on-demand-checks.md](../dev-practices/on-demand-checks.md)).

### The window, as built

The display pipeline's phase 5 built the window the renderer draws in:
the winit adapter's full translation, what a window tells whatever draws
in it, the render thread, the surface, and a clipboard adapter. The facts
of each part are in the module docs of `crates/editor-platform`,
`crates/editor-platform-winit`, `crates/editor-platform-arboard`,
`crates/editor-ffi` (`render`) and `crates/editor-render-wgpu`
(`surface`, `gpu`); these are the decisions. **None is confirmed by the
owner.** Nothing of it reaches Lean: no input variant, no row of the
event table, no Lean module and no C function changed, and the process's
window is still run with nothing drawing in it. The threads are in
[concurrency.md](concurrency.md), "Sharing state".

- **Redraw is on demand, from end to end.** winit's loop waits for the
  next event, and the adapter never asks it for a redraw and never sets
  its control flow. The render thread waits on the render loop's park
  with no deadline. A draw happens because something asked for one: a
  frame was published, or the window said it was resized or damaged. A
  key, the pointer, the focus and a composition ask for nothing by
  themselves: they are input, and it is what the editor publishes in
  answer that draws. The interrupt key is not singled out: every input
  takes one path to the queue.
- **The window tells what draws in it through a second listener.** The
  window port's `Platform::run` takes a drawer beside its report, and
  hands it a `Canvas`: the window opened (with its native window, its
  size and its display's refresh rate), a new size or scale, a new
  refresh rate, damage, hidden or shown, closing. It is not a variant of
  `Input`, because every `Input` becomes an event for Lean and a native
  window is nothing Lean can use. The contract holds the order: the
  drawer hears the window opened before anyone is told of the window, so
  whoever learns of it from the queue finds the render loop there; and it
  hears the window is closing last, before the window is gone.
- **The native window is the port's own data.** `NativeWindow` is an
  AppKit view, an Xlib window or a Wayland surface, as the pointers and
  numbers the system defines. The window adapter fills it from the
  handles winit gives, and the renderer turns it back into the handles
  wgpu takes, each through its own library's re-export of
  `raw-window-handle`: no type of winit, of wgpu or of that crate is
  public anywhere, and no crate of the workspace depends on it.
- **A key's names are winit's, which are the W3C's.** winit documents its
  named keys and key codes as the W3C UI Events values, so a variant's
  own name is taken, and the three places winit says it differs are
  written out: the system key is `Meta` and its codes `MetaLeft` and
  `MetaRight`, and Space is the character it types. A table of some five
  hundred variants written by hand would make every key winit adds
  unidentified until someone listed it.
- **A key's text is what the port documents, not always what winit
  gives.** On X11 winit gives a release the text of its press and gives
  Escape the text U+001B. The port says a release produces no text and
  that a key known by its name produces none. So a release carries none,
  and text that holds a control character is no text: Escape, Enter, Tab
  and Backspace are known by their names. This decides what Lean sees
  for those keys. A key pressed with Control or the system key held
  carries none either: winit on macOS gives Control-A the text `a` and
  Command-S the text `s` (read at the pin, not seen), and on X11
  Control-Shift-A arrived with `A` (seen), where Control-A arrives with
  U+0001. Such a key is a command and inserted nothing, and whatever
  inserts a key's text would otherwise insert `a` on Control-A on macOS
  and nothing on Linux. Shift and Alt leave the text: Alt composes
  characters on macOS. The modifiers are the ones winit last reported.
  The port's fake is not changed: its sample script's first key has
  Control held and the text `a`, and tests on both sides of the Lean
  boundary read it.
- **Modifiers are those winit last reported**, and are not put right. On
  X11 a modifier's own press arrives before the change that names it, so
  the press of Control carries no `control`. No command binds a bare
  modifier.
- **The pointer.** A press and a release are where winit says, and the
  pointer is there after them; winit 0.31 gives a button its position,
  and on macOS says where the pointer is before every press as well.
  A move with a button held is a drag, carrying the button held longest;
  a move with none held is remembered and not reported. Being told the
  pointer is where it already was is no move and so no drag: winit on
  macOS says where the pointer is before every press and every release,
  and a click there arrived as a press, a drag and a release (seen on
  winit 0.30). A wheel is where the pointer last was and carries
  winit's delta as it is, in lines or pixels, positive when the content
  moves right and down. The five buttons winit names are the port's
  five, and every other is another button by winit's number for it (on
  X11, winit 0.31 numbers the buttons with codes 8 to 36 by code less 5,
  where 0.30 gave the code). A touch and a tablet tool are not the
  pointer: winit 0.31 sends them as the pointer's events, and they
  report nothing and leave where the pointer is as it was.
- **Size and scale.** A resize is the new size at the scale last known,
  and a change of scale a resize at the size last known. A window says
  its size as it opens, in a resize straight after `Opened`: the port has
  no other way to say how large a window is, and Lean must know before
  it lays anything out. A size winit says again is reported again: on
  macOS a window says its size four times as it opens, the same each
  time (seen), since winit says it at each step of building the window.
  A resize says how large the window is, not that it changed; the same
  size is no demand to the render loop, and a frame equal to the one
  shown is none either. The scale goes two ways from the window, and
  they have nothing in common. The render loop is told it with the size,
  as its target's, and the renderer uses it for the thickness of the
  lines it sizes and for the kind of mask. Layout is told it by whoever
  lays out for the window, with `Layout::set_scale`, before it lays out
  for that size: in this phase that is the window example's editor
  thread, which reads the scale off the resize it pulled from the queue,
  and nothing else. Lean is handed the scale in the `resize` event and
  reads it nowhere. Between the window saying a new scale and the frame
  laid out for it arriving, a frame laid out at the old scale may be
  drawn once on the target at the new one: the same transient as a frame
  of the old size on a new one, and no longer.
- **Native fullscreen and Spaces need no code of their own.** The window
  is made with winit's default attributes, which are resizable and
  titled, and on macOS such a window has the green button, which puts it
  into the system's fullscreen on a Space of its own. The event loop is
  built without winit's default menu, so a fullscreen shortcut that is a
  menu item's is not there: the button is the way in. To the editor it
  is a burst of sizes: winit reports each change of the content view's
  frame as a resize, the adapter reports it and tells the drawer, the
  render loop draws the frame shown on the newest size at most once a
  refresh (several sizes within a refresh are one draw, on the last),
  and the surface is configured again before a draw of another size. A
  window on another Space is occluded: it is told as hidden, nothing is
  drawn while it is, and it is drawn once when it is shown if anything
  was asked meanwhile. All of that is read, in this tree and in winit,
  and each step is pinned on fakes; **nobody has seen a window of ours
  enter fullscreen, move between displays or change Space.** Two things
  cannot be promised by a resize alone. Between a change of size and the
  next picture presented at it, the system stretches the last picture to
  the layer's new bounds (the default contents gravity of the Metal
  layer wgpu makes: read). And the loop's first draw on a new size is of
  the frame laid out for the old one, with the target cleared to black
  where that frame has no view, until the frame for the new size
  arrives. Each lasts a draw or two; whether either shows during the
  system's animation has not been seen
  ([on-demand-checks.md](../dev-practices/on-demand-checks.md), "The
  window's scale, as seen"). Changing the first is a call on the layer,
  and the second is who lays out on a resize
  ([concurrency.md](concurrency.md)); neither is built.
- **Fullscreen and minimise are commands too.** `toggle-fullscreen` and
  `minimise-window` (`lean/Editor/FrameCommands.lean`), bound by default
  to `C-s-f` (Ctrl-Cmd-F) and `s-m` (Cmd-M), ask the window through the
  display interface (`Display.askFrame`), which the real binding sends
  with `editor_ffi_window_request`. Whether the window is in fullscreen
  comes back on every resize, which the loop keeps in the frame
  (`Frame.fullscreen`), so `toggle-fullscreen` knows which way to go after
  the green button too. The title follows the scene, and is sent to the
  window only when it changes, so a publish per key does not wake the
  window's loop per key. None of it has been seen in a real window:
  that, Ctrl-Cmd-F, the green button, Cmd-M and the title are phase 6's of
  the macOS app roadmap to see.
- **The refresh rate is read after the events that can change it.** winit
  has no event for it. A window comes to be on another display by being
  moved, resized or rescaled, so after each the translation asks the
  display, and tells the drawer when the answer is another than the
  last. The session turns thousandths of a hertz into the loop's
  interval; a display that does not say leaves the loop's default.
- **The surface.** Its format is the first sRGB one it offers, wherever
  that is in the offer, since the blend is in linear light and Metal
  offers a format that is not sRGB first; with none, the first, drawn on
  through its sRGB form. Its present mode and frame latency are the
  choice already on record, `Fifo` at 1, and never wgpu's default, which
  on llvmpipe's surface was a mode that tears. An outdated or lost
  surface is configured again and tried once; an occluded one is not
  presented to, and the draw says its target is hidden, so that the loop
  waits to be told more and not for a refresh. The picture is copied out of the surface only when a
  check asks for it. All of this is decided in one place that makes no
  call of wgpu's (`surface::State`), which reaches the surface through a
  port of two calls, configure and ask for the next texture: the device
  implements the port with wgpu's, and the gate's tests with a surface
  that is a script.
- **The clipboard is a port of its own, below Lean's.** Text in and out
  of the system clipboard, in `editor-platform`, with a fake and a
  contract; `editor-platform-arboard` is the adapter. What the editor
  asks of a clipboard (which register, when, what a yank writes) is the
  clipboard interface in Lean, the command loop's, and binding this to it
  is phase 6's. arboard needs no window, which is what lets the adapter
  be checked without one.
- **How it is tested.** The gate opens no window, makes no surface and
  touches no clipboard. Everything decided is pure and tested there: the
  translation, on winit's own values built in the tests; which call on
  the render loop each thing told becomes, on a loop stepped by hand;
  the session's thread, on the scripted platform and the recording
  renderer; the surface's choices, and when it is configured, what is
  done with each of its answers and how its picture is read, on a
  surface that is a script; how arboard's answers become the port's.
  What is left is the calls themselves, and they run on demand:
  under Xvfb in a container, where the real window keeps the port's
  contract, a fixture frame of real text is drawn in it and read back
  from its surface within 3 of 255 of the CPU's picture (the run fails
  unless every frame's picture was compared), nothing is
  drawn over an idle second, input given by xdotool arrives on the queue
  as documented, and the clipboard keeps its contract in one process and
  across two ([on-demand-checks.md](../dev-practices/on-demand-checks.md),
  "The window on Linux, on demand"). That task, and not the gate, is
  what confirms a window draws and a clipboard round-trips. There the
  example also fails unless each frame's glyphs are drawn at 14 points
  times the scale the window said, and unless the window, each time it
  is left alone for a second, shows a frame laid out for the size and
  scale it last said. At Xvfb's scale of 1 the first of those cannot
  tell a layout that was told the scale from one that was not: that the
  window's scale reaches layout is shown only at another scale. So the
  task runs the window a second time with winit told a scale of 2, and
  requires a frame laid out at scale 2 whose 14 points are 28 pixels;
  with the example made not to tell its layout, that run prints 14 and
  fails, there as on one desktop at scale 2. It is winit that is told:
  no display in the container is at scale 2. The first run ends with a
  change of scale under the open window, from 1 to 2, made by changing
  the display's settings: winit's own event for it, which no test can
  build, is taken apart by the adapter there, and the task requires the
  resize at the size last known and the new scale that the port
  documents. That is one display changing its scale on X11, not a window
  moved between two displays on macOS.
  What the gate holds of the scale is layout's arithmetic and its cost,
  on the fake shaper, and what the example makes of what it saw, in its
  unit tests. What neither holds is for a person: an apparent size
  beside another app, a second display at another scale, fullscreen and
  Spaces. Those steps are written down and have not been run.

### The frame is device-independent

The frame carries positioned text runs with resolved faces, rectangles,
cursors and gutter marks, in layout units. It holds no atlas ids, textures
or rasterised glyphs. Which device it is drawn on is decided by the pair of
adapters behind the `Shaper` and `Renderer` ports:

| Front end | Shaper | Renderer |
|---|---|---|
| GUI | Parley, real font metrics | wgpu |
| Cell grid | Cell shaper: advance is the Unicode width, line height is 1 | Writes the frame into a grid of styled cells |
| Headless | Parley, real font metrics | The GUI's painter, with its quads laid over a picture in memory on the CPU: no GPU and no window |

As built, the headless renderer draws: it is `HeadlessRenderer`, the
same painter as the wgpu adapter's with a CPU compositor behind it ("The
renderer, as built"). The renderer that records the frame and draws
nothing is the `Renderer` port's published fake, `RecordingRenderer`,
which the tests of everything above the port run on. No cell grid
renderer is built.

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

As built (the display pipeline's phase 4, `crates/editor-render`): the
frame journal and the renderer's counters.

- **The journal** has one entry for each frame presented, and none for a
  draw that did not present or for any time in which nothing was drawn:
  an idle editor writes nothing. An entry holds three times read from one
  clock, in nanoseconds: of the input the frame answers, of the start of
  its draw, and of its presentation; and the rows the draw built and
  reused. The input's time is the oldest stamp among the demands the draw
  served: a frame's stamp is its publisher's, a dirty mark and a resize
  are stamped as they are made, an animation by its deadline; and when a
  newer frame replaces one not yet drawn the older stamp is kept, so a
  latency is never flattered. A mark, a size and a deadline ask for the
  frame shown to be drawn again, so what was asked before a first frame
  is shown is no demand of the first draw: its input's time is its
  frame's stamp alone, and a latency is not inflated either. It is a ring
  of the last 4096 entries, and counts those it let go.
- **The counters** count work, never time: draws and failed draws,
  frames submitted and replaced, rows built and reused, glyph images
  rasterised, reused, evicted and skipped, and the atlas's bytes. A draw
  that did not present is counted as failed and nothing more. The wgpu
  adapter paints before wgpu can refuse a draw, so what it painted for a
  refused draw is answered by its next draw that presents, as if the two
  were one draw: the work is counted once, in that frame's entry, and a
  row the refused draw built is there a row built, not a row reused.
- **The clock.** For a latency to mean anything the journal must read the
  clock that stamped the input, which is `editor-ffi`'s. That crate
  implements the render loop's clock port for its input clock, and a
  window's session runs the loop on it: an entry's time from input to
  presentation is a subtraction on one clock. A frame published in answer
  to an event is submitted with that event's stamp.
- **What is not built.** Neither the journal nor the counters reach Lean
  yet. Nothing has been measured with them: the one figure there is, some
  220 ms from a window's size arriving to its first frame presented, is
  of a debug build on a software driver, and includes making the
  renderer. Layout's counters are layout's
  ("Layout and rendering", as built); which ranges have been visible is
  not built.

## Open questions

- **A field of the scene for the prompt.** The prompt text is the
  minibuffer view's status line ("Publishing"), which keeps the scene's
  shape. A field of its own is the cleaner contract, and needs the same
  field in the Rust scene and its binding: whether to make that change,
  and when, is for the display pipeline's work on the minibuffer.
- **The minibuffer's height** (answered): the display's `heights` answer
  sizes it ("The height of a view's text area", below).
- **A summarised tree for the display layers.** The rope is a library's
  ("Text", as built). Display layers, excerpt buffers and decoration
  interval trees favour a sum tree in the style of Zed's; whether they get
  one of their own is for the display pipeline to decide. Phase 1 chose sparse storage of the rows laid out ("Layout
  and rendering", as built) and left the tree to the first layer that
  needs sums over a whole text.
- **How escape characters are displayed.** A raw byte of a file is a
  private-use character in the text. Until the display draws it as its
  byte, it shows as whatever the font has there: the real shaper shapes
  it as the character it is, which is the font's missing glyph. A
  carriage return alone, U+2028 and U+2029 are in the same case: the
  real shaper draws a space for the first and the replacement character
  for the other two, which are stand-ins that keep the line whole
  ("Layout and rendering", as built), not a decision about what they
  look like.
- **A second row rule.** A language server counts a carriage return alone
  as the end of a line; rows here do not. The rope library can count that
  rule beside this one without the stored text changing. The language
  server client decides whether it is needed.
- **Lending a job its snapshots when it is started.** How a job names a
  snapshot is settled ([concurrency.md](concurrency.md), "Sharing state"):
  by the id a command got, read through the table the editor thread
  publishes. A job that was handed its snapshots when it was started would
  read no table at all. That needs a way to start a job with arguments,
  which the command loop adds, and can be added beside what is built.
- **Who forgets the log, and when.** The log is bounded only by Lean
  forgetting ("The edit log", as built), and nothing does yet. The command
  loop or review decides, knowing which consumers are behind and whether a
  review still needs the provenance.
- **Provenance older than the horizon.** Forgetting loses who wrote the
  older bytes. Whether that is kept somewhere cheaper, such as a run map
  beside the text or a record written when a commit is made, is for review
  to decide.
- **The table of origins.** An origin is a number whose meaning is Lean's.
  Three are fixed: 0, `unattributed`; 1, `user`, the user's own edits; and
  2, `disk`, a reload from disk ("The edit log", as built). The rest of the
  table, from numbers to commands, agent sessions and tool calls and
  formatters, arrives with the things that produce those edits.
- **Rebasing a stale transaction.** A transaction built for an older
  revision is refused by its length. The log keeps no text, so it cannot
  supply the change sets to rebase through. The kept inverses do not settle
  it either: each is a revision's own inverse, holds only what its
  transaction removed, and may have been dropped. The first job that
  proposes an edit settles where the change sets come from
  ([concurrency.md](concurrency.md)).
- **Bounding the undo tree, and pruning it.** Nothing prunes a node, and
  the library keeps an inverse for each edge and for each transaction of a
  group that has not been crossed. A bound (by count, by bytes, by age) is
  the command loop's policy; pruning a branch is dropping its edges' runs.
- **A text that keeps no inverses.** A text nobody undoes (a transcript, a
  log buffer) keeps an inverse for each transaction until Lean drops it.
  There is no switch that keeps none; whoever makes such buffers decides
  whether dropping after each edit is enough.
- **Squashing a closed group's inverses.** A group that has not been
  crossed keeps one inverse for each of its transactions, and they are
  composed when the group is first undone. Composing them when the group
  is closed would hold less; nothing measured asks for it yet.
- **Whose text an inverse's is in a trace.** Text an undo restores is
  traced to the undo, with the origin it was given, not to whoever first
  wrote it. Review, which reads provenance, decides whether an undo should
  carry the original author forward.
- **A query for a text's state.** Neither half can be asked which state a
  text is in: the library only accepts or refuses an inverse, and the tree
  knows only the moves it made. So an inverse applied behind the tree's
  back is a new state to the tree, which may say "modified" of a text that
  is back in its saved state. A query would settle it if a caller needs it.
- **A history that survives a restart.** The tree is a Lean value and the
  kept inverses are in memory: both are lost at a restart.
- **A selection a later transaction of a run carried.** When a run's first
  transaction carried no selection, none is handed back, though a later one
  did. Taking a later one back through the transactions before it is one
  function in the library and one in the model if a caller needs it.
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
  knows clusters, in view. The real shaper did not decide it: layout's
  cells are characters, so a cursor can stand between a letter and its
  combining mark, where it is drawn at an even split of the cluster's box.
- **Character classes for words outside ASCII.** For the motions a word
  character is an ASCII letter, digit or underscore, or any character from
  U+0080 up; Vim has a table of classes for other scripts, punctuation and
  emoji, which is not copied. Measured against Vim 9.1 (patches 1-1752):
  the two agree on ASCII text and on `é`. They differ in that an emoji, CJK
  text and punctuation outside ASCII (`—`, `“`, `”`) are word characters
  here and classes of their own in Vim; a no-break space and the other
  Unicode spaces are word characters here and blank in Vim; and a combining
  mark is a cell and a word character here and part of the character before
  it in Vim, which the word motions show after punctuation (`!` and a mark
  are two words here). `×` and `÷` are word characters in both. A fix is
  one table, in the library's private module for a character's class and in
  the Lean model, and nothing else changes. Evil's word motions (`w b e`
  and `W B E`) are where a user meets this: they are the primitives taken
  a count of times ([keymaps-and-modes.md](keymaps-and-modes.md), "Motions
  as built"). Their checks use ASCII text and one text with `é` and `ö`,
  and restate no class, so a fix to the table breaks none of them.
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
  simpler. Undo did not need it: applying an inverse hands the selection
  back, and the caller places it.
- **Tabs** (answered): expanded before shaping, in the tab layer ("Display
  layers", as built). Tab stops on a proportional font are counted in
  spaces, not in pixels, until an align-to-stop primitive exists.
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
- **Large files and long lines** (long lines answered): a row is laid out
  in segments of at most 4096 bytes ("Display layers", as built). What a
  file of many megabytes costs beyond the rows shown (the estimate walks
  every row) is not measured.
- **Two views of one text at two widths.** Layout keeps one width per
  text, so two views of one text at different widths break each other's
  rows again on every frame. Keeping breaks per width is an addition when
  splits of one buffer arrive. Evil's `j` and `k` are a second asker at
  another width with one view alone: each asks about the cursor's line
  and the line it goes to with the text unwrapped (the command loop's
  phase 16), and the next frame asks at the view's width, so the rows both
  touch are broken again each time, not shaped again. What that costs is
  not measured.
- **Where the echo area, the pending prefix and the preedit are drawn**
  (the echo answered, as built): messages share the minibuffer's bottom
  row, as in Vim and Emacs (the owner's decision, 2026-11-15). With no
  prompt open, the minibuffer's place is one `message` row at the frame's
  bottom and holds no view, and layout ends the frame with one more view
  frame there when the scene's echo is not empty and no view's rectangle
  overlaps that row: id `u64::MAX`, which the wire never sends, no text
  rows and no cursor, and one status row of the echo in face `echo-area`.
  With a prompt open, the minibuffer's view covers the row and its status
  row, the prompt, is drawn there. Opening a prompt clears the echo, as
  Vim does (`EditorState.openPrompt`), so the row is empty when the prompt
  closes until a command says something; a key's command clears it too
  before it runs, so what a job's command said while the prompt was open
  shows only if the prompt is closed by something other than a key. The
  pending prefix and the preedit are still drawn nowhere: tasks
  `show-pending-key-prefix` and `draw-input-method-preedit`.
- **The height of a view's text area, for the rows query** (answered, as
  built): the display answers one more question, `heights` (text, status
  and message, each a whole number of physical pixels rounded up, at the
  display's scale), and layout makes a view's status row exactly `status`
  tall, or `message` tall for a view with status fields whose rectangle
  reaches the frame's bottom edge, the minibuffer's while a prompt is open;
  a taller glyph is clipped to the row. Lean asks about a view with its
  height less its bottom row (`EditorState.bottomRow`,
  `Scroll.Area.ofRect`), so the rows a query answers are the rows the frame
  shows (`editor-layout`'s `tests/heights.rs`; the milestone fixture's
  `agree`). The minibuffer's place takes `message`, and `text + message`
  while a prompt is open, in place of the 32-pixel placeholder. The rule
  that names the minibuffer's view by its reaching the bottom edge holds
  while the minibuffer is the bottom leaf of the split tree; a layout that
  put a window there would need a field of the scene.
- **Sizes and the window's scale factor** (answered): a theme states its
  lengths in logical points, and layout multiplies them by the scale
  factor of the target it lays out for, before shaping ("Decorations", as
  built, "A length a face states is in logical points"; "Layout and
  rendering", as built, "The scale"). The real shaper still takes sizes
  as physical pixels, and hints nothing.
- **A scene published from Lean at its window's scale** (answered, as
  built; the owner's decision, 2026-11-15): inside the library. The
  process's presenter keeps the scale the window last said (`Opened`,
  `Resized`), and a display bound to it sets that scale on its layout,
  under layout's lock, before each publish, each query and each heights
  answer. Lean's scene, the wire, the display interface and its model do
  not change, and Lean never handles a scale. The cost: for the one
  publish before Lean reads a newer resize, a scene whose rectangles were
  computed for one size may be laid out at the scale of the next. The
  other way, a scale in the scene that Lean passes on, was set aside.
- **A kept row's height in the estimate, after a change of font or of
  scale.** `Layout::height_estimate` counts a kept row at the height it
  was last laid out at, without asking whether it would be laid out the
  same now. After a change of the default face's font, and after a
  change of scale, every kept row is such a row until a frame or a query
  reaches it again, so the estimate is of the old heights for the rows
  kept and of the new one for the rest (seen in a spike: 84 where 112 is
  right). Nothing outside layout's own tests calls the estimate yet.
  Dropping everything kept when the scale changes would also settle it
  for a change of scale, at the cost of shaping rows a view may not show
  again; it is the first reason to prefer that to keeping the scale in
  the key as the font.
- **The names of a face's lengths.** `Pixels`, `Pixels.whole` and
  `LineHeight.pixels` in Lean, and `Length::pixels` and
  `LineHeight::Pixels` in Rust, name a unit a face's lengths are no
  longer in. Their documentation says so in each place; a reader of code
  alone can be misled. Renaming them touches every theme, config's
  faces and the wire's documentation for no change of behaviour, and
  awaits the owner.
- **Right-to-left geometry.** Layout's cells have no direction, since
  the port's glyph carries none. So three things are not right for
  right-to-left text: the cells of a right-to-left cluster of several
  characters are placed left to right; a position on a right-to-left
  cell, and a bar cursor there, is at the cell's left edge, though the
  character starts at its right; and the position at the end of a line
  that ends in right-to-left text is at the line's right edge. A
  direction on the glyph, or on the cluster, would settle all three.
- **A ligature in a right-to-left run.** Its glyph is placed at the left
  edge of the leftmost of its clusters. No fixture font has such a
  ligature, so this is shown on clusters written out by hand and on no
  real font.
- **What a segment boundary cuts.** A row longer than 4096 bytes is
  shaped in segments, so a ligature, a cluster or a right-to-left run
  that crosses a boundary is shaped as two.
- **A ligature across a change of paint.** It is one glyph, and a row's
  runs name paints by byte, so which paint it is drawn in is the
  renderer's choice. The renderer draws it whole in the paint of its
  first byte ("The renderer, as built"); splitting the glyph's image at
  the change is not done.
- **The renderer's choices await the owner.** Where the `Renderer` port
  lives, and that the drawing is ours and not Vello's
  ([rendering-prior-art.md](rendering-prior-art.md)), are decisions the
  plan of the display pipeline's phase 4 took and the owner has not
  confirmed.
- **No present mode has been measured.** `Fifo` at a frame latency of 1
  was chosen by reading wgpu's source. A surface exists now, and one has
  reported what it offers: llvmpipe's, on an X11 window under Xvfb, where
  the choice was configured and frames were presented. What Metal's
  offers is still what was read. The editor can now be measured on a
  window: `--present-mode`, `--frame-latency` and `--report` ask for
  another presentation for one run and print what the surface offered and
  the journal's figures. No figure from a real window has been taken yet
  (`docs/dev-practices/on-demand-checks.md`, "The present mode, measured
  on a window")
  ([rendering-prior-art.md](rendering-prior-art.md), "Present mode and
  pacing").
- **Where the window has drawn, and where it has not.** The surface, the
  render thread and the window's translation run on Linux under Xvfb, in
  a container, whenever `mise run linux-window` is run. On macOS the
  window that draws has been run on one desktop, on Metal, on one
  display at scale 2: its picture matched the headless renderer's within
  1 of 255, and what failed there was the check's and has been changed
  ([on-demand-checks.md](../dev-practices/on-demand-checks.md), "What
  the first desktop run showed"). Not seen anywhere: a display at scale
  1 beside one at scale 2 and a window moved between them, the system's
  fullscreen, another Space, a resize by hand, Wayland, x86_64
  ([concurrency.md](concurrency.md), "Still to verify").
- **The window's choices await the owner**: that the render thread draws
  and the main thread does not; that the window tells what draws in it
  through a second listener of the port, with its native window as the
  port's own data; that a key's text is none for a release and for a
  control character, which decides what Lean sees for Escape and Enter;
  that a key's text is none when Control or the system key is held, and
  kept under Shift and Alt, which decides what Lean sees for Control-A
  and Command-S and is the adapter's reading of the port's "what it
  produced to insert", made after a review and confirmed by nobody (if
  it stands, the text of the fake's sample key with Control held is the
  next thing to change; if it does not, the port says that text is not
  dropped under those modifiers and whoever inserts it checks them); and
  where the clipboard's port lives. What that rule does on macOS for
  Control-A and Command-S has been read and not seen.
- **The GPU's picture is checked on demand only.** The gate checks the
  wgpu adapter's calls, on a back end that draws nothing, and the CPU
  compositor's picture. That a real GPU draws the same is seen when
  someone runs `mise run render-gpu` or `mise run linux-render`, and
  after a change to the shader nothing makes them. The shader and the
  CPU's blend state one arithmetic twice, kept alike by hand.
- **No colour glyph from a real font.** No fixture font has one. Colour
  is tested in the cache, the painter and the compositor on images the
  tests make, and never through the rasteriser. No GPU has drawn a
  colour image either: the on-demand check draws the fixture frame, in
  subpixel masks and in plain ones, and that path of the shader is only
  validated. COLR version 1 glyphs are not drawn in colour by `swash` at
  the pin, and a colour bitmap's alpha convention was not checked.
- **What only a person at a display can tune.** Hinting (on by
  default, off at the macOS weight), the weight of text (a per-platform
  setting: linear by default, and on macOS fitted to Core Text's drawing
  of one sentence at one size, "The renderer, as built"; beside
  TextEdit in Menlo the owner saw it as heavy, by eye), the
  amount of synthetic bold, where an underline and a
  strike-through sit (the frame carries no metric for either), and the
  default atlas budget and page size. The order of a display's colour
  stripes is a setting nobody sets yet.
- **What the frame does not carry is not drawn.** The echo area, the
  pending key prefix and the input method's preedit are in no frame.
  Boxes, images and gutter marks are not in the frame either. A curly
  underline is a stepped line.
- **The whole frame is drawn on every draw.** Quads are kept per row,
  but every quad of the frame is sent and blended again, and no damage
  is reported to the compositor. An atlas page is sent to the GPU again
  whole when a glyph is added to it.
- **x86_64 is unverified** for the renderer throughout: the reference
  image was made, and every check run, on aarch64. The comparison's
  tolerance of 2 is for that.
- **Zero-width characters.** U+200B and U+200D ride on the line of the
  cluster beside them in Parley. The shaper contract's texts hold none,
  and its rule that a line fits its width says nothing of them.
- **A line height shorter than its font.** The real shaper gives a line
  of the height asked in pixels only when the line still holds its
  baseline: under about three quarters of the size it is a little taller,
  and a line height of 0 is a few pixels, not none ("Layout and
  rendering", as built). Nothing needs such heights yet.
- **The system's default family.** The system font set's default is the
  first family fontique gives for the generic `monospace`, which on
  macOS was Courier when it was checked. Which family the editor starts
  in, and whether config names it, is not decided.
- **The system's fonts on Linux, and when they change.** No gate runs
  the system font path: `mise run shaper-system` is on demand, and it
  has been run on macOS only. The Linux build of the pin is checked by
  `mise run linux-ci`, which builds it with cargo alone and runs the
  fixture tests. Nothing watches the system's fonts for changes: a
  shaper can be handed other fonts, under another generation, and
  nothing calls that.
- **Face inheritance.** A face cannot name another as its base. A theme
  that wants `comment` to follow `default` leaves the attributes unset,
  which covers the one level the precedence gives; anything deeper is not
  built.
- **Where a decoration source that is not the scene's sits in the
  precedence.** Syntax highlighting is a third source. The order has a
  place below the scene's decorations, which a test hook uses; the source
  states its place when it is added.
- **Accessibility of text not laid out**: only visible lines have layout,
  but a screen reader may want to read past the viewport. Expose the
  viewport and scroll on request, or supply unlaid-out text as well?
- **Accessibility coverage**: what AccessKit supports on each platform,
  and how its text model fits ours, have not been checked.
