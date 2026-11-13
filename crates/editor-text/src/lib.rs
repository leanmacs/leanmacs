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
//! | Another read of the text | A method of [`Snapshot`] | The unit tests beside it |
//! | Something more of the rope library | A method of the private `rope::Rope`, in this crate's terms | The tests of the read that needs it |

mod rope;
mod snapshot;
mod text;

pub use snapshot::{Revision, Snapshot};
pub use text::{BadRange, Text};
