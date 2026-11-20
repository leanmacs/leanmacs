//! Text storage: a text that can be edited, and what can be read of it.
//!
//! A [`Text`] holds the text of one buffer. Every read goes through a
//! [`Snapshot`], which is the text as it was at one moment. The crate is
//! pure: it does no I/O of its own, reads no clock, starts no thread and
//! knows nothing about Lean. It reaches a file system only through the
//! [`fs::Fs`] port, which it defines and whose real adapter is another
//! crate (`editor-fs-std`); the crate's `clippy.toml` refuses a line of it,
//! a test included, that names a real file, a process or a clock.
//! `editor-ffi` puts a text behind a handle for the Lean editor.
//!
//! # The text model
//!
//! - **A text is UTF-8**, always valid. The rope, shaping, a parser and a
//!   Lean string all want that.
//! - **A byte of a file that is not part of valid UTF-8 is kept as one
//!   reserved character**, `U+10DC00` plus the byte, and saved as that one
//!   byte. So the bytes of a file loaded ([`Text::from_bytes`]) and saved
//!   unchanged ([`Snapshot::to_bytes`]) are identical, for every file. The
//!   private module `bytes` has the mapping, why it is an escape and not a
//!   table beside the text, and what it costs.
//! - **Line endings are kept as they are.** Nothing is normalised on the
//!   way in or out, so LF, CRLF and mixed files come back byte for byte.
//!   Which ending a new line gets is the editor's policy, not this crate's.
//! - **An offset** is a byte offset into that UTF-8. **A position** is an
//!   offset that is a character boundary within the text, its end included
//!   ([`Snapshot::is_char_boundary`]). Offsets are the unit the Lean editor
//!   speaks.
//! - **A row** begins at the start of the text and after each line feed.
//!   So a text has one more row than it has line feeds
//!   ([`Snapshot::row_count`]): an empty text has one row, and a text that
//!   ends in a line feed has an empty last row. A carriage return is an
//!   ordinary character of its row: the rows of a file with CRLF endings
//!   end in one, and a carriage return alone starts no row. This is
//!   tree-sitter's rule. [`Snapshot::row_range`] is a row's bytes without
//!   its line feed.
//! - **A point** is a row and a column counted from the row's start: in
//!   bytes ([`Point`]), in UTF-16 code units ([`PointUtf16`]) or in cells
//!   ([`PointCells`]). They are three types so the units cannot be mixed.
//!   A column in cells is how many cells of the row start before the
//!   position, which is the column a block's corners are counted in. So in
//!   a row that ends in a carriage return and a line feed, the column just
//!   past the content's cells is the carriage return's position, and the
//!   position between the two bytes is one column further, the row's last.
//! - **A conversion answers only for a position**, and clamps nothing:
//!   clamping is the caller's policy. An offset converts to a point only if
//!   it is a position. A point converts to an offset only if it names one:
//!   a row the text has, and a column within the row that is not inside a
//!   character (in UTF-16, not between the two units of one). So the
//!   conversions are inverses wherever either answers.
//! - **A replace** puts a string in place of the bytes between two
//!   positions ([`Text::replace`]). It is refused, changing nothing, unless
//!   both ends are positions and are in order.
//! - **A change set** ([`ChangeSet`]) is an edit as a walk over the whole
//!   text: changes that keep the next bytes ([`Change::Retain`]), remove
//!   them ([`Change::Delete`]) or put text in ([`Change::Insert`]), with
//!   lengths in bytes. It is for a text of one length
//!   ([`ChangeSet::len_before`]) and makes one of another
//!   ([`ChangeSet::len_after`]). It is kept in one normal form, so two
//!   change sets that do the same thing in the same places are equal: no
//!   change of length zero, no two neighbours of one kind, and where bytes
//!   are replaced the insert is before the delete.
//! - **A change set fits a text** only when it is for the text's length and
//!   every boundary between two of its changes is a position. One that
//!   stops short of the text's end is refused, not padded with a retain,
//!   so a change set built for another state of the text is caught where
//!   the lengths differ.
//! - **Change sets compose and invert.** [`ChangeSet::compose`] is the
//!   change set that does one and then another, and [`ChangeSet::invert`]
//!   the one that undoes a change set, given the text before it for the
//!   bytes it deleted. Composition is associative, and the inverse of an
//!   inverse is the change set, as values.
//! - **A position is mapped through a change set with a bias**
//!   ([`ChangeSet::map`], [`Bias`]), which says whether it stays before or
//!   goes after text inserted at it. The table is on the method. Many
//!   positions are mapped in one walk of the change set by a [`Mapper`]
//!   ([`ChangeSet::mapper`]), which answers as [`ChangeSet::map`] does.
//! - **An anchor** ([`Anchor`]) is an offset and a bias: a position that is
//!   kept where it was in the text by mapping it through each change set
//!   ([`Anchor::map`]), as an Emacs marker is moved by each edit. Two
//!   anchors of one bias never pass each other, and one that stays before
//!   inserted text never passes one that goes after it.
//! - **A selection is mapped through a change set** ([`Selection::map`])
//!   by mapping each end as an anchor, with a bias that follows from the
//!   shape (the table is on the method), and putting the result in the
//!   selection's form again, so ranges an edit brought together are one.
//! - **A marker** ([`Marker`]) is an anchor or a selection that a text
//!   holds ([`Text::mark`]) under an id ([`MarkerId`]) the text gives out
//!   and never uses again. Every transaction the text accepts moves every
//!   marker, [`Text::replace`] included, and a refused one moves none, so
//!   a marker read back ([`Text::marker`]) is always at positions of the
//!   text as it is. A marker is checked against the text when it is made
//!   or put somewhere else ([`Text::place`]): an anchor that is at no
//!   position, or a selection with an end at none, is refused
//!   ([`MarkError`]). Marking, placing and giving a marker up
//!   ([`Text::unmark`]) are not edits: they change neither the revision
//!   nor the log, and no snapshot holds a marker. Moving the markers costs
//!   one walk of the transaction's changes and a sort of the ends held.
//! - **A transaction** ([`Transaction`]) is a change set and, optionally,
//!   the selection before it and the selection after it. Applying one
//!   ([`Text::apply`]) is the one way a text changes, and it is all or
//!   nothing: a transaction is refused, changing nothing, unless its change
//!   set fits the text and every end of each selection is a position of
//!   its own text, the one before or the one after. [`Text::replace`] is
//!   the transaction with one change and no selection, and the inverse of
//!   a run ([`Text::apply_inverse`]) is a transaction applied by the same
//!   path: there is one writer path.
//! - **The inverse of every accepted transaction is kept**, by the
//!   revision the transaction produced: the transaction that undoes it
//!   ([`Transaction::invert`]), which holds the bytes it removed, only the
//!   lengths of what it inserted, and its two selections swapped. One
//!   direction only: a transaction that inserts a megabyte keeps a few
//!   bytes, and the other direction is made when it is needed, because
//!   applying an inverse keeps *its* inverse, which reads what it is about
//!   to remove back out of the text, once. Nothing hands a kept inverse
//!   out: text that was deleted stays in the crate.
//! - **A state** is where a text is in its history, not what it holds.
//!   The text names the state it is in by the revision of the transaction
//!   that first put it there, and 0 as it was made. A transaction puts the
//!   text in a new state; the inverse of a run puts it back in the state
//!   it was in before the run, under that state's name. A revision cannot
//!   say this, since an inverse makes a new revision that holds old text.
//!   A name is given once, to the text one transaction made, and an
//!   inverse only copies one, so whenever the text has a name it holds
//!   byte for byte what it held when the name was given. Comparing what
//!   two states hold would cost the text, and a text typed back by hand
//!   to what it held is a different state in every editor. Nothing
//!   answers which state a text is in: the names are kept with the
//!   inverses and only decide whether an inverse is allowed.
//! - **The inverse of a run of consecutive revisions is applied as one
//!   transaction** ([`Text::apply_inverse`]): one new revision and one log
//!   entry, with the origin the caller passes, and every marker moved
//!   through the one change set, which is the run's kept inverses
//!   composed. It is allowed only when the text is in the state the run
//!   ended in, and is otherwise refused with the text as it was
//!   ([`InverseError`]). Its own inverse is kept like any other's, so a
//!   redo is the inverse of an undo and there is one primitive. In the log
//!   an inverse is an edit like any other: text it puts back traces to it
//!   ([`Text::trace`]), not to whoever first wrote it. A marker moves
//!   through it as through any transaction and not back to where it was:
//!   an anchor inside text that was deleted collapsed to a point then, and
//!   is before or after the text when it is put back.
//! - **Applying an inverse hands back the selection in force before the
//!   run** ([`Inverted`]): the selection before that the run's first
//!   transaction carried, or none when it carried none. A text holds no
//!   current selection, so placing it is the caller's. The inverse of an
//!   inverse hands back the selection after that the run's last
//!   transaction carried.
//! - **The kept inverses are bounded only by [`Text::drop_inverses`]**,
//!   which drops those of a run of revisions; a run, and not everything
//!   up to a revision, because what a history no longer needs is not a
//!   prefix. The inverse of a run that names a dropped revision is refused
//!   ([`InverseError::NotKept`]), whatever state the text is in. The crate
//!   never drops an inverse by itself, not even those of a run it has just
//!   inverted: whether they are still wanted is the history's to say. So
//!   what grows without bound is one kept inverse for each accepted
//!   transaction until the caller drops it, each holding the bytes its
//!   transaction removed, its two selections and two state names; a text
//!   nobody undoes keeps them all the same. Dropping inverses and
//!   [`Text::forget`] are independent: one leaves the log and the other
//!   every kept inverse, and an inverse of a run whose entries the log
//!   has forgotten still applies.
//! - **A selection** ([`Selection`]) is one or more ranges of two offsets,
//!   an anchor and a head ([`SelectionRange`]), one of them the primary,
//!   with one [`Shape`] for them all. It is kept in one form whatever it
//!   was built from: the ranges sorted by start and then by end, and ranges
//!   that overlap made one, from the lowest start to the highest end. In
//!   the exclusive shape two ranges overlap when the later starts before
//!   the earlier ends or both start at one offset, so ranges that only
//!   touch stay two; in the other shapes, whose ends are on characters,
//!   when the later starts at or before the earlier's end. A merged range
//!   points the way the primary did if the primary is in it, and otherwise
//!   the way its first range did. The primary is the range the one given
//!   as primary ended in.
//! - **A cell** is the unit a cursor is on: one character, or a carriage
//!   return and the line feed after it together. A character is a Unicode
//!   scalar value, not an extended grapheme cluster. The private module
//!   `cell` is the one place that says so.
//! - **What a selection covers** is computed against a text
//!   ([`Snapshot::extents`]): the ends of a range say where two cursors
//!   are, and the shape says what is selected between them. An exclusive
//!   range covers from its lower end up to its higher; an inclusive one
//!   through the cell at its higher end; a line-wise one the whole rows of
//!   both ends, through the last one's line feed; a block, on each of its
//!   rows, the columns between its corners, counted in cells and cut off
//!   at the row's content. The table is on the method. So a cursor on a
//!   character is an inclusive range with equal ends: on the last
//!   character of a line it covers that character and not the line break,
//!   on an empty line it covers the line break, and at the end of the text
//!   it covers nothing. No end is clamped: keeping a cursor off a line
//!   break is the editor's rule.
//! - **A motion** ([`Motion`]) leads from a position of a text to another
//!   ([`Snapshot::motion`]), and is refused from an offset that is none.
//!   It moves by the cell, so the next cell from a position is the end of
//!   what an inclusive cursor there covers. A *cell start* is a position
//!   where a cell starts: every position but the one between a carriage
//!   return and the line feed after it, and not the end of the text. The
//!   next cell is the first cell start after a position, or the end of the
//!   text; the previous cell the last before it, or 0. The line break is a
//!   cell like any other, so both cross lines. The start of a line is
//!   where the position's row starts, its end where the row's content
//!   ends, before its line break, and its first non-blank the first
//!   position of that content whose character is neither a space nor a
//!   tab, or the content's end when there is none.
//! - **A word** is a longest run of neighbouring cells that are all word
//!   characters or all punctuation, and **a WORD** a longest run of cells
//!   that are not blank ([`WordKind`]). A blank is a space or a tab. A
//!   word character is an ASCII letter, an ASCII digit, an underscore, or
//!   any character from U+0080 up, and every other character is
//!   punctuation; the private module `word` is the one place that says so.
//!   A line break separates words as a blank does, but the line break of
//!   an empty line, a row with no content that has a line break, is a word
//!   alone. A word starts where its first cell starts and ends where its
//!   last cell starts, the position of a cursor on its last character. The
//!   next start or end of a word is the first after a position, or the end
//!   of the text; the previous one the last before it, or 0. The next end
//!   passes over empty lines, and the other three stop on one.
//! - **A motion to another row** takes a count of rows and a column in
//!   cells ([`Motion::RowsUp`], [`Motion::RowsDown`]). It answers the
//!   position that many cells into the content of the row that many rows
//!   up or down, or where that content ends when it has fewer cells, and
//!   never a position past the content. Past the first or the last row it
//!   stops there, and a count of 0 stays in the position's own row. The
//!   column of a position is its [`PointCells`] column.
//! - **A motion walks the rope** from the position, a cell at a time, and
//!   builds nothing: no string and no list of the text's cells or words.
//!   No answer is clamped: which motion a key runs, a count as repetition
//!   and keeping a cursor on a line are the editor's rules.
//! - **A pair** is read as a motion is, by a walk of the rope from a
//!   position that builds nothing, and is refused from an offset that is
//!   none. The bracket a walk leaves unbalanced ([`Snapshot::unmatched`])
//!   is the first bracket of a kind ([`Bracket`]) and a side, opening or
//!   closing, strictly after the position or strictly before it, at which
//!   the brackets of the other side met have all been matched; only
//!   brackets that are escaped, after an odd number of backslashes, or
//!   only those that are not, are counted, and the walk crosses rows. It
//!   reads quotes as any other character, or, when asked, passes over the
//!   brackets Vim's default `cpoptions` guesses are quoted, by its guess a
//!   row at a time. The quoted string round a
//!   position ([`Snapshot::quoted`]) is a pair of quotes of a kind
//!   ([`Quote`]) in the position's row, found by Vim 9.1's rule, in which
//!   a backslash escapes the character after it. Both are Vim's, and what
//!   a key makes of them (`%`, a block or quote object, a count, the
//!   blanks round a string) is the editor's.
//! - **An origin** ([`Origin`]) says who made an edit. It is an opaque
//!   number given when a transaction is applied, not part of the
//!   transaction. The crate keeps it in the transaction's log entry
//!   ([`Text::entry`]) and never reads its value; what a number stands for
//!   is the caller's table. [`Text::replace`] records the default, 0.
//! - **The edit log** has one entry for each transaction a text accepted
//!   ([`Text::entry`], [`LogEntry`]): the revision it produced, its origin,
//!   and its edits. **An edit** ([`Edit`]) is one changed range, for each
//!   run of deletes and inserts between two retains: a span of the text
//!   before and a span of the text after ([`Span`]), each as byte offsets
//!   and as points. That is four points, because a change that follows
//!   another in one transaction starts at different points in the two
//!   texts; the three an incremental parser takes are derived from them
//!   ([`Edit::input_edit`]). The log stores no text.
//! - **A consumer pulls what changed**; it is not sent each edit.
//!   [`Text::changes_since`] a revision is one [`Patch`], however many
//!   transactions were applied since: its edits' old spans are ranges of
//!   the text at that revision and their new spans ranges of the text now,
//!   in order, with no two overlapping or touching. Changes that came to
//!   overlap or touch are one edit, and text inserted and deleted again in
//!   between is in none. **A subscriber is a revision** the consumer keeps
//!   ([`Text::subscribe`], [`Text::pull`]): nothing is registered with the
//!   text, so there is no queue of edits for a consumer and nothing to
//!   release.
//! - **A range of the text is traced to the entries that wrote it**
//!   ([`Text::trace`]): the range comes back cut into pieces, each with
//!   the revision and the origin of the transaction that inserted its
//!   bytes ([`Source::Entry`]). The log is walked back from its newest
//!   entry; no second structure is kept beside the text, so an edit pays
//!   nothing for it.
//! - **The log is bounded only by [`Text::forget`]**, which drops the
//!   entries up to a revision and moves the log's horizon
//!   ([`Text::horizon`]) there. The crate never drops an entry by itself:
//!   when to forget is the editor's policy, since the editor knows who
//!   still reads the log. Behind the horizon [`Text::changes_since`] is
//!   refused ([`LogError::Forgotten`]), so a consumer that far behind
//!   reads a snapshot whole and subscribes again; and bytes written at or
//!   before the horizon trace to [`Source::Earlier`], with the horizon's
//!   revision, never to nobody.
//! - **A revision** counts the transactions a text has accepted
//!   ([`Revision`]). A new text is at 0, every accepted transaction adds
//!   one, however many changes it has and one that changes nothing
//!   included, and a refused one adds none. It only grows: the inverse of
//!   a run is an accepted transaction, so undoing adds one too, and two
//!   revisions may hold the same text.
//! - **A snapshot** is the text at one revision ([`Text::snapshot`]). It
//!   never changes, whatever is done to the text afterwards, and it outlives
//!   the text. Taking one copies none of the text, and so does cloning one.
//!   It is `Send + Sync`: a snapshot is what a worker thread, a job or the
//!   renderer reads, and none of them sees the text itself. Two snapshots of
//!   one text at the same revision hold the same text.
//! - **A text is made from a snapshot** ([`Text::from_snapshot`]): a new
//!   text holding what the snapshot holds, at revision 0, with an empty
//!   log, no markers and no kept inverses. It copies none of the text. That
//!   is how what another thread loaded becomes a text, and how a text is
//!   copied.
//! - **Nothing panics on a caller's value.** Every read that takes an
//!   offset, a row, a point or a range returns an `Option`, and an edit a
//!   `Result`.
//! - **A text has one writer.** [`Text::apply`] takes `&mut self`, and the
//!   text holds no lock: a caller that shares a text between threads puts it
//!   behind one.
//!
//! # Excerpt texts
//!
//! An excerpt text is a text made of ranges of other texts, its sources, by
//! the module [`excerpt`], whose docs have the rules in full:
//!
//! - **It is a list and a plain text.** The list ([`excerpt::Excerpts`])
//!   holds each excerpt as a source and two anchors the source marks, its
//!   start with [`Bias::Before`] and its end with [`Bias::After`], so text
//!   inserted at either end is inside it. The assembled text, a [`Text`]
//!   only the list writes, holds the excerpts' bytes joined by one line
//!   feed. Its snapshots, revisions, log and markers are a plain text's, so
//!   every read of a snapshot, motions included, answers over it unchanged,
//!   and a motion crosses from one excerpt into the next.
//! - **It is caught up at every request** ([`excerpt::Excerpts::refresh`]):
//!   each source's patch since the revision last read, cut to each of its
//!   excerpts, is applied as one transaction, so however many sources moved
//!   the assembled text gets one revision. An excerpt the cut does not line
//!   up for, or whose source's log no longer reaches that revision, is
//!   replaced whole.
//! - **Replacing the list** ([`excerpt::Excerpts::set`]) is one more
//!   transaction, which keeps the excerpts the two lists start and end with
//!   alike, anchors and bytes, and gives up the anchors of those dropped.
//! - The assembled text keeps no inverse, and the list refuses to go on
//!   over one written by anything else.
//! - **An edit of it is its sources' edits**
//!   ([`excerpt::Excerpts::edit`]): each range it changes, inside one
//!   excerpt, both ends included, is mapped to its source, every source it
//!   changes is given one transaction with the caller's origin, and the
//!   excerpt text catches up from them once. Every check comes first, so a
//!   refused edit changes no source; an edit of a separator byte, or one
//!   whose range in its source meets another excerpt of that source, is
//!   refused.
//!
//! # Files
//!
//! A text is loaded from a file and a snapshot saved as one through the
//! file port ([`fs::Fs`]), by the module [`mod@file`], whose docs have the
//! rules in full:
//!
//! - **A load** ([`file::load`]) reads the file once, up to a limit the
//!   caller gives, refuses a binary file (a NUL byte among its first 8,000
//!   bytes), counts its line endings and changes none, and returns the text
//!   with a stamp: the file's modification time and size.
//! - **A save** ([`file::save`]) writes a temporary file beside the file
//!   and renames it over the file, so a crash never leaves a half-written
//!   file, and keeps the file's permissions. It is told what to expect on
//!   disk, and a file that is not as expected is not overwritten: the
//!   refusal says what is there now.
//! - **A listing** ([`file::list`]) answers what a directory holds, each
//!   entry with its kind, links followed, sorted by the bytes of the
//!   names.
//! - **A directory made** ([`file::make_directory`]) is made with every
//!   directory on the way to it; one already there is no error.
//! - All four are tested on the port's published fake ([`fs::FakeFs`]) and
//!   make no real file; the real adapter is another crate, held to the
//!   port's contract by its own tests.
//!
//! # The rope
//!
//! The text is held in a rope, a tree of small pieces, from the `ropey`
//! library. The private module `rope` is the only one that names it, and no
//! type of it is public here.
//!
//! The pieces are what [`Snapshot::chunks`], [`Snapshot::chunks_in`] and
//! [`Snapshot::chunk_at`] hand out, for a reader that wants the text
//! without a copy: search, shaping, a parser. A piece ends on a character
//! boundary; where is the rope's business.
//!
//! A part of the text is copied out without reading the rest of it: the
//! text between two positions ([`Snapshot::slice_to_string`]), and the
//! content of one row, which is the row without its line break
//! ([`Snapshot::row_to_string`]). Each reads the pieces of its range and
//! no others.
//!
//! # Not here yet
//!
//! - A second row rule, in which a carriage return alone ends a line, which
//!   is how a language server counts. The library can count it beside this
//!   one without the stored text changing.
//! - Composing transactions, as something a caller can ask for: the
//!   inverses of a run are composed inside the crate.
//! - A bound on how many markers a text holds, and a marker that a
//!   transaction sets to its selection after.
//! - Extended grapheme clusters as the cell: a letter and a combining mark
//!   after it are two cells here.
//! - A block's columns counted by display width (tab stops, wide
//!   characters), and a block that runs to the end of every row.
//! - Rebasing a transaction built for an older revision: the log keeps no
//!   text, so it cannot supply the change sets to rebase through.
//! - Points in UTF-16 in an edit. A client that speaks them converts with
//!   the snapshots of the two revisions.
//! - A policy for forgetting, and anywhere cheaper to keep provenance
//!   older than the horizon.
//! - The undo tree, groups of revisions, and whether a text is modified:
//!   they are in Lean, over [`Text::apply_inverse`] and
//!   [`Text::drop_inverses`], as any other undo style would be.
//! - A bound on the kept inverses that the crate keeps by itself, and a
//!   text that keeps none.
//! - A trace that names text an inverse put back as written by whoever
//!   first wrote it: it is the inverse's.
//! - Handing back a selection that a later transaction of a run carried,
//!   when the run's first carried none.
//! - What a save that renames does not keep: the other names of a file
//!   with hard links, a foreign owner, the special mode bits, extended
//!   attributes. Writing in place where a rename would lose one gives up
//!   the crash guarantee, and is not built.
//! - A load that streams into the rope without holding the file's bytes
//!   whole, and an override of the binary rule.
//! - A trace through an excerpt text to the edits of its sources; an
//!   excerpt text as another's source; and a tree of running totals over
//!   the list, which waits for a measured need.
//! - Noticing that a file changed on disk at any time but a save, and a
//!   change inside the file system's clock granularity that keeps the size.
//!
//! # Where an addition goes
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | Another read of the text | A method of [`Snapshot`] | The unit tests beside it, and a property in `tests/properties/` that compares it with the same read of a `String` |
//! | Another way to change the text | A way to build a [`Transaction`], applied by [`Text::apply`]: the text has one writer path | The unit tests beside it, and the revision rule above |
//! | Another kind of change | A variant of [`Change`], with its push on [`ChangeSet`] that keeps the normal form, and its case in apply, compose, invert, map and the log's edits | The unit tests of `change`, and the laws in `tests/properties/changes.rs`, whose generator gains the kind |
//! | Another read of the log | A method of [`Text`] over the private `log::Log` | Its unit tests on literal edits, and a property in `tests/properties/log.rs` that compares it with a reference computed from the strings |
//! | A rule about what bytes a text loads from or saves as | The private module `bytes` | Its unit tests on named byte strings, and the byte properties in `tests/properties/` |
//! | A rule about how a file is loaded or saved: what is refused, what is checked, what is kept | The module [`mod@file`], over the port | Its unit tests on [`fs::FakeFs`], and the properties in `tests/properties/files.rs`; never a test in an adapter's crate |
//! | A bound on what an operation costs, the log's growth and what a kept inverse holds included | `tests/snapshot_cost.rs`, as a count of bytes allocated | Itself |
//! | Another fact kept with a transaction's inverse | A field of the private `inverse::Kept`, set where [`Text::apply`] and [`Text::apply_inverse`] keep one | The unit tests of `inverse`, and a property in `tests/properties/inverses.rs`, whose history beside the text gains the fact |
//! | Another bound on the kept inverses | A method of [`Text`] over the private `inverse::Inverses`, beside [`Text::drop_inverses`] | The unit tests of `inverse`, and the driver of `tests/properties/inverses.rs`, which gains the step |
//! | Something more of the rope library | A method of the private `rope::Rope`, in this crate's terms | The tests of the read that needs it |
//! | Another shape of selection | A variant of [`Shape`], with its overlap rule and its biases in `selection`, and what it covers in `extent` | The unit tests of both, and the properties in `tests/properties/selections.rs`, whose generator and reference gain the shape |
//! | Another kind of marker | A variant of [`Marker`], with its check in [`Text::mark`] and its ends in the private `marker::Markers` | The unit tests of `text`, and a property in `tests/properties/anchors.rs` that compares it with mapping it by hand |
//! | A change to what a cell is | The private module `cell`, and nowhere else: every reader steps by its `cell_end` and `cell_start_before` and asks its `cell_kind` what a cell is, and none reads the text's characters for itself. If a cell comes to be more than one character, `cell::Kind` changes, and the compiler names its readers, the word motions | Its unit tests, and `extents_agree_with_a_reference_on_a_string`, `cell_points_round_trip_at_every_position_and_count_the_characters_before_it_in_its_row` and the reference of `tests/properties/motions.rs`, which change with it. `a_column_in_cells_is_that_many_steps_of_the_next_cell_from_its_rows_start` there states no rule: it holds both conversions of a column in cells to the module's step |
//! | A change to what a word character or a blank is | The private module `word`, and nowhere else | Its unit tests on named characters, and the reference of `tests/properties/motions.rs`, which states the rule again and changes with it |
//! | Another motion | A variant of [`Motion`], with its arm in [`Snapshot::motion`] | Its unit tests beside it, on the fixture's table, and the reference of `tests/properties/motions.rs`, which gains the motion |
//! | Another kind of bracket or quote, or another read of a pair | A variant of [`Bracket`] or [`Quote`], or a method of [`Snapshot`] in the private module `pair` | The unit tests of `pair`, one for each rule |
//! | Another rule about how an excerpt follows its sources, about a list that replaces another, or about how an edit of an excerpt text reaches its sources | The module [`excerpt`] | Its unit tests on two named sources, and the properties in `tests/properties/excerpts.rs`, whose reference keeps each excerpt's ends as anchors mapped by hand and maps each run of an edit through the excerpt it is in |
//! | Another thing the crate needs of a file system | A method of [`fs::Fs`], as the module docs of [`fs`] say | Its rule in [`fs::contract::check`], with a fake written to break it, which the fake and every real adapter are then held to |

mod anchor;
mod bytes;
mod cell;
mod change;
pub mod excerpt;
mod extent;
pub mod file;
pub mod fs;
mod inverse;
mod log;
mod marker;
mod motion;
mod pair;
mod patch;
mod point;
mod rope;
mod selection;
mod snapshot;
mod text;
mod transaction;
mod word;

pub use anchor::Anchor;
pub use bytes::ByteChunks;
pub use change::{Bias, Change, ChangeSet, Mapper};
pub use inverse::{InverseError, Inverted};
pub use log::{Attribution, LogEntry, LogError, Origin, Source, Subscription};
pub use marker::{MarkError, Marker, MarkerId};
pub use motion::Motion;
pub use pair::{Bracket, Quote};
pub use patch::{Edit, InputEdit, Patch, Span};
pub use point::{Point, PointCells, PointUtf16};
pub use selection::{Selection, SelectionRange, Shape};
pub use snapshot::{Chunks, Revision, Snapshot};
pub use text::{BadRange, Text};
pub use transaction::{ApplyError, Transaction};
pub use word::{WordKind, is_word_character};
