//! Syntax trees: a text parsed with a grammar, kept up to date with its
//! edits off the editor thread, and queried by range.
//!
//! - **The port** ([`Syntax`], in `port`) is what a parsing library fills:
//!   a parser for a grammar, a parse of a snapshot (or of some ranges of
//!   it), an edit told to a tree, a query compiled, a query's captures and
//!   matches, a pattern's settings, and a tree read as plain [`Node`]s. Everything it answers is in its own terms; the tree, the
//!   parser and the query are the implementation's types. It also
//!   registers a grammar at run time from a [`GrammarSource`] (a native
//!   library, a symbol, an optional policy), answering the name or a
//!   [`RegistrationRefusal`] ([`Syntax::register`]).
//! - **The registry** ([`registry::Registry`]) is the core's decisions
//!   about a registration: the name, the default policy (`Whole`), the
//!   override of an earlier or compiled-in grammar, provenance and the
//!   listing; an adapter holds one and supplies only the load step.
//! - **The rule for a range** ([`query::captures_in`]) is what a query
//!   answers of a range of the text: the captures whose node overlaps it,
//!   each once, by start, the longer first, then by pattern and capture.
//!   The port may answer more; the rule decides.
//! - **A session** ([`Session`]) is one text's parse state: it pulls the
//!   text and the edit log's patch through a [`Source`], reparses from its
//!   last tree as its grammar's [`ReparsePolicy`] says (incrementally,
//!   keeping the tree whatever it holds, or whole), and delivers each
//!   result, tagged with the revision it parsed, to its [`Consumer`]s,
//!   unless a newer revision has been told by then: a stale result is never
//!   handed out. Its refresh round ([`Session::refresh_once`]) parses a
//!   quiet text whole and delivers that only when it differs: incremental
//!   now, exactly a fresh parse once the text is quiet.
//! - **The worker** ([`Worker`]) runs sessions' rounds on whichever thread
//!   runs its loop, and each session's refresh once its text has gone an
//!   idle interval unchanged after an edit, measured on a [`clock::Clock`].
//!   The crate starts no thread.
//! - **Highlighting** ([`highlight`]) is a query's captures drawn in faces
//!   by the highlight rule ([`highlight::spans`]), from a [`Highlighter`]
//!   a session is given; a session answers what a snapshot is drawn with
//!   ([`Session::highlights`]): the tree delivered, carried through the
//!   edit log's patch to a newer snapshot until the reparse that replaces
//!   it is delivered, without waiting for a parse.
//! - **Injections** ([`inject`]) are text of one language held in a node of
//!   another's: the injection rule finds them from an injections query's
//!   matches, and a session parses each as a layer of its own, on the
//!   worker, and draws its spans over the host's.
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
//! Registration has a fake and a contract of its own. [`fake::Libraries`]
//! is the fake with a table: it "loads" grammars from an in-memory table of
//! libraries keyed by path ([`fake::libraries::table`]).
//! [`contract::registration::check`] holds a registering syntax to a
//! [`contract::registration::RegistrationCorpus`] (success; the override of
//! a name already listed, compiled in or registered before, which then
//! ships no query and takes the source's policy; the default policy; each
//! refusal): the fake with its table keeps it here, over its compiled-in
//! `parens`, and the real adapter, which loads native grammar libraries
//! and compiles in none, on its fixture library in its own tests, over a
//! `json` registered before.
//! [`contract::registration::check_unsupported`] holds a syntax that loads
//! no grammar, as the fake with no table, to refusing every source as
//! unsupported, changing nothing. A grammar that ships no query, as one
//! registered ships none, is held to [`contract::check`] with the
//! highlights query beside its library ([`contract::Corpus::highlights`]).
//!
//! # Where an addition goes
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | Something more asked of a parsing library | A method of [`Syntax`], answered in plain data | A property of [`contract`], with a broken implementation that it catches, and the fake |
//! | A rule of what a range answers, or of the order | [`query`] | Its unit tests, on a syntax that answers out of order; and the same rule in the Lean model (`lean/Editor/SyntaxTree/Model.lean`) |
//! | A rule of when a text is reparsed, which result is handed out, or when a question of captures or of a kept query is refused | [`session`] | Its unit tests, on the fake and a recording mock, single-threaded |
//! | A rule of how captures are drawn, or carried through edits | [`highlight`] | Its unit tests, on the fake and hand-built patches |
//! | A rule of which injections a query's matches say, or how layers nest | [`inject`] | Its unit tests, on a mock that answers canned matches and on the fake; the adapter's `tests/injections.rs` on the real grammars |
//! | A rule of which tree a snapshot is drawn from | [`session`] ("Highlights") | Its unit tests, single-threaded, and `tests/highlight.rs` on a real thread with a parse held |
//! | A rule of what runs next, or of when a refresh runs | [`worker`] | Its unit tests, stepped by hand on a [`clock::ManualClock`], and `tests/worker.rs` on a real thread |
//! | A rule of what a refresh does | [`session`] ("The refresh round") | Its unit tests, single-threaded, and the contract's [`contract::CONVERGES`] |
//! | A grammar | The real adapter's table, with a corpus its contract test runs | That crate's `tests/contract.rs` |
//! | A rule of registration: the name, the override, the default policy, provenance | [`registry`] | Its unit tests; mirrored in `lean/Editor/SyntaxTree/Registration/Model.lean` |
//! | Something more asked of registration | A property of [`contract::registration`], with a broken registering syntax it catches | Held against [`fake::Libraries`] in the contract's tests, and against the real adapter on its fixture library in its `tests/registration.rs` |
//! | When a registration is answered | [`worker`] ("Registrations") | Its unit tests, stepped by hand, and `tests/worker.rs` on a real thread |
//! | A grammar's reparse policy | The real adapter's table, and the `policy` of its corpus | The contract's [`contract::REPARSE_POLICY`] and [`contract::GRAMMAR_QUALITY`]; the real Rust grammar's convergence after the idle interval in the adapter's `tests/refresh.rs` |

pub mod clock;
pub mod contract;
pub mod fake;
pub mod highlight;
pub mod inject;
mod port;
pub mod query;
pub mod registry;
pub mod session;
pub mod worker;

pub use highlight::{BadFaces, HighlightSpan, Highlighter, Highlights};
pub use port::{
    Capture, GrammarName, GrammarSource, Match, MatchCapture, Node, QueryError, QueryErrorKind,
    QueryKind, RegistrationRefusal, ReparsePolicy, Setting, Syntax,
};
pub use session::{
    CapturesRefusal, Consumer, Kept, KeptRefusal, Latest, Outcome, Parsed, Session, Source,
};
pub use worker::{Handle, Worker};
