//! Syntax trees: a text parsed with a grammar, kept up to date with its
//! edits off the editor thread, and queried by range.
//!
//! - **The port** ([`Syntax`], in `port`) is what a parsing library fills:
//!   a parser for a grammar, a parse of a snapshot, an edit told to a tree,
//!   a query compiled, a query's captures, and a tree read as plain
//!   [`Node`]s. Everything it answers is in its own terms; the tree, the
//!   parser and the query are the implementation's types.
//! - **The rule for a range** ([`query::captures_in`]) is what a query
//!   answers of a range of the text: the captures whose node overlaps it,
//!   each once, by start, the longer first, then by pattern and capture.
//!   The port may answer more; the rule decides.
//! - **A session** ([`Session`]) is one text's parse state: it pulls the
//!   text and the edit log's patch through a [`Source`], reparses
//!   incrementally from its last tree (and parses whole instead when the
//!   incremental tree has an error, so every tree equals a fresh parse's),
//!   and delivers each result, tagged
//!   with the revision it parsed, to its [`Consumer`]s, unless a newer
//!   revision has been told by then: a stale result is never handed out.
//! - **The worker** ([`Worker`]) runs sessions' rounds on whichever thread
//!   runs its loop. The crate starts no thread.
//!
//! The crate depends on `editor-text` alone and knows nothing about Lean or
//! a parsing library. The real implementation of the port is another crate
//! (`editor-syntax-treesitter`), held to [`contract::check`] by its own
//! tests.
//!
//! # The fake and the contract
//!
//! [`fake::Parens`] is the port's fake, a toy grammar of parens and atoms,
//! and everything above the port is tested on it. [`contract::check`] is
//! what every implementation keeps, over a [`contract::Corpus`] of its
//! grammar: the fake passes it here, and each real adapter in its own
//! tests. Each property is seen to bite on an implementation written to
//! break it, in the contract's tests.
//!
//! # Where an addition goes
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | Something more asked of a parsing library | A method of [`Syntax`], answered in plain data | A property of [`contract`], with a broken implementation that it catches, and the fake |
//! | A rule of what a range answers, or of the order | [`query`] | Its unit tests, on a syntax that answers out of order; and the same rule in the Lean model (`lean/Editor/SyntaxTree/Model.lean`) |
//! | A rule of when a text is reparsed, or which result is handed out | [`session`] | Its unit tests, on the fake and a recording mock, single-threaded |
//! | A rule of what runs next | [`worker`] | Its unit tests, stepped by hand, and `tests/worker.rs` on a real thread |
//! | A grammar | The real adapter's table, with a corpus its contract test runs | That crate's `tests/contract.rs` |

pub mod contract;
pub mod fake;
mod port;
pub mod query;
pub mod session;
pub mod worker;

pub use port::{Capture, GrammarName, Node, QueryError, QueryErrorKind, Syntax};
pub use session::{Consumer, Latest, Outcome, Parsed, Session, Source};
pub use worker::{Handle, Worker};
