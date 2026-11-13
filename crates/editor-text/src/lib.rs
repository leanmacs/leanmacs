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
//! - **An edit** replaces the bytes between two positions with a string
//!   ([`Text::replace`]). It is refused, changing nothing, unless both ends
//!   are positions and are in order.
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
//! - **A transaction** ([`Transaction`]) is a change set and, optionally,
//!   the selection before it and the selection after it. Applying one
//!   ([`Text::apply`]) is the one way a text changes, and it is all or
//!   nothing: a transaction is refused, changing nothing, unless its change
//!   set fits the text and every end of each selection is a position of
//!   its own text, the one before or the one after. [`Text::replace`] is
//!   the transaction with one change and no selection.
//! - **A selection**, so far, is plain data ([`Selection`]): one or more
//!   ranges of two offsets, one of them the primary, kept exactly as given.
//!   Nothing sorts, merges or moves them yet.
//! - **An origin** ([`Origin`]) says who made an edit. It is an opaque
//!   number given when a transaction is applied, not part of the
//!   transaction. The crate keeps it in the transaction's log entry
//!   ([`Text::entry`]) and never reads its value; what a number stands for
//!   is the caller's table. [`Text::replace`] records the default, 0.
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
//! - Composing and inverting change sets, mapping a position through one,
//!   and what the log records of a transaction beyond its origin.
//! - Anchors, the selection type and undo.
//! - Reading and writing a file, detecting a file's line ending, and
//!   refusing a binary file: this crate takes bytes and gives bytes.
//!
//! # Where an addition goes
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | Another read of the text | A method of [`Snapshot`] | The unit tests beside it, and a property in `tests/properties/` that compares it with the same read of a `String` |
//! | Another way to change the text | A method of [`Text`] that takes `&mut self` | The same, and the revision rule above |
//! | A rule about what bytes a text loads from or saves as | The private module `bytes` | Its unit tests on named byte strings, and the byte properties in `tests/properties/` |
//! | A bound on what an operation costs | `tests/snapshot_cost.rs`, as a count of bytes allocated | Itself |
//! | Something more of the rope library | A method of the private `rope::Rope`, in this crate's terms | The tests of the read that needs it |

mod bytes;
mod change;
mod log;
mod point;
mod rope;
mod selection;
mod snapshot;
mod text;
mod transaction;

pub use bytes::ByteChunks;
pub use change::{Change, ChangeSet};
pub use log::{LogEntry, Origin};
pub use point::{Point, PointUtf16};
pub use selection::{Selection, SelectionRange};
pub use snapshot::{Chunks, Revision, Snapshot};
pub use text::{BadRange, Text};
pub use transaction::{ApplyError, Transaction};
