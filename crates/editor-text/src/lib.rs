//! Text storage: a text that can be edited, and what can be read of it.
//!
//! A [`Text`] holds the text of one buffer. Every read goes through a
//! [`Snapshot`], which is the text as it was at one moment. The crate is
//! pure: it does no I/O, reads no clock, starts no thread and knows nothing
//! about Lean. `editor-ffi` puts a text behind a handle for the Lean editor.
//!
//! # The text model
//!
//! - **A text is UTF-8**, always valid.
//! - **An offset** is a byte offset into that UTF-8. **A position** is an
//!   offset that is a character boundary within the text, its end included
//!   ([`Snapshot::is_char_boundary`]). Offsets are the unit the Lean editor
//!   speaks.
//! - **An edit** replaces the bytes between two positions with a string
//!   ([`Text::replace`]). It is refused, changing nothing, unless both ends
//!   are positions and are in order.
//! - **A revision** counts the edits a text has accepted ([`Revision`]). A
//!   new text is at 0, every accepted edit adds one, one that changes
//!   nothing included, and a refused edit adds none.
//! - **A snapshot** is the text at one revision ([`Text::snapshot`]). It
//!   never changes, whatever is done to the text afterwards, and it outlives
//!   the text. Taking one copies none of the text, and so does cloning one.
//!   It is `Send + Sync`: a snapshot is what a worker thread, a job or the
//!   renderer reads, and none of them sees the text itself. Two snapshots of
//!   one text at the same revision hold the same text.
//! - **A text has one writer.** [`Text::replace`] takes `&mut self`, and the
//!   text holds no lock: a caller that shares a text between threads puts it
//!   behind one.
//!
//! # The rope
//!
//! The text is held in a rope, a tree of small pieces, from the `ropey`
//! library. The private module `rope` is the only one that names it, and no
//! type of it is public here.
//!
//! # Where an addition goes
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | Another read of the text | A method of [`Snapshot`] | The unit tests beside it, and a property in `tests/properties.rs` that compares it with the same read of a `String` |
//! | Another way to change the text | A method of [`Text`] that takes `&mut self` | The same, and the revision rule above |
//! | A bound on what an operation costs | `tests/snapshot_cost.rs`, as a count of bytes allocated | Itself |
//! | Something more of the rope library | A method of the private `rope::Rope`, in this crate's terms | The tests of the read that needs it |

mod rope;
mod snapshot;
mod text;

pub use snapshot::{Revision, Snapshot};
pub use text::{BadRange, Text};
