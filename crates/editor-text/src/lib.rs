//! Text storage: a text that can be edited, and what can be read of it.
//!
//! A [`Text`] holds the text of one buffer. Every read goes through a
//! [`Snapshot`], which is the text as it was at one moment. The crate is
//! pure: it does no I/O, reads no clock, starts no thread and knows nothing
//! about Lean. `editor-ffi` puts a text behind a handle for the Lean editor.
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
//!   bytes ([`Point`]) or in UTF-16 code units ([`PointUtf16`]). They are
//!   two types so the units cannot be mixed.
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
//!   the transaction with one change and no selection.
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
//!   included, and a refused one adds none.
//! - **A snapshot** is the text at one revision ([`Text::snapshot`]). It
//!   never changes, whatever is done to the text afterwards, and it outlives
//!   the text. Taking one copies none of the text, and so does cloning one.
//!   It is `Send + Sync`: a snapshot is what a worker thread, a job or the
//!   renderer reads, and none of them sees the text itself. Two snapshots of
//!   one text at the same revision hold the same text.
//! - **Nothing panics on a caller's value.** Every read that takes an
//!   offset, a row, a point or a range returns an `Option`, and an edit a
//!   `Result`.
//! - **A text has one writer.** [`Text::apply`] takes `&mut self`, and the
//!   text holds no lock: a caller that shares a text between threads puts it
//!   behind one.
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
//! # Not here yet
//!
//! - A second row rule, in which a carriage return alone ends a line, which
//!   is how a language server counts. The library can count it beside this
//!   one without the stored text changing.
//! - Composing transactions.
//! - What a selection covers, and undo.
//! - A bound on how many markers a text holds, and a marker that a
//!   transaction sets to its selection after.
//! - Rebasing a transaction built for an older revision: the log keeps no
//!   text, so it cannot supply the change sets to rebase through.
//! - Points in UTF-16 in an edit. A client that speaks them converts with
//!   the snapshots of the two revisions.
//! - A policy for forgetting, and anywhere cheaper to keep provenance
//!   older than the horizon.
//! - Reading and writing a file, detecting a file's line ending, and
//!   refusing a binary file: this crate takes bytes and gives bytes.
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
//! | A bound on what an operation costs, the log's growth included | `tests/snapshot_cost.rs`, as a count of bytes allocated | Itself |
//! | Something more of the rope library | A method of the private `rope::Rope`, in this crate's terms | The tests of the read that needs it |

mod anchor;
mod bytes;
mod change;
mod log;
mod marker;
mod patch;
mod point;
mod rope;
mod selection;
mod snapshot;
mod text;
mod transaction;

pub use anchor::Anchor;
pub use bytes::ByteChunks;
pub use change::{Bias, Change, ChangeSet, Mapper};
pub use log::{Attribution, LogEntry, LogError, Origin, Source, Subscription};
pub use marker::{MarkError, Marker, MarkerId};
pub use patch::{Edit, InputEdit, Patch, Span};
pub use point::{Point, PointUtf16};
pub use selection::{Selection, SelectionRange, Shape};
pub use snapshot::{Chunks, Revision, Snapshot};
pub use text::{BadRange, Text};
pub use transaction::{ApplyError, Transaction};
