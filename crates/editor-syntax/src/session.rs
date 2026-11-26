//! One text's parse state, and the rule for which result is handed out.
//!
//! A [`Session`] parses one text with one grammar, off the editor thread.
//! It reaches the text through a [`Source`], which hands it the text as it
//! is now and the edit log's patch since the tree it last parsed, and it
//! hands each result it delivers to its [`Consumer`]s. Parsing never passes
//! through Lean: the bytes go from the snapshot's chunks to the parser.
//!
//! # A round ([`Session::parse_once`])
//!
//! 1. The source is asked for the text as it is now and what changed since
//!    the revision of the last tree parsed, the *base*. A text that is gone
//!    ends the session ([`Outcome::Gone`]). One still at the base's revision
//!    needs nothing ([`Outcome::UpToDate`]), unless the injections have
//!    changed since the base's layers were found (step 4).
//! 2. **The policy** ([`ReparsePolicy`], read once from the grammar when
//!    the session is made). With an [`ReparsePolicy::Incremental`] grammar,
//!    a base, and a patch that chains from it (`patch.from` is the base's
//!    revision and `patch.to` the snapshot's), a clone of the base tree is
//!    told each of the patch's edits, in order, and the text is reparsed
//!    with it. Otherwise (a [`ReparsePolicy::Whole`] grammar, the first
//!    parse, a log that has forgotten the base's revision, a patch that
//!    does not chain) the text is parsed whole, handed no old tree.
//! 3. **No fallback.** The incremental reparse's tree is kept whatever the
//!    text holds, errors or not, as other tree-sitter editors keep it. How
//!    a library recovers from an error can depend on what it reuses, so
//!    while a text has an error its tree may differ from a fresh parse's;
//!    on a text without errors the grammar is held equal to a fresh parse
//!    ([`crate::contract::GRAMMAR_QUALITY`]). Exactness is restored once the
//!    text is quiet, by the idle refresh.
//! 4. **Layers.** When the session has an injections query
//!    ([`Session::set_injections`]), the new tree's layers are found
//!    ([`crate::inject::layers`]) and parsed, each whole, on the worker, by
//!    parsers the work keeps, one for each grammar. The injections are read
//!    once, at the round's start, with their *generation*, which grows with
//!    each change ([`Session::set_injections`], [`Session::set_language`]).
//!    A text still at the base's revision whose base's layers were found
//!    with another generation is not parsed again: the base tree is kept,
//!    its layers are found again, and, when they are not the base's (by
//!    language, grammar, depth and ranges, which fix a layer's tree), the
//!    result is delivered at the same revision. So the injections a mode
//!    sets are drawn without a key pressed. Layers alike are what was
//!    delivered, and the round is [`Outcome::UpToDate`]: a language's new
//!    faces are read when highlights are asked, and need no delivery.
//! 5. The result is the new base, delivered or not.
//! 6. **The delivery rule.** The result is delivered only if its revision is
//!    at least the newest the session has been told of
//!    ([`Session::touch`]). Delivering sets that revision to the result's,
//!    keeps the result ([`Session::parsed`]) and hands it to each consumer.
//!    A result older than a revision the session has been told of is
//!    [`Outcome::Stale`]: nobody sees it, and it serves only as the base of
//!    the next parse. So a result is delivered at least at every revision
//!    told and every one delivered before: the revisions delivered never go
//!    back, and they repeat only for a round of step 4's that found new
//!    layers or a refresh whose whole parse differed (below), and a result
//!    tagged with a revision older than the current one is never handed
//!    out.
//!
//! # The refresh round ([`Session::refresh_once`])
//!
//! When to refresh is the worker's rule ([`crate::worker`], "Idle
//! refreshes"): once a text has gone the idle interval unchanged after an
//! edit. What a refresh does is this module's. It runs under the work lock,
//! as a round does.
//!
//! 1. The source is asked for the text as it is now. A text that is gone is
//!    [`Outcome::Gone`].
//! 2. **The text has moved past the base, or there is no base:** an
//!    ordinary round. The edit's touch has scheduled the refresh again.
//! 3. **The base is already a whole parse** (the first round's, a `whole`
//!    grammar's, a refresh's): nothing to parse. Step 4 of a round is still
//!    done when the injections changed; otherwise [`Outcome::UpToDate`].
//! 4. **Otherwise** the text is parsed whole, handed no old tree, and that
//!    tree becomes the base. When its nodes ([`Syntax::nodes`]) equal the
//!    base tree's, nothing is delivered and no consumer is called: the tree
//!    delivered is marked exact, and the refresh is
//!    [`Outcome::UpToDate`]. Otherwise its layers are found and it goes
//!    through the delivery rule at the same revision: delivered, or
//!    [`Outcome::Stale`] when a newer revision has been told by then. A
//!    stale refresh still leaves its whole tree as the base of the next
//!    incremental reparse.
//!
//! The base tree is compared, not the tree delivered: the base is the last
//! tree parsed, and in step 4 it is of the revision delivered, the tree
//! delivered unless a stale result came between; if one did, the revision
//! delivered is older and the refresh is in step 2. Equal host nodes give
//! equal injection matches, so layers are found again only when the host
//! tree differed.
//!
//! **Exact.** The session keeps the revision whose whole parse the tree
//! delivered equals: set by a delivery of a whole parse and by a refresh
//! that found no difference, and cleared by a delivery of an incremental
//! reparse. [`Session::wait_exact`] waits for it, for tests.
//!
//! # A question of captures ([`Session::captures`])
//!
//! A question of a query's captures in a range of a snapshot is answered
//! from the tree delivered, never parsed for, so it never waits. It is
//! refused, checked in this order, when the query is of another grammar
//! than the session's ([`CapturesRefusal::WrongGrammar`]), when the range
//! is not two positions of the snapshot's text in order
//! ([`CapturesRefusal::BadRange`]), and when the tree delivered last is not
//! of the snapshot's revision, older or newer
//! ([`CapturesRefusal::NotParsed`]): a caller asks again after the next
//! delivery. Otherwise it answers what [`crate::query::captures_in`]
//! answers of that tree. The order is what the Lean model of the syntax
//! interface reproduces.
//!
//! # Kept queries ([`Session::keep`], [`Session::kept_captures`])
//!
//! A session keeps one query of each structural kind it is given
//! ([`QueryKind::TextObjects`], [`QueryKind::Indents`]), a later one
//! replacing the one before, so a question of text objects or indentation
//! names a kind, not a query. A question of a kept query's captures is
//! answered as one of captures is, from the tree delivered, with the
//! query's capture names; it is refused, checked in this order, when
//! nothing of that kind is kept ([`KeptRefusal::NoQuery`]), when the range
//! is not two positions of the snapshot's text in order
//! ([`KeptRefusal::BadRange`]), and when the tree delivered last is not of
//! the snapshot's revision ([`KeptRefusal::NotParsed`]).
//!
//! **Refused, not carried.** Highlights are carried through the edits since
//! the tree delivered, since a frame must draw something; an indent level
//! or a text object of a tree that lacks the latest edit would be wrong,
//! not stale (an indent asked right after the line break that makes it
//! matter). So a structural question before its reparse is delivered is
//! refused, and the caller keeps the row's indent or finds no object. The
//! reparse is milliseconds, and keys come further apart than that.
//!
//! # Highlights ([`Session::highlights`])
//!
//! A session may be given a [`Highlighter`] ([`Session::set_highlighter`]),
//! and then says what a snapshot of its text is drawn with, from the tree
//! delivered last, of revision M, for a snapshot of revision N. It is
//! asked once a frame, and what it answers is fixed for that frame:
//!
//! - with no highlighter, or nothing delivered yet, nothing: the text is
//!   drawn plain until the first parse arrives;
//! - when M is N, the tree delivered answers;
//! - when M is older, the tree delivered still answers, carried: the
//!   source is asked for the patch from M ([`Source::latest`]), and the
//!   spans are carried through it ([`crate::highlight`], "Carrying through
//!   a patch"). When the text has moved on past N, or the log has
//!   forgotten M, nothing, for that frame: the next one draws again;
//! - when M is newer (a scene of an old snapshot), nothing.
//!
//! The tree delivered carries its layers, and they are drawn over the
//! host's spans by the injections the session has when it is asked
//! ([`crate::highlight`], "Layers").
//!
//! So the old highlights stay, carried through the edits since, until the
//! reparse that replaces them is delivered, and an edit never waits for a
//! parse: a question of highlights takes the state lock, lets it go, and
//! then the source's, and never the work lock.
//!
//! # Locks
//!
//! A session has two: the *work* lock, over the parsers and the base, which
//! only the round takes, so only the worker; and the *state* lock, over the
//! newest revision told, the result delivered, the consumers, the
//! highlighter and the injections, which the round takes briefly at its
//! start, to read the injections and their generation, and then only to
//! deliver, and which [`Session::touch`] takes to tell. A refresh takes the
//! same locks as a round, and the state lock also to mark the tree
//! delivered exact when it delivers nothing. A parse holds the
//! work lock and no other: it takes the document's lock only inside
//! [`Source::latest`], and never the state lock while it parses, so an
//! edit's touch, and a change of injections, never wait for a parse.
//! Nothing takes the state lock and then the work lock, so the round's
//! taking the state lock under the work lock makes no cycle. A consumer is
//! called under the state lock and must not call back into the session.

use std::collections::BTreeMap;
use std::ops::Range;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};

use editor_wait::HangGuard;

use editor_text::{Patch, Revision, Snapshot};

use crate::highlight::{Highlighter, Highlights};
use crate::inject::{Injections, Language, Layer, layers};
use crate::port::{Capture, GrammarName, QueryKind, ReparsePolicy, Syntax};
use crate::query::{captures_in, positions};

/// How the session reaches its text: the text as it is now and, when the
/// log can still say, what changed since a revision.
pub trait Source: Send + Sync {
    /// The text as it is now and, when `since` is given and the log can
    /// still say, the patch from `since` to it. `None` when the text is
    /// gone.
    ///
    /// The snapshot and the patch are taken together, so the patch reaches
    /// exactly the snapshot's revision.
    fn latest(&self, since: Option<Revision>) -> Option<Latest>;
}

/// What a [`Source`] answers.
#[derive(Clone)]
pub struct Latest {
    /// The text as it is now.
    pub snapshot: Snapshot,
    /// What changed from the revision asked about to the snapshot's, when
    /// one was asked about and the log can still say.
    pub patch: Option<Patch>,
}

/// A parse result, tagged with the revision it parsed.
pub struct Parsed<T> {
    /// The revision of the text the tree is of.
    pub revision: Revision,
    /// The text the tree is of.
    pub snapshot: Snapshot,
    /// The tree.
    pub tree: T,
    /// The tree's layers, in order of depth and then of start
    /// ([`crate::inject::layers`]).
    pub layers: Vec<Layer<T>>,
}

impl<T> Parsed<T> {
    /// The result of `tree`, the tree of `snapshot` at `revision`, with no
    /// layers.
    pub fn new(revision: Revision, snapshot: Snapshot, tree: T) -> Self {
        Self {
            revision,
            snapshot,
            tree,
            layers: Vec::new(),
        }
    }
}

/// What is handed each result a session delivers.
pub trait Consumer<T>: Send + Sync {
    /// `parsed` is delivered: its revision is at least every revision the
    /// session has been told of and every one delivered before. It is the
    /// same as the last one delivered only when the injections changed and
    /// the text did not (the module docs, step 4), or when an idle
    /// refresh's whole parse differed from the tree delivered (the module
    /// docs, "The refresh round"). Called under the session's state lock: it
    /// must not call back into the session.
    fn deliver(&self, parsed: &Parsed<T>);
}

/// How a round ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// A tree of this revision was parsed and delivered.
    Delivered(Revision),
    /// A tree of this revision was parsed and not delivered: the session
    /// had been told of a newer revision by then.
    Stale(Revision),
    /// The text is still at the revision of the last tree parsed, and
    /// nothing was delivered: for a refresh, the whole parse equalled that
    /// tree, or it was a whole parse already.
    UpToDate,
    /// The text is gone: the session has nothing more to do.
    Gone,
}

/// Why a question of captures was refused ([`Session::captures`]), in the
/// order the refusals are checked.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CapturesRefusal {
    /// The query is of another grammar than the session parses with.
    WrongGrammar,
    /// The range is not two positions of the snapshot's text in order.
    BadRange,
    /// No tree of the snapshot's revision is the one delivered last.
    NotParsed,
}

/// Why a question of a kept query's captures was refused
/// ([`Session::kept_captures`]), in the order the refusals are checked.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeptRefusal {
    /// The session keeps no query of that kind.
    NoQuery,
    /// The range is not two positions of the snapshot's text in order.
    BadRange,
    /// No tree of the snapshot's revision is the one delivered last.
    NotParsed,
}

/// The capture names of a kept query and its captures in a range
/// ([`Session::kept_captures`]).
pub type Kept = (Vec<String>, Vec<Capture>);

/// One text's parse state.
pub struct Session<S: Syntax> {
    /// The grammar it parses with.
    grammar: GrammarName,
    /// How the grammar's texts are reparsed, read once.
    policy: ReparsePolicy,
    /// Where the text is read.
    source: Box<dyn Source>,
    /// The parser and the base, which only a round takes.
    work: Mutex<Work<S>>,
    /// What the round delivers into and a touch tells.
    state: Mutex<State<S>>,
    /// Woken at each delivery.
    delivered: Condvar,
    /// Whether the session is in a worker's queue
    /// ([`crate::worker::Worker`]): a session is queued at most once.
    pub(crate) queued: AtomicBool,
    /// The session's own number, given out once in the process: what the
    /// worker's schedule of refreshes knows it by. Not its address, which a
    /// later session can be given after this one is dropped.
    pub(crate) id: u64,
}

/// The next session's id.
static NEXT_ID: AtomicU64 = AtomicU64::new(0);

/// What only a round takes.
struct Work<S: Syntax> {
    /// The parser.
    parser: S::Parser,
    /// A parser for each grammar a layer has been parsed with.
    parsers: BTreeMap<GrammarName, S::Parser>,
    /// The last tree parsed, delivered or not.
    base: Option<Base<S::Tree>>,
}

/// The last tree a round parsed.
struct Base<T> {
    /// The revision it is of.
    revision: Revision,
    /// The tree.
    tree: T,
    /// Whether the tree is a whole parse of its revision, handed no old
    /// tree: what a refresh need not parse again.
    whole: bool,
    /// The generation of the injections its layers were found with.
    generation: u64,
    /// Its layers, each as its language, grammar, depth and ranges: what
    /// tells whether layers found again are new.
    layers: Vec<LayerKey>,
}

/// A layer as what tells it from another of the same text: its language,
/// grammar, depth and ranges. Two layers alike in these have equal trees,
/// each parsed whole in its ranges.
type LayerKey = (String, GrammarName, u32, Vec<Range<usize>>);

/// The keys of `layers`, in order.
fn keys<T>(layers: &[Layer<T>]) -> Vec<LayerKey> {
    layers
        .iter()
        .map(|layer| {
            (
                layer.language.clone(),
                layer.grammar.clone(),
                layer.depth,
                layer.ranges.clone(),
            )
        })
        .collect()
}

/// What a round delivers into and a touch tells.
struct State<S: Syntax> {
    /// The newest revision the session has been told of or delivered.
    current: Revision,
    /// The newest revision the session has been told of.
    told: Revision,
    /// The last result delivered.
    delivered: Option<Arc<Parsed<S::Tree>>>,
    /// Who is handed each result.
    consumers: Vec<Box<dyn Consumer<S::Tree>>>,
    /// What the text is drawn with, once one is set.
    highlighter: Option<Arc<Highlighter<S::Query>>>,
    /// The injections layers are found and drawn with.
    injections: Arc<Injections<S::Query>>,
    /// How many times the injections have changed.
    generation: u64,
    /// The generation of the injections the result delivered last found
    /// its layers with.
    delivered_generation: u64,
    /// The revision whose whole parse the tree delivered equals: set by a
    /// delivery of a whole parse and by a refresh that found no difference,
    /// and cleared by a delivery of an incremental reparse.
    exact: Option<Revision>,
    /// The query kept of each kind.
    kept: BTreeMap<QueryKind, Arc<S::Query>>,
}

/// `mutex`, locked. A round and a touch leave what they guard whole at
/// every point a panic could leave it, so a poisoned lock is used as it is.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

impl<S: Syntax> Session<S> {
    /// A session that parses the text `source` reads with `grammar`, which
    /// has been told of revision 0; `None` when `syntax` has no such
    /// grammar, opening no parser or declaring no reparse policy.
    pub fn new(syntax: &S, grammar: GrammarName, source: Box<dyn Source>) -> Option<Self> {
        let parser = syntax.parser(&grammar)?;
        let policy = syntax.reparse_policy(&grammar)?;
        Some(Self {
            grammar,
            policy,
            source,
            work: Mutex::new(Work {
                parser,
                parsers: BTreeMap::new(),
                base: None,
            }),
            state: Mutex::new(State {
                current: Revision::default(),
                told: Revision::default(),
                delivered: None,
                consumers: Vec::new(),
                highlighter: None,
                injections: Arc::new(Injections::default()),
                generation: 0,
                delivered_generation: 0,
                exact: None,
                kept: BTreeMap::new(),
            }),
            delivered: Condvar::new(),
            queued: AtomicBool::new(false),
            id: NEXT_ID.fetch_add(1, Ordering::Relaxed),
        })
    }

    /// The grammar it parses with.
    pub fn grammar(&self) -> &GrammarName {
        &self.grammar
    }

    /// How its grammar's texts are reparsed, as the grammar declared it
    /// when the session was made.
    pub fn policy(&self) -> ReparsePolicy {
        self.policy
    }

    /// Hands `consumer` every result delivered from now on.
    pub fn subscribe(&self, consumer: Box<dyn Consumer<S::Tree>>) {
        lock(&self.state).consumers.push(consumer);
    }

    /// Tells the session the text has reached `revision`, and says whether
    /// it is newer than every revision it has been told of: an edit, which
    /// the worker schedules an idle refresh for, and not an attach or a
    /// change of injections at a revision told already. A revision older
    /// than one it has been told of changes nothing. Queueing it for a
    /// parse is the worker's ([`crate::worker::Handle::touch`]).
    ///
    /// A delivery does not count as told: the worker may parse an edit
    /// before the edit's touch arrives, and that touch is still an edit.
    pub fn touch(&self, revision: Revision) -> bool {
        let mut state = lock(&self.state);
        state.current = state.current.max(revision);
        let newer = revision > state.told;
        state.told = state.told.max(revision);
        newer
    }

    /// The newest revision the session has been told of or delivered.
    pub fn current(&self) -> Revision {
        lock(&self.state).current
    }

    /// The last result delivered, if any.
    pub fn parsed(&self) -> Option<Arc<Parsed<S::Tree>>> {
        lock(&self.state).delivered.clone()
    }

    /// The last result delivered once its revision is at least `revision`
    /// and its layers were found with the injections as they are now,
    /// waiting for a delivery up to `guard`, which names it; `None` when
    /// none has come by then. For tests, and for nothing on the editor
    /// thread.
    pub fn wait_for(&self, revision: Revision, guard: HangGuard) -> Option<Arc<Parsed<S::Tree>>> {
        let state = lock(&self.state);
        let reached = |state: &mut State<S>| {
            state.delivered_generation == state.generation
                && state
                    .delivered
                    .as_ref()
                    .is_some_and(|parsed| parsed.revision >= revision)
        };
        let (state, reached) =
            editor_wait::wait_while(&self.delivered, state, guard, |state| !reached(state));
        if reached {
            state.delivered.clone()
        } else {
            None
        }
    }

    /// The last result delivered once it is exact for a revision of at
    /// least `revision`: its tree equals a whole parse of its own revision
    /// (a whole parse delivered, or an incremental one a refresh found
    /// equal), and its layers were found with the injections as they are
    /// now. Waits for that up to `guard`, which names it; `None` when it has
    /// not come by then. For tests, and for nothing on the editor thread.
    pub fn wait_exact(&self, revision: Revision, guard: HangGuard) -> Option<Arc<Parsed<S::Tree>>> {
        let state = lock(&self.state);
        let reached = |state: &mut State<S>| {
            state.delivered_generation == state.generation
                && state.exact.is_some_and(|exact| {
                    exact >= revision
                        && state
                            .delivered
                            .as_ref()
                            .is_some_and(|parsed| parsed.revision == exact)
                })
        };
        let (state, reached) =
            editor_wait::wait_while(&self.delivered, state, guard, |state| !reached(state));
        if reached {
            state.delivered.clone()
        } else {
            None
        }
    }

    /// Draws the text with `highlighter` from now on, in place of any
    /// before, and says whether there was one before.
    pub fn set_highlighter(&self, highlighter: Highlighter<S::Query>) -> bool {
        lock(&self.state)
            .highlighter
            .replace(Arc::new(highlighter))
            .is_some()
    }

    /// Finds the text's layers with `query`, or none with none, from the
    /// next round on (the module docs, step 4). The caller queues the
    /// session for that round.
    pub fn set_injections(&self, query: Option<Arc<S::Query>>) {
        self.change_injections(|injections| injections.query = query);
    }

    /// Parses and draws an injection of the language `name` as `language`
    /// says from the next round on, in place of any language of that name
    /// before. The caller queues the session for that round.
    pub fn set_language(&self, name: String, language: Language<S::Query>) {
        self.change_injections(|injections| {
            injections.languages.insert(name, language);
        });
    }

    /// Changes the injections with `change`, and their generation.
    fn change_injections(&self, change: impl FnOnce(&mut Injections<S::Query>)) {
        let mut state = lock(&self.state);
        let mut injections = (*state.injections).clone();
        change(&mut injections);
        state.injections = Arc::new(injections);
        state.generation += 1;
    }

    /// What `snapshot` is drawn with, as the module docs say
    /// ("Highlights"): none with no highlighter or nothing delivered, the
    /// tree delivered when it is of the snapshot's revision, the tree
    /// delivered carried through the log's patch when it is older, and
    /// none when the patch cannot be had of exactly the snapshot's
    /// revision, or the tree is newer.
    ///
    /// It takes the state lock and lets it go, and then the source's,
    /// never the work lock: it never waits for a parse.
    pub fn highlights(&self, snapshot: &Snapshot) -> Option<Highlights<S>> {
        let (parsed, highlighter, injections) = {
            let state = lock(&self.state);
            (
                state.delivered.clone()?,
                state.highlighter.clone()?,
                state.injections.clone(),
            )
        };
        let revision = snapshot.revision();
        if parsed.revision == revision {
            return Some(Highlights::new(
                parsed,
                highlighter,
                injections,
                snapshot.clone(),
                None,
            ));
        }
        if parsed.revision > revision {
            return None;
        }
        let latest = self.source.latest(Some(parsed.revision))?;
        let patch = latest
            .patch
            .filter(|patch| patch.from == parsed.revision && patch.to == revision)?;
        (latest.snapshot.revision() == revision).then(|| {
            Highlights::new(
                parsed,
                highlighter,
                injections,
                latest.snapshot,
                Some(patch),
            )
        })
    }

    /// The captures of `query`, compiled for `grammar`, in `range` of
    /// `text`, from the tree delivered last when it is of `text`'s
    /// revision; or why not, as the module docs say.
    pub fn captures(
        &self,
        syntax: &S,
        grammar: &GrammarName,
        query: &S::Query,
        text: &Snapshot,
        range: Range<usize>,
    ) -> Result<Vec<Capture>, CapturesRefusal> {
        if *grammar != self.grammar {
            return Err(CapturesRefusal::WrongGrammar);
        }
        let range = positions(text, range).map_err(|_| CapturesRefusal::BadRange)?;
        let parsed = self
            .parsed()
            .filter(|parsed| parsed.revision == text.revision())
            .ok_or(CapturesRefusal::NotParsed)?;
        // The tree's text is of the same revision, so the range is one of
        // its positions too.
        captures_in(syntax, query, &parsed.tree, &parsed.snapshot, range)
            .map_err(|_| CapturesRefusal::BadRange)
    }

    /// Keeps `query` as the query of `kind`, in place of any before
    /// ("Kept queries", in the module docs).
    pub fn keep(&self, kind: QueryKind, query: Arc<S::Query>) {
        lock(&self.state).kept.insert(kind, query);
    }

    /// The capture names of the query kept of `kind`; none when nothing of
    /// that kind is kept.
    pub fn kept_names(&self, syntax: &S, kind: QueryKind) -> Option<Vec<String>> {
        let query = lock(&self.state).kept.get(&kind).cloned()?;
        Some(syntax.capture_names(&query))
    }

    /// The capture names of the query kept of `kind` and its captures in
    /// `range` of `text`, from the tree delivered last when it is of
    /// `text`'s revision; or why not, as the module docs say.
    pub fn kept_captures(
        &self,
        syntax: &S,
        kind: QueryKind,
        text: &Snapshot,
        range: Range<usize>,
    ) -> Result<Kept, KeptRefusal> {
        let (query, parsed) = {
            let state = lock(&self.state);
            (state.kept.get(&kind).cloned(), state.delivered.clone())
        };
        let query = query.ok_or(KeptRefusal::NoQuery)?;
        let range = positions(text, range).map_err(|_| KeptRefusal::BadRange)?;
        let parsed = parsed
            .filter(|parsed| parsed.revision == text.revision())
            .ok_or(KeptRefusal::NotParsed)?;
        let captures = captures_in(syntax, &query, &parsed.tree, &parsed.snapshot, range)
            .map_err(|_| KeptRefusal::BadRange)?;
        Ok((syntax.capture_names(&query), captures))
    }

    /// One round, as the module docs say.
    pub fn parse_once(&self, syntax: &S) -> Outcome {
        self.round(syntax, false)
    }

    /// One refresh round, as the module docs say ("The refresh round"):
    /// an ordinary round when the text has moved past the last tree
    /// parsed, and otherwise, when that tree is not a whole parse, a whole
    /// parse of the text, delivered at the same revision only when it
    /// differs from that tree.
    pub fn refresh_once(&self, syntax: &S) -> Outcome {
        self.round(syntax, true)
    }

    /// A round, or with `refresh` a refresh round.
    fn round(&self, syntax: &S, refresh: bool) -> Outcome {
        let mut work = lock(&self.work);
        let (injections, generation) = {
            let state = lock(&self.state);
            (state.injections.clone(), state.generation)
        };
        let since = work.base.as_ref().map(|base| base.revision);
        let Some(latest) = self.source.latest(since) else {
            return Outcome::Gone;
        };
        let revision = latest.snapshot.revision();
        let Work {
            parser,
            parsers,
            base,
        } = &mut *work;
        // The refresh's whole parse: a text still at the last tree parsed,
        // which an incremental reparse made.
        if refresh
            && let Some(base) = base.as_mut()
            && base.revision == revision
            && !base.whole
        {
            let tree = syntax.parse(parser, &latest.snapshot, None);
            if syntax.nodes(&tree) != syntax.nodes(&base.tree) {
                let layers = layers(syntax, &injections, &tree, &latest.snapshot, parsers);
                *base = Base {
                    revision,
                    tree: tree.clone(),
                    whole: true,
                    generation,
                    layers: keys(&layers),
                };
                drop(work);
                return self.deliver(
                    Parsed {
                        layers,
                        ..Parsed::new(revision, latest.snapshot, tree)
                    },
                    generation,
                    true,
                );
            }
            // Equal nodes find equal layers: only the tree is new, and it
            // is the one delivered, so that is exact now.
            base.tree = tree;
            base.whole = true;
            if base.generation == generation {
                drop(work);
                self.found_exact(revision);
                return Outcome::UpToDate;
            }
        }
        let (tree, whole) = match base.as_mut() {
            Some(base) if base.revision == revision && base.generation == generation => {
                return Outcome::UpToDate;
            }
            // The text as it was; only the injections are new. Layers alike
            // in their keys are what was delivered: nothing to deliver.
            Some(base) if base.revision == revision => {
                let layers = layers(syntax, &injections, &base.tree, &latest.snapshot, parsers);
                let whole = base.whole;
                if keys(&layers) == base.layers {
                    base.generation = generation;
                    drop(work);
                    let mut state = lock(&self.state);
                    if state
                        .delivered
                        .as_ref()
                        .is_some_and(|parsed| parsed.revision == revision)
                    {
                        state.delivered_generation = generation;
                        if whole {
                            state.exact = Some(revision);
                        }
                        self.delivered.notify_all();
                    }
                    return Outcome::UpToDate;
                }
                let tree = base.tree.clone();
                *base = Base {
                    revision,
                    tree: tree.clone(),
                    whole,
                    generation,
                    layers: keys(&layers),
                };
                drop(work);
                return self.deliver(
                    Parsed {
                        layers,
                        ..Parsed::new(revision, latest.snapshot, tree)
                    },
                    generation,
                    whole,
                );
            }
            _ => {
                let edited = match (self.policy, base.as_ref(), &latest.patch) {
                    (ReparsePolicy::Incremental, Some(base), Some(patch))
                        if patch.from == base.revision && patch.to == revision =>
                    {
                        let mut edited = base.tree.clone();
                        for edit in &patch.edits {
                            syntax.edit(&mut edited, &edit.input_edit());
                        }
                        Some(edited)
                    }
                    _ => None,
                };
                let whole = edited.is_none();
                (
                    syntax.parse(parser, &latest.snapshot, edited.as_ref()),
                    whole,
                )
            }
        };
        let layers = layers(syntax, &injections, &tree, &latest.snapshot, parsers);
        *base = Some(Base {
            revision,
            tree: tree.clone(),
            whole,
            generation,
            layers: keys(&layers),
        });
        drop(work);
        self.deliver(
            Parsed {
                layers,
                ..Parsed::new(revision, latest.snapshot, tree)
            },
            generation,
            whole,
        )
    }

    /// Marks the tree delivered exact, when it is of `revision`: a refresh's
    /// whole parse found it equal to that tree.
    fn found_exact(&self, revision: Revision) {
        let mut state = lock(&self.state);
        if state
            .delivered
            .as_ref()
            .is_some_and(|parsed| parsed.revision == revision)
        {
            state.exact = Some(revision);
            self.delivered.notify_all();
        }
    }

    /// The delivery rule. `whole` says the tree is a whole parse of its
    /// revision, so delivered, it is exact.
    fn deliver(&self, parsed: Parsed<S::Tree>, generation: u64, whole: bool) -> Outcome {
        let mut state = lock(&self.state);
        let revision = parsed.revision;
        if revision < state.current {
            return Outcome::Stale(revision);
        }
        state.current = revision;
        state.delivered_generation = generation;
        state.exact = whole.then_some(revision);
        let parsed = Arc::new(parsed);
        for consumer in &state.consumers {
            consumer.deliver(&parsed);
        }
        state.delivered = Some(parsed);
        self.delivered.notify_all();
        Outcome::Delivered(revision)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use std::sync::Weak;

    use editor_text::{InputEdit, Text};

    use super::*;
    use crate::fake::{GRAMMAR, Parens, ParensParser, ParensQuery, ParensTree};
    use crate::highlight::Highlighter;
    use crate::inject::{Injections, Language, Layer};
    use crate::port::{Node, QueryError, QueryKind, ReparsePolicy};
    use std::time::Duration;

    /// A guard run out at once, on purpose: a read of what is delivered
    /// now, with no wait for a delivery not yet made.
    const AT_ONCE: HangGuard = HangGuard::held("a delivery not yet made", Duration::ZERO);

    /// [`Session::wait_for`], one of the readouts these tests are of: the
    /// one place they call it.
    fn wait_for<S: Syntax>(
        session: &Session<S>,
        revision: Revision,
        guard: HangGuard,
    ) -> Option<Arc<Parsed<S::Tree>>> {
        #[expect(
            clippy::disallowed_methods,
            reason = "reads the delivery of `revision` or a newer one, on `Session::wait_for`, one of the readouts these tests are of"
        )]
        session.wait_for(revision, guard)
    }

    /// [`Session::wait_exact`], one of the readouts these tests are of: the
    /// one place they call it.
    fn wait_exact<S: Syntax>(
        session: &Session<S>,
        revision: Revision,
        guard: HangGuard,
    ) -> Option<Arc<Parsed<S::Tree>>> {
        #[expect(
            clippy::disallowed_methods,
            reason = "reads an exact delivery of `revision` or a newer one, on `Session::wait_exact`, one of the readouts these tests are of"
        )]
        session.wait_exact(revision, guard)
    }

    /// A text behind a lock, as a document holds one, read as a source.
    pub(crate) struct TextSource(pub(crate) Weak<Mutex<Text>>);

    impl Source for TextSource {
        fn latest(&self, since: Option<Revision>) -> Option<Latest> {
            let text = self.0.upgrade()?;
            let text = lock(&text);
            Some(Latest {
                snapshot: text.snapshot(),
                patch: since.and_then(|since| text.changes_since(since).ok()),
            })
        }
    }

    /// The fake, recording what each parse was handed as its old tree (the
    /// edits that tree was told, or `None` for a whole parse, in `olds`; and
    /// the old tree's nodes, in `old_nodes`), and running a hook once,
    /// inside the next parse.
    ///
    /// With `recovers`, it recovers from an error as a real library may:
    /// an incremental parse whose tree has an error or a missing node
    /// answers another tree than a fresh parse would ([`Recovers`]).
    ///
    /// Its grammar's policy is `policy`: incremental by default, and none
    /// for a test of a grammar that declares none.
    pub(crate) struct Recording {
        pub(crate) olds: Mutex<Vec<Option<Vec<InputEdit>>>>,
        pub(crate) old_nodes: Mutex<Vec<Option<Vec<Node>>>>,
        pub(crate) asked: Mutex<Vec<Range<usize>>>,
        pub(crate) hook: Mutex<Option<Box<dyn FnOnce() + Send>>>,
        pub(crate) recovers: Recovers,
        pub(crate) policy: Option<ReparsePolicy>,
    }

    /// What [`Recording`]'s incremental parse of a text with an error
    /// answers.
    #[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
    pub(crate) enum Recovers {
        /// The fresh parse's tree.
        #[default]
        AsFresh,
        /// The tree of the text with one more atom: it still has an error,
        /// and its root runs past the text.
        OutsideText,
        /// The fresh parse's tree with its error and missing nodes left
        /// out: a whole tree of the text, and not the fresh one.
        Whole,
    }

    impl Recovers {
        /// What an incremental parse of `text`, whose tree as the fake
        /// parses it is `tree`, answers.
        pub(crate) fn tree(self, tree: ParensTree, text: &Snapshot) -> ParensTree {
            if !Parens.has_errors(&tree) {
                return tree;
            }
            match self {
                Self::AsFresh => tree,
                Self::OutsideText => {
                    let other = Text::from(format!("{text} x").as_str()).snapshot();
                    Parens.parse(&mut ParensParser, &other, None)
                }
                Self::Whole => {
                    let mut nodes = Parens.nodes(&tree);
                    nodes.retain(|node| !node.error && !node.missing);
                    ParensTree::of_nodes(nodes)
                }
            }
        }
    }

    impl Default for Recording {
        fn default() -> Self {
            Self {
                olds: Mutex::default(),
                old_nodes: Mutex::default(),
                asked: Mutex::default(),
                hook: Mutex::default(),
                recovers: Recovers::AsFresh,
                policy: Some(ReparsePolicy::Incremental),
            }
        }
    }

    impl Syntax for Recording {
        type Parser = ParensParser;
        type Tree = ParensTree;
        type Query = ParensQuery;

        fn grammars(&self) -> Vec<GrammarName> {
            Parens.grammars()
        }
        fn parser(&self, grammar: &GrammarName) -> Option<ParensParser> {
            Parens.parser(grammar)
        }
        fn reparse_policy(&self, grammar: &GrammarName) -> Option<ReparsePolicy> {
            Parens.reparse_policy(grammar).and(self.policy)
        }
        fn parse(
            &self,
            parser: &mut ParensParser,
            text: &Snapshot,
            old: Option<&ParensTree>,
        ) -> ParensTree {
            lock(&self.olds).push(old.map(|old| old.edits().to_vec()));
            lock(&self.old_nodes).push(old.map(|old| Parens.nodes(old)));
            if let Some(hook) = lock(&self.hook).take() {
                hook();
            }
            let tree = Parens.parse(parser, text, old);
            if old.is_some() {
                return self.recovers.tree(tree, text);
            }
            tree
        }
        fn edit(&self, tree: &mut ParensTree, edit: &InputEdit) {
            Parens.edit(tree, edit);
        }
        fn compile(&self, grammar: &GrammarName, source: &str) -> Result<ParensQuery, QueryError> {
            Parens.compile(grammar, source)
        }
        fn shipped_query(&self, grammar: &GrammarName, kind: crate::QueryKind) -> Option<String> {
            Parens.shipped_query(grammar, kind)
        }
        fn capture_names(&self, query: &ParensQuery) -> Vec<String> {
            Parens.capture_names(query)
        }
        fn captures(
            &self,
            query: &ParensQuery,
            tree: &ParensTree,
            text: &Snapshot,
            range: Range<usize>,
        ) -> Vec<Capture> {
            lock(&self.asked).push(range.clone());
            Parens.captures(query, tree, text, range)
        }
        fn matches(
            &self,
            query: &ParensQuery,
            tree: &ParensTree,
            text: &Snapshot,
            range: Range<usize>,
        ) -> Vec<crate::port::Match> {
            Parens.matches(query, tree, text, range)
        }
        fn pattern_settings(
            &self,
            query: &ParensQuery,
            pattern: usize,
        ) -> Vec<crate::port::Setting> {
            Parens.pattern_settings(query, pattern)
        }
        fn parse_in(
            &self,
            parser: &mut ParensParser,
            text: &Snapshot,
            ranges: &[Range<usize>],
        ) -> ParensTree {
            Parens.parse_in(parser, text, ranges)
        }
        fn nodes(&self, tree: &ParensTree) -> Vec<Node> {
            Parens.nodes(tree)
        }
        fn has_errors(&self, tree: &ParensTree) -> bool {
            Parens.has_errors(tree)
        }
    }

    /// A consumer that records the revisions it is handed.
    pub(crate) struct Revisions(pub(crate) Arc<Mutex<Vec<Revision>>>);

    impl<T> Consumer<T> for Revisions {
        fn deliver(&self, parsed: &Parsed<T>) {
            lock(&self.0).push(parsed.revision);
        }
    }

    /// A text, a session over it with the recording syntax, and the
    /// revisions its consumer has been handed.
    struct Fixture {
        text: Arc<Mutex<Text>>,
        syntax: Recording,
        session: Arc<Session<Recording>>,
        delivered: Arc<Mutex<Vec<Revision>>>,
    }

    impl Fixture {
        fn new(text: &str) -> Self {
            Self::with(text, Recording::default())
        }

        /// A fixture whose syntax is `syntax`.
        fn with(text: &str, syntax: Recording) -> Self {
            let text = Arc::new(Mutex::new(Text::from(text)));
            let session = Session::new(
                &syntax,
                GrammarName::new(GRAMMAR),
                Box::new(TextSource(Arc::downgrade(&text))),
            )
            .unwrap();
            let delivered = Arc::new(Mutex::new(Vec::new()));
            session.subscribe(Box::new(Revisions(delivered.clone())));
            Self {
                text,
                syntax,
                session: Arc::new(session),
                delivered,
            }
        }

        /// Replaces `range` with `with`, and returns the revision.
        fn replace(&self, range: Range<usize>, with: &str) -> Revision {
            replace(&self.text, range, with)
        }

        fn delivered(&self) -> Vec<Revision> {
            lock(&self.delivered).clone()
        }

        fn olds(&self) -> Vec<Option<Vec<InputEdit>>> {
            lock(&self.syntax.olds).clone()
        }

        /// Whether the delivered tree equals a fresh parse of the text now.
        fn delivered_is_fresh(&self) -> bool {
            let snapshot = lock(&self.text).snapshot();
            let fresh = Parens.parse(&mut ParensParser, &snapshot, None);
            self.session.parsed().is_some_and(|parsed| {
                parsed.revision == snapshot.revision()
                    && Parens.nodes(&parsed.tree) == Parens.nodes(&fresh)
            })
        }
    }

    /// Replaces `range` of `text` with `with`, and returns the revision.
    pub(crate) fn replace(text: &Mutex<Text>, range: Range<usize>, with: &str) -> Revision {
        let mut text = lock(text);
        text.replace(range, with).unwrap();
        text.current().revision()
    }

    #[test]
    fn a_grammar_the_syntax_lacks_makes_no_session() {
        let text = Arc::new(Mutex::new(Text::from("")));
        let source = Box::new(TextSource(Arc::downgrade(&text)));

        assert!(Session::new(&Parens, GrammarName::new("rust"), source).is_none());
    }

    #[test]
    fn a_grammar_that_declares_no_reparse_policy_makes_no_session() {
        let text = Arc::new(Mutex::new(Text::from("")));
        let source = Box::new(TextSource(Arc::downgrade(&text)));
        let syntax = Recording {
            policy: None,
            ..Recording::default()
        };

        assert!(Session::new(&syntax, GrammarName::new(GRAMMAR), source).is_none());
    }

    #[test]
    fn the_first_round_parses_the_whole_text_and_delivers_it() {
        let fixture = Fixture::new("(a b)");

        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::Delivered(Revision::new(0))
        );
        assert_eq!(fixture.olds(), [None]);
        assert_eq!(fixture.delivered(), [Revision::new(0)]);
        assert!(fixture.delivered_is_fresh());
    }

    #[test]
    fn a_round_with_nothing_new_parses_nothing() {
        let fixture = Fixture::new("(a b)");
        fixture.session.parse_once(&fixture.syntax);

        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::UpToDate
        );
        assert_eq!(fixture.olds().len(), 1);
        assert_eq!(fixture.delivered(), [Revision::new(0)]);
    }

    #[test]
    fn a_round_after_edits_reparses_with_the_base_told_the_patchs_edits_in_order() {
        let fixture = Fixture::new("(a b)\n(c)");
        fixture.session.parse_once(&fixture.syntax);
        fixture.replace(1..2, "xyz");
        fixture.replace(0..0, "w ");
        let patch = lock(&fixture.text).changes_since(Revision::new(0)).unwrap();

        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::Delivered(Revision::new(2))
        );
        let told: Vec<InputEdit> = patch.edits.iter().map(|edit| edit.input_edit()).collect();
        assert_eq!(patch.edits.len(), 2);
        assert_eq!(fixture.olds(), [None, Some(told)]);
        assert!(fixture.delivered_is_fresh());
    }

    #[test]
    fn an_edit_whose_incremental_reparse_has_an_error_delivers_that_tree_with_no_whole_parse() {
        let fixture = Fixture::with(
            "(a b)",
            Recording {
                recovers: Recovers::OutsideText,
                ..Recording::default()
            },
        );
        fixture.session.parse_once(&fixture.syntax);
        let revision = fixture.replace(0..0, "(");
        let patch = lock(&fixture.text).changes_since(Revision::new(0)).unwrap();

        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::Delivered(revision)
        );
        let told: Vec<InputEdit> = patch.edits.iter().map(|edit| edit.input_edit()).collect();
        // No third parse: the incremental one is kept, error and all.
        assert_eq!(fixture.olds(), [None, Some(told)]);
        let delivered = fixture.session.parsed().unwrap();
        assert!(fixture.syntax.has_errors(&delivered.tree));
        // The recovering tree's nodes, not a fresh parse's.
        let recovered = Text::from("((a b) x").snapshot();
        assert_eq!(
            Parens.nodes(&delivered.tree),
            Parens.nodes(&Parens.parse(&mut ParensParser, &recovered, None))
        );
        assert!(!fixture.delivered_is_fresh());
    }

    /// The nodes of a fresh parse of `text`.
    fn fresh_nodes(text: &str) -> Vec<Node> {
        Parens.nodes(&Parens.parse(&mut ParensParser, &Text::from(text).snapshot(), None))
    }

    #[test]
    fn a_refresh_whose_whole_parse_differs_delivers_it_at_the_same_revision() {
        let fixture = Fixture::with(
            "(a b)",
            Recording {
                recovers: Recovers::Whole,
                ..Recording::default()
            },
        );
        fixture.session.parse_once(&fixture.syntax);
        let revision = fixture.replace(0..0, "(");
        fixture.session.parse_once(&fixture.syntax);
        assert!(!fixture.delivered_is_fresh());

        assert_eq!(
            fixture.session.refresh_once(&fixture.syntax),
            Outcome::Delivered(revision)
        );
        assert!(fixture.delivered_is_fresh());
        assert_eq!(fixture.olds().last(), Some(&None));
        assert_eq!(fixture.delivered(), [Revision::new(0), revision, revision]);
        assert!(wait_exact(&fixture.session, revision, AT_ONCE).is_some());
    }

    #[test]
    fn a_refresh_whose_whole_parse_equals_the_delivered_tree_delivers_nothing() {
        let fixture = Fixture::new("(a b)");
        fixture.session.parse_once(&fixture.syntax);
        let revision = fixture.replace(5..5, " c");
        fixture.session.parse_once(&fixture.syntax);
        assert!(wait_exact(&fixture.session, revision, AT_ONCE).is_none());

        assert_eq!(
            fixture.session.refresh_once(&fixture.syntax),
            Outcome::UpToDate
        );
        // A whole parse was made, and nothing delivered.
        assert_eq!(fixture.olds().len(), 3);
        assert_eq!(fixture.olds().last(), Some(&None));
        assert_eq!(fixture.delivered(), [Revision::new(0), revision]);
        let exact = wait_exact(&fixture.session, revision, AT_ONCE);
        assert_eq!(exact.map(|parsed| parsed.revision), Some(revision));
    }

    #[test]
    fn a_refresh_of_a_whole_tree_parses_nothing() {
        let fixture = Fixture::new("(a b)");
        fixture.session.parse_once(&fixture.syntax);

        assert_eq!(
            fixture.session.refresh_once(&fixture.syntax),
            Outcome::UpToDate
        );
        assert_eq!(fixture.olds(), [None]);
        assert_eq!(fixture.delivered(), [Revision::new(0)]);
        // A second refresh after one that parsed whole parses nothing more.
        let revision = fixture.replace(5..5, " c");
        fixture.session.parse_once(&fixture.syntax);
        fixture.session.refresh_once(&fixture.syntax);
        assert_eq!(
            fixture.session.refresh_once(&fixture.syntax),
            Outcome::UpToDate
        );
        assert_eq!(fixture.olds().len(), 3);
        assert_eq!(fixture.delivered(), [Revision::new(0), revision]);
    }

    #[test]
    fn a_refresh_of_a_text_that_moved_is_an_ordinary_round() {
        let fixture = Fixture::new("(a b)");
        fixture.session.parse_once(&fixture.syntax);
        let revision = fixture.replace(5..5, " c");
        let patch = lock(&fixture.text).changes_since(Revision::new(0)).unwrap();

        assert_eq!(
            fixture.session.refresh_once(&fixture.syntax),
            Outcome::Delivered(revision)
        );
        let told: Vec<InputEdit> = patch.edits.iter().map(|edit| edit.input_edit()).collect();
        assert_eq!(fixture.olds(), [None, Some(told)]);

        // With no base yet, too: the first round.
        let first = Fixture::new("(a)");
        assert_eq!(
            first.session.refresh_once(&first.syntax),
            Outcome::Delivered(Revision::new(0))
        );
        assert_eq!(first.olds(), [None]);
    }

    #[test]
    fn a_stale_refresh_leaves_its_whole_tree_as_the_next_base() {
        let fixture = Fixture::with(
            "(a b)",
            Recording {
                recovers: Recovers::Whole,
                ..Recording::default()
            },
        );
        fixture.session.parse_once(&fixture.syntax);
        let revision = fixture.replace(0..0, "(");
        fixture.session.parse_once(&fixture.syntax);
        // Inside the refresh's whole parse, the text is edited and the
        // session told so.
        let (text, session) = (fixture.text.clone(), fixture.session.clone());
        *lock(&fixture.syntax.hook) = Some(Box::new(move || {
            let revision = replace(&text, 6..6, " c");
            session.touch(revision);
        }));

        assert_eq!(
            fixture.session.refresh_once(&fixture.syntax),
            Outcome::Stale(revision)
        );
        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::Delivered(Revision::new(2))
        );
        // The next round reparsed from the refresh's whole tree, not the
        // recovered one.
        let old_nodes = lock(&fixture.syntax.old_nodes).clone();
        assert_eq!(old_nodes.last(), Some(&Some(fresh_nodes("((a b)"))));
    }

    #[test]
    fn waiting_for_an_exact_tree_waits_for_a_whole_parse_of_the_revision() {
        let fixture = Fixture::new("(a b)");
        assert!(wait_exact(&fixture.session, Revision::new(0), AT_ONCE).is_none());
        // The first round parses whole: its tree is exact.
        fixture.session.parse_once(&fixture.syntax);
        assert!(wait_exact(&fixture.session, Revision::new(0), AT_ONCE).is_some());
        // An incremental delivery is not, until a refresh finds it so.
        let revision = fixture.replace(5..5, " c");
        fixture.session.parse_once(&fixture.syntax);
        assert!(wait_exact(&fixture.session, Revision::new(0), AT_ONCE).is_none());
        fixture.session.refresh_once(&fixture.syntax);
        assert!(wait_exact(&fixture.session, revision, AT_ONCE).is_some());
        // Not past what has been parsed.
        assert!(wait_exact(&fixture.session, Revision::new(2), AT_ONCE).is_none());
    }

    #[test]
    fn a_whole_grammars_rounds_are_never_handed_an_old_tree() {
        let fixture = Fixture::with(
            "(a b)",
            Recording {
                policy: Some(ReparsePolicy::Whole),
                ..Recording::default()
            },
        );
        fixture.session.parse_once(&fixture.syntax);
        for (range, with) in [(0..0, "("), (5..5, " c"), (0..1, "")] {
            let revision = fixture.replace(range, with);
            assert_eq!(
                fixture.session.parse_once(&fixture.syntax),
                Outcome::Delivered(revision)
            );
            assert!(fixture.delivered_is_fresh());
        }

        assert_eq!(fixture.olds(), [None, None, None, None]);
        assert_eq!(fixture.session.policy(), ReparsePolicy::Whole);
    }

    #[test]
    fn an_incremental_reparse_whose_tree_has_no_error_is_kept() {
        let fixture = Fixture::with(
            "(a b",
            Recording {
                recovers: Recovers::OutsideText,
                ..Recording::default()
            },
        );
        fixture.session.parse_once(&fixture.syntax);
        let revision = fixture.replace(4..4, ")");

        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::Delivered(revision)
        );
        assert_eq!(fixture.olds().len(), 2);
        assert!(fixture.olds()[1].is_some());
        assert!(fixture.delivered_is_fresh());
    }

    #[test]
    fn a_log_that_has_forgotten_the_base_gives_a_whole_parse() {
        let fixture = Fixture::new("(a b)");
        fixture.session.parse_once(&fixture.syntax);
        let revision = fixture.replace(0..0, "x ");
        lock(&fixture.text).forget(revision).unwrap();

        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::Delivered(revision)
        );
        assert_eq!(fixture.olds(), [None, None]);
        assert!(fixture.delivered_is_fresh());
    }

    /// A source whose patches claim to start a revision later than asked.
    struct Unchained(TextSource);

    impl Source for Unchained {
        fn latest(&self, since: Option<Revision>) -> Option<Latest> {
            let mut latest = self.0.latest(since)?;
            if let Some(patch) = &mut latest.patch {
                patch.from = Revision::new(patch.from.get() + 1);
            }
            Some(latest)
        }
    }

    #[test]
    fn a_patch_that_does_not_chain_from_the_base_gives_a_whole_parse() {
        let text = Arc::new(Mutex::new(Text::from("(a)")));
        let syntax = Recording::default();
        let source = Box::new(Unchained(TextSource(Arc::downgrade(&text))));
        let session = Session::new(&syntax, GrammarName::new(GRAMMAR), source).unwrap();
        session.parse_once(&syntax);
        replace(&text, 0..0, "b ");

        assert_eq!(
            session.parse_once(&syntax),
            Outcome::Delivered(Revision::new(1))
        );
        assert_eq!(lock(&syntax.olds).clone(), [None, None]);
    }

    #[test]
    fn a_text_that_is_gone_ends_the_session() {
        let fixture = Fixture::new("(a)");
        let Fixture {
            text,
            syntax,
            session,
            ..
        } = fixture;
        drop(text);

        assert_eq!(session.parse_once(&syntax), Outcome::Gone);
        assert!(session.parsed().is_none());
    }

    #[test]
    fn a_result_older_than_the_current_revision_is_not_delivered() {
        let fixture = Fixture::new("(a b)");
        fixture.replace(0..0, "x ");
        // Inside the parse of revision 1, the text is edited to revision 2
        // and the session is told so.
        let (text, session) = (fixture.text.clone(), fixture.session.clone());
        *lock(&fixture.syntax.hook) = Some(Box::new(move || {
            let revision = replace(&text, 0..0, "y ");
            session.touch(revision);
        }));
        fixture.session.touch(Revision::new(1));

        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::Stale(Revision::new(1))
        );
        assert_eq!(fixture.delivered(), []);
        assert!(fixture.session.parsed().is_none());

        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::Delivered(Revision::new(2))
        );
        assert_eq!(fixture.delivered(), [Revision::new(2)]);
        assert!(fixture.delivered_is_fresh());
    }

    #[test]
    fn a_stale_result_is_the_base_of_the_next_parse() {
        let fixture = Fixture::new("(a b)");
        fixture.replace(0..0, "x ");
        let (text, session) = (fixture.text.clone(), fixture.session.clone());
        *lock(&fixture.syntax.hook) = Some(Box::new(move || {
            let revision = replace(&text, 1..1, "z");
            session.touch(revision);
        }));
        fixture.session.parse_once(&fixture.syntax);
        let patch = lock(&fixture.text).changes_since(Revision::new(1)).unwrap();

        fixture.session.parse_once(&fixture.syntax);
        let told: Vec<InputEdit> = patch.edits.iter().map(|edit| edit.input_edit()).collect();
        assert_eq!(fixture.olds(), [None, Some(told)]);
    }

    #[test]
    fn a_touch_says_whether_its_revision_is_newer_than_every_one_told() {
        let fixture = Fixture::new("(a)");

        // Made at revision 0: told of it already.
        assert!(!fixture.session.touch(Revision::new(0)));
        assert!(fixture.session.touch(Revision::new(2)));
        assert!(!fixture.session.touch(Revision::new(2)));
        assert!(!fixture.session.touch(Revision::new(1)));
        // A delivery at a revision not told does not make its touch old:
        // the edit's touch may come after the worker has parsed it.
        fixture.replace(0..0, "b ");
        fixture.replace(0..0, "c ");
        fixture.replace(0..0, "d ");
        fixture.session.parse_once(&fixture.syntax);
        assert_eq!(fixture.session.current(), Revision::new(3));
        assert!(fixture.session.touch(Revision::new(3)));
    }

    #[test]
    fn sessions_have_ids_of_their_own() {
        let (one, two) = (Fixture::new("(a)"), Fixture::new("(a)"));

        assert_ne!(one.session.id, two.session.id);
    }

    #[test]
    fn a_late_touch_does_not_lower_the_current_revision() {
        let fixture = Fixture::new("");
        fixture.session.touch(Revision::new(5));
        fixture.session.touch(Revision::new(3));

        assert_eq!(fixture.session.current(), Revision::new(5));
    }

    #[test]
    fn a_result_newer_than_the_last_touch_is_delivered() {
        // The worker can see an edit before the edit's touch arrives.
        let fixture = Fixture::new("(a)");
        fixture.replace(0..0, "b ");
        fixture.replace(0..0, "c ");

        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::Delivered(Revision::new(2))
        );
        assert_eq!(fixture.session.current(), Revision::new(2));
        fixture.session.touch(Revision::new(1));
        assert_eq!(fixture.session.current(), Revision::new(2));
    }

    #[test]
    fn waiting_for_a_revision_answers_the_delivered_result_once_it_reaches_it() {
        let fixture = Fixture::new("(a)");

        assert!(wait_for(&fixture.session, Revision::new(0), AT_ONCE).is_none());
        fixture.session.parse_once(&fixture.syntax);
        let parsed = wait_for(&fixture.session, Revision::new(0), AT_ONCE);
        assert_eq!(parsed.map(|parsed| parsed.revision), Some(Revision::new(0)));
        assert!(wait_for(&fixture.session, Revision::new(1), AT_ONCE).is_none());
    }

    /// The captures of every atom and list, in `range` of `snapshot`, as
    /// the session answers them with a query compiled for its grammar,
    /// said to be of `grammar`.
    fn captures(
        fixture: &Fixture,
        grammar: &str,
        snapshot: &Snapshot,
        range: Range<usize>,
    ) -> Result<Vec<Capture>, CapturesRefusal> {
        let query = Parens
            .compile(&GrammarName::new(GRAMMAR), "atom @atom\nlist @list")
            .unwrap();
        fixture.session.captures(
            &fixture.syntax,
            &GrammarName::new(grammar),
            &query,
            snapshot,
            range,
        )
    }

    #[test]
    fn a_question_of_captures_is_refused_for_its_grammar_then_its_range_then_a_tree_not_parsed() {
        let fixture = Fixture::new("(é)");
        let snapshot = lock(&fixture.text).snapshot();

        assert_eq!(
            captures(&fixture, "rust", &snapshot, 2..4),
            Err(CapturesRefusal::WrongGrammar)
        );
        assert_eq!(
            captures(&fixture, GRAMMAR, &snapshot, 2..4),
            Err(CapturesRefusal::BadRange)
        );
        assert_eq!(
            captures(&fixture, GRAMMAR, &snapshot, Range { start: 3, end: 1 }),
            Err(CapturesRefusal::BadRange)
        );
        assert_eq!(
            captures(&fixture, GRAMMAR, &snapshot, 0..5),
            Err(CapturesRefusal::BadRange)
        );
        assert_eq!(
            captures(&fixture, GRAMMAR, &snapshot, 0..4),
            Err(CapturesRefusal::NotParsed)
        );
        fixture.session.parse_once(&fixture.syntax);
        assert_eq!(
            captures(&fixture, "rust", &snapshot, 0..4),
            Err(CapturesRefusal::WrongGrammar)
        );
        assert_eq!(
            captures(&fixture, GRAMMAR, &snapshot, 0..5),
            Err(CapturesRefusal::BadRange)
        );
    }

    #[test]
    fn captures_are_answered_only_from_a_delivered_tree_of_the_snapshots_own_revision() {
        let fixture = Fixture::new("(a b)");
        let first = lock(&fixture.text).snapshot();
        fixture.session.parse_once(&fixture.syntax);
        let ranges = |answer: Result<Vec<Capture>, CapturesRefusal>| {
            answer.map(|captures| captures.iter().map(Capture::range).collect::<Vec<_>>())
        };

        assert_eq!(
            ranges(captures(&fixture, GRAMMAR, &first, 0..5)),
            Ok(vec![0..5, 1..2, 3..4])
        );
        fixture.replace(5..5, " c");
        let second = lock(&fixture.text).snapshot();
        // The tree delivered is of the first revision still.
        assert_eq!(
            captures(&fixture, GRAMMAR, &second, 0..7),
            Err(CapturesRefusal::NotParsed)
        );
        assert_eq!(
            ranges(captures(&fixture, GRAMMAR, &first, 3..4)),
            Ok(vec![0..5, 3..4])
        );
        fixture.session.parse_once(&fixture.syntax);
        // Now it is of the second: a tree newer than the snapshot answers
        // nothing either.
        assert_eq!(
            captures(&fixture, GRAMMAR, &first, 0..5),
            Err(CapturesRefusal::NotParsed)
        );
        assert_eq!(
            ranges(captures(&fixture, GRAMMAR, &second, 3..7)),
            Ok(vec![0..5, 3..4, 6..7])
        );
    }

    /// The fake's shipped highlights, each capture drawn in a face named
    /// after it.
    fn parens_highlighter() -> Highlighter<ParensQuery> {
        let grammar = GrammarName::new(GRAMMAR);
        let source = Parens
            .shipped_query(&grammar, QueryKind::Highlights)
            .unwrap();
        let query = Parens.compile(&grammar, &source).unwrap();
        let names = Parens.capture_names(&query);
        let faces = names
            .iter()
            .map(|name| Some(format!("syntax.{name}")))
            .collect();
        Highlighter::new(Arc::new(query), names.len(), faces).unwrap()
    }

    /// The spans `session` draws over the whole of `snapshot`, each with
    /// the name of its face; none when it draws nothing.
    fn highlighted(
        syntax: &Recording,
        session: &Session<Recording>,
        snapshot: &Snapshot,
    ) -> Option<Vec<(Range<usize>, String)>> {
        let highlights = session.highlights(snapshot)?;
        let mut spans = Vec::new();
        highlights.spans(syntax, 0..snapshot.len(), &mut spans);
        Some(
            spans
                .into_iter()
                .map(|span| (span.bytes, highlights.faces()[span.face].clone()))
                .collect(),
        )
    }

    /// The fresh highlights of `snapshot`, each with the name of its face.
    fn fresh_of(snapshot: &Snapshot) -> Vec<(Range<usize>, String)> {
        let highlighter = parens_highlighter();
        crate::highlight::fresh(&Parens, &highlighter, None, &mut ParensParser, snapshot)
            .into_iter()
            .map(|span| (span.bytes, highlighter.names()[span.face].clone()))
            .collect()
    }

    #[test]
    fn no_highlights_before_the_first_delivery_or_without_a_highlighter() {
        let fixture = Fixture::new("(a b)");
        let snapshot = lock(&fixture.text).snapshot();
        fixture.session.parse_once(&fixture.syntax);
        // Delivered, but no highlighter.
        assert!(fixture.session.highlights(&snapshot).is_none());

        let fixture = Fixture::new("(a b)");
        assert!(!fixture.session.set_highlighter(parens_highlighter()));
        assert!(fixture.session.highlights(&snapshot).is_none());
        fixture.session.parse_once(&fixture.syntax);
        assert_eq!(
            highlighted(&fixture.syntax, &fixture.session, &snapshot),
            Some(fresh_of(&snapshot))
        );
        // A second highlighter replaces the first.
        assert!(fixture.session.set_highlighter(parens_highlighter()));
    }

    #[test]
    fn the_highlights_of_a_newer_snapshot_are_the_delivered_ones_carried() {
        let fixture = Fixture::new("(ab cd)");
        fixture.session.set_highlighter(parens_highlighter());
        fixture.session.parse_once(&fixture.syntax);
        // `x` typed inside `ab`, told and not parsed.
        let revision = fixture.replace(2..2, "x");
        fixture.session.touch(revision);
        let snapshot = lock(&fixture.text).snapshot();

        let carried = highlighted(&fixture.syntax, &fixture.session, &snapshot).unwrap();
        // Revision 0's spans, carried around the `x`, which is plain: not
        // none, and not what a fresh parse of revision 1 draws.
        assert_eq!(
            carried,
            [
                (0..2, "syntax.list".to_owned()),
                (3..8, "syntax.list".to_owned()),
                (0..1, "syntax.punctuation.bracket".to_owned()),
                (1..2, "syntax.variable".to_owned()),
                (3..4, "syntax.variable".to_owned()),
                (5..7, "syntax.variable".to_owned()),
                (7..8, "syntax.punctuation.bracket".to_owned()),
            ]
        );
        assert_ne!(carried, fresh_of(&snapshot));
        assert_eq!(
            fixture.session.highlights(&snapshot).unwrap().revision(),
            Revision::new(0)
        );
    }

    #[test]
    fn the_delivered_highlights_replace_the_carried_ones() {
        let fixture = Fixture::new("(ab cd)");
        fixture.session.set_highlighter(parens_highlighter());
        fixture.session.parse_once(&fixture.syntax);
        let revision = fixture.replace(2..2, "x");
        fixture.session.touch(revision);
        let snapshot = lock(&fixture.text).snapshot();

        fixture.session.parse_once(&fixture.syntax);
        assert_eq!(
            highlighted(&fixture.syntax, &fixture.session, &snapshot),
            Some(fresh_of(&snapshot))
        );
    }

    #[test]
    fn a_published_snapshot_the_text_has_moved_past_draws_nothing() {
        let fixture = Fixture::new("(a b)");
        fixture.session.set_highlighter(parens_highlighter());
        fixture.session.parse_once(&fixture.syntax);
        fixture.replace(0..0, "x ");
        let published = lock(&fixture.text).snapshot();
        // The text moves on past the snapshot published.
        fixture.replace(0..0, "y ");

        assert!(fixture.session.highlights(&published).is_none());
        // A snapshot older than the tree delivered draws nothing either.
        let first = Text::from("(a b)").snapshot();
        fixture.session.parse_once(&fixture.syntax);
        assert!(fixture.session.highlights(&first).is_none());
    }

    #[test]
    fn a_log_that_has_forgotten_the_delivered_revision_draws_nothing() {
        let fixture = Fixture::new("(a b)");
        fixture.session.set_highlighter(parens_highlighter());
        fixture.session.parse_once(&fixture.syntax);
        let revision = fixture.replace(0..0, "x ");
        lock(&fixture.text).forget(revision).unwrap();
        let snapshot = lock(&fixture.text).snapshot();

        assert!(fixture.session.highlights(&snapshot).is_none());
    }

    #[test]
    fn the_query_is_asked_only_of_the_range_mapped_back() {
        let fixture = Fixture::new("(a)\n(bb)\n(c)\n");
        fixture.session.set_highlighter(parens_highlighter());
        fixture.session.parse_once(&fixture.syntax);
        // `zz` put in at the start of the second row: revision 0's second
        // row, 4..8, is 6..10 now.
        let revision = fixture.replace(4..4, "zz");
        fixture.session.touch(revision);
        let snapshot = lock(&fixture.text).snapshot();
        let highlights = fixture.session.highlights(&snapshot).unwrap();
        lock(&fixture.syntax.asked).clear();

        let mut spans = Vec::new();
        highlights.spans(&fixture.syntax, 6..10, &mut spans);
        // The port is asked the range mapped back, a byte wider each side.
        assert_eq!(lock(&fixture.syntax.asked).clone(), vec![3..9]);
        let ranges: Vec<Range<usize>> = spans.into_iter().map(|span| span.bytes).collect();
        assert_eq!(ranges, [6..10, 6..7, 7..9, 9..10]);
    }

    /// The fake's query `source`, compiled.
    fn parens_query(source: &str) -> Arc<ParensQuery> {
        Arc::new(Parens.compile(&GrammarName::new(GRAMMAR), source).unwrap())
    }

    /// The host's injections query: each list's text but its child lists
    /// and atoms, as the language `inner`.
    fn inner_injections() -> Arc<ParensQuery> {
        parens_query("list @injection.content #set! injection.language inner")
    }

    /// The language `inner`: the fake's grammar, its lists drawn in
    /// `inner.list` and its parens in `inner.paren`.
    fn inner_language() -> Language<ParensQuery> {
        let query = parens_query("list @l\n\"(\" @p\n\")\" @p");
        let faces = vec![
            Some("inner.list".to_owned()),
            Some("inner.paren".to_owned()),
        ];
        Language {
            grammar: GrammarName::new(GRAMMAR),
            highlighter: Arc::new(Highlighter::new(query, 2, faces).unwrap()),
            injections: None,
        }
    }

    /// The injections `inner_injections` and `inner_language` make.
    fn injections() -> Injections<ParensQuery> {
        Injections {
            query: Some(inner_injections()),
            languages: BTreeMap::from([("inner".to_owned(), inner_language())]),
        }
    }

    /// Gives `session` the injections of `injections()`.
    fn inject(session: &Session<Recording>) {
        session.set_injections(Some(inner_injections()));
        session.set_language("inner".to_owned(), inner_language());
    }

    /// A layer as its language, depth, ranges and nodes.
    type Shape = (String, u32, Vec<Range<usize>>, Vec<Node>);

    /// Each layer as its language, depth, ranges and nodes.
    fn shape(layers: &[Layer<ParensTree>]) -> Vec<Shape> {
        layers
            .iter()
            .map(|layer| {
                (
                    layer.language.clone(),
                    layer.depth,
                    layer.ranges.clone(),
                    Parens.nodes(&layer.tree),
                )
            })
            .collect()
    }

    /// The layers a fresh round of the text of `fixture` as it is now finds.
    fn fresh_layers(fixture: &Fixture) -> Vec<Shape> {
        let snapshot = lock(&fixture.text).snapshot();
        let grammar = GrammarName::new(GRAMMAR);
        let (_, layers) =
            crate::inject::fresh(&Parens, &grammar, &injections(), &snapshot).unwrap();
        shape(&layers)
    }

    /// The layers of the tree `fixture`'s session delivered last.
    fn delivered_layers(fixture: &Fixture) -> Vec<Shape> {
        shape(&fixture.session.parsed().unwrap().layers)
    }

    #[test]
    fn waiting_for_a_revision_waits_for_layers_found_with_the_injections_as_they_are() {
        let fixture = Fixture::new("(a)");
        fixture.session.parse_once(&fixture.syntax);
        inject(&fixture.session);

        assert!(wait_for(&fixture.session, Revision::new(0), AT_ONCE).is_none());
        fixture.session.parse_once(&fixture.syntax);
        assert!(wait_for(&fixture.session, Revision::new(0), AT_ONCE).is_some());
    }

    #[test]
    fn a_round_with_injections_delivers_the_layers_a_fresh_round_finds() {
        let fixture = Fixture::new("(a b) c (d)");
        inject(&fixture.session);

        fixture.session.parse_once(&fixture.syntax);
        let layers = delivered_layers(&fixture);
        assert_eq!(layers, fresh_layers(&fixture));
        let ranges: Vec<Vec<Range<usize>>> = layers.into_iter().map(|layer| layer.2).collect();
        assert_eq!(ranges, [vec![0..1, 2..3, 4..5], vec![8..9, 10..11]]);
    }

    #[test]
    fn setting_injections_after_a_delivery_delivers_layers_at_the_same_revision() {
        let fixture = Fixture::new("(a b)");
        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::Delivered(Revision::new(0))
        );
        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::UpToDate
        );
        assert!(delivered_layers(&fixture).is_empty());

        inject(&fixture.session);
        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::Delivered(Revision::new(0))
        );
        assert_eq!(delivered_layers(&fixture), fresh_layers(&fixture));
        assert!(!delivered_layers(&fixture).is_empty());
        // The text was not parsed again: one parse, the first.
        assert_eq!(fixture.olds(), [None]);
        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::UpToDate
        );
        assert_eq!(fixture.delivered(), [Revision::new(0), Revision::new(0)]);
    }

    #[test]
    fn injections_that_find_the_layers_delivered_deliver_nothing_new() {
        let fixture = Fixture::new("a b");
        fixture.session.parse_once(&fixture.syntax);
        // No list: the injections find no layer, as before them.
        inject(&fixture.session);

        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::UpToDate
        );
        assert_eq!(fixture.delivered(), [Revision::new(0)]);
        // And a wait for the revision is not held up by the injections.
        assert!(wait_for(&fixture.session, Revision::new(0), AT_ONCE).is_some());

        // A language set again with the same layers: nothing new either.
        let text = Fixture::new("(a) b");
        inject(&text.session);
        text.session.parse_once(&text.syntax);
        assert!(!delivered_layers(&text).is_empty());
        text.session
            .set_language("inner".to_owned(), inner_language());
        assert_eq!(text.session.parse_once(&text.syntax), Outcome::UpToDate);
        assert_eq!(text.delivered(), [Revision::new(0)]);
    }

    #[test]
    fn layers_after_edits_equal_a_fresh_rounds() {
        let fixture = Fixture::new("(a b) c");
        inject(&fixture.session);
        fixture.session.parse_once(&fixture.syntax);
        for (range, with) in [(7..7, " (d (e))"), (0..1, ""), (0..0, "((x)"), (3..9, "")] {
            let revision = fixture.replace(range, with);
            fixture.session.touch(revision);
            assert_eq!(
                fixture.session.parse_once(&fixture.syntax),
                Outcome::Delivered(revision)
            );
            assert_eq!(delivered_layers(&fixture), fresh_layers(&fixture));
        }
    }

    /// The fake's shipped highlights, with the injections of `injections()`,
    /// each span with the name of its face.
    fn fresh_injected(snapshot: &Snapshot) -> Vec<(Range<usize>, String)> {
        let highlighter = parens_highlighter();
        let injections = injections();
        let (faces, _) = crate::highlight::face_table(&highlighter, Some(&injections));
        crate::highlight::fresh(
            &Parens,
            &highlighter,
            Some(&injections),
            &mut ParensParser,
            snapshot,
        )
        .into_iter()
        .map(|span| (span.bytes, faces[span.face].clone()))
        .collect()
    }

    #[test]
    fn a_layers_spans_are_drawn_over_the_hosts_and_cut_to_its_ranges() {
        let fixture = Fixture::new("(a b) c");
        fixture.session.set_highlighter(parens_highlighter());
        inject(&fixture.session);
        fixture.session.parse_once(&fixture.syntax);
        let snapshot = lock(&fixture.text).snapshot();

        let drawn = highlighted(&fixture.syntax, &fixture.session, &snapshot).unwrap();
        let at = |range: Range<usize>, face: &str| (range, face.to_owned());
        assert_eq!(
            drawn,
            [
                // The host's, first.
                at(0..5, "syntax.list"),
                at(0..1, "syntax.punctuation.bracket"),
                at(1..2, "syntax.variable"),
                at(3..4, "syntax.variable"),
                at(4..5, "syntax.punctuation.bracket"),
                at(6..7, "syntax.variable"),
                // The layer's list, cut to its ranges: the atoms are not
                // its; then its parens.
                at(0..1, "inner.list"),
                at(2..3, "inner.list"),
                at(4..5, "inner.list"),
                at(0..1, "inner.paren"),
                at(4..5, "inner.paren"),
            ]
        );
        assert_eq!(drawn, fresh_injected(&snapshot));
        assert_eq!(
            fixture.session.highlights(&snapshot).unwrap().faces(),
            [
                "syntax.punctuation.bracket",
                "syntax.list",
                "syntax.variable",
                "syntax.constant",
                "syntax.error",
                "inner.list",
                "inner.paren"
            ]
        );
    }

    #[test]
    fn a_layers_spans_are_carried_through_a_patch_until_the_reparse() {
        let fixture = Fixture::new("(a b) c");
        fixture.session.set_highlighter(parens_highlighter());
        inject(&fixture.session);
        fixture.session.parse_once(&fixture.syntax);
        // `zz ` typed at the start, told and not parsed.
        let revision = fixture.replace(0..0, "zz ");
        fixture.session.touch(revision);
        let snapshot = lock(&fixture.text).snapshot();

        let carried = highlighted(&fixture.syntax, &fixture.session, &snapshot).unwrap();
        let layer: Vec<(Range<usize>, String)> = carried
            .iter()
            .filter(|(_, face)| face.starts_with("inner."))
            .cloned()
            .collect();
        let at = |range: Range<usize>, face: &str| (range, face.to_owned());
        assert_eq!(
            layer,
            [
                at(3..4, "inner.list"),
                at(5..6, "inner.list"),
                at(7..8, "inner.list"),
                at(3..4, "inner.paren"),
                at(7..8, "inner.paren"),
            ]
        );
        assert_ne!(carried, fresh_injected(&snapshot));

        fixture.session.parse_once(&fixture.syntax);
        assert_eq!(
            highlighted(&fixture.syntax, &fixture.session, &snapshot),
            Some(fresh_injected(&snapshot))
        );
    }

    #[test]
    fn a_layer_whose_language_is_gone_or_of_another_grammar_is_not_drawn() {
        let fixture = Fixture::new("(a b)");
        fixture.session.set_highlighter(parens_highlighter());
        inject(&fixture.session);
        fixture.session.parse_once(&fixture.syntax);
        let snapshot = lock(&fixture.text).snapshot();
        fixture.session.set_language(
            "inner".to_owned(),
            Language {
                grammar: GrammarName::new("another"),
                ..inner_language()
            },
        );

        let drawn = highlighted(&fixture.syntax, &fixture.session, &snapshot).unwrap();
        assert!(drawn.iter().all(|(_, face)| !face.starts_with("inner.")));
    }

    /// The kept captures of `kind` in `range` of `snapshot`, each as its
    /// capture's name and range.
    fn kept(
        fixture: &Fixture,
        kind: QueryKind,
        snapshot: &Snapshot,
        range: Range<usize>,
    ) -> Result<Vec<(String, Range<usize>)>, KeptRefusal> {
        let (names, captures) =
            fixture
                .session
                .kept_captures(&fixture.syntax, kind, snapshot, range)?;
        Ok(captures
            .iter()
            .map(|capture| (names[capture.capture as usize].clone(), capture.range()))
            .collect())
    }

    #[test]
    fn kept_captures_answer_the_kept_querys_captures_of_the_delivered_tree() {
        let fixture = Fixture::new("(a b) c");
        fixture
            .session
            .keep(QueryKind::TextObjects, parens_query("list @l\natom @a"));
        fixture
            .session
            .keep(QueryKind::Indents, parens_query("list @indent.begin"));
        fixture.session.parse_once(&fixture.syntax);
        let snapshot = lock(&fixture.text).snapshot();
        let at = |name: &str, range: Range<usize>| (name.to_owned(), range);

        assert_eq!(
            kept(&fixture, QueryKind::TextObjects, &snapshot, 2..4),
            Ok(vec![at("l", 0..5), at("a", 3..4)])
        );
        assert_eq!(
            kept(&fixture, QueryKind::Indents, &snapshot, 0..7),
            Ok(vec![at("indent.begin", 0..5)])
        );
        // A later query of a kind replaces the one before.
        fixture
            .session
            .keep(QueryKind::Indents, parens_query("atom @x"));
        assert_eq!(
            kept(&fixture, QueryKind::Indents, &snapshot, 5..7),
            Ok(vec![at("x", 6..7)])
        );
    }

    #[test]
    fn kept_captures_of_a_snapshot_not_yet_parsed_are_refused() {
        let fixture = Fixture::new("(a b)");
        fixture
            .session
            .keep(QueryKind::TextObjects, parens_query("atom @a"));
        fixture.session.parse_once(&fixture.syntax);
        let revision = fixture.replace(5..5, " c");
        fixture.session.touch(revision);
        let edited = lock(&fixture.text).snapshot();

        // The edit is told and not parsed: the tree delivered lacks it.
        assert_eq!(
            kept(&fixture, QueryKind::TextObjects, &edited, 0..7),
            Err(KeptRefusal::NotParsed)
        );
        fixture.session.parse_once(&fixture.syntax);
        assert_eq!(
            kept(&fixture, QueryKind::TextObjects, &edited, 0..7).map(|found| found.len()),
            Ok(3)
        );
    }

    #[test]
    fn the_refusals_are_checked_no_query_then_bad_range_then_not_parsed() {
        let fixture = Fixture::new("(é)");
        let snapshot = lock(&fixture.text).snapshot();

        assert_eq!(
            kept(&fixture, QueryKind::Indents, &snapshot, 2..3),
            Err(KeptRefusal::NoQuery)
        );
        fixture
            .session
            .keep(QueryKind::Indents, parens_query("list @indent.begin"));
        assert_eq!(
            kept(&fixture, QueryKind::Indents, &snapshot, 2..3),
            Err(KeptRefusal::BadRange)
        );
        assert_eq!(
            kept(&fixture, QueryKind::Indents, &snapshot, 0..4),
            Err(KeptRefusal::NotParsed)
        );
        fixture.session.parse_once(&fixture.syntax);
        assert_eq!(
            kept(&fixture, QueryKind::Indents, &snapshot, 0..4).map(|found| found.len()),
            Ok(1)
        );
        assert_eq!(
            kept(&fixture, QueryKind::TextObjects, &snapshot, 0..4),
            Err(KeptRefusal::NoQuery)
        );
    }

    #[test]
    fn a_kept_query_survives_its_handles_release() {
        let fixture = Fixture::new("(a)");
        let query = parens_query("atom @a");
        fixture.session.keep(QueryKind::TextObjects, query.clone());
        drop(query);
        fixture.session.parse_once(&fixture.syntax);
        let snapshot = lock(&fixture.text).snapshot();

        assert_eq!(
            kept(&fixture, QueryKind::TextObjects, &snapshot, 0..3),
            Ok(vec![("a".to_owned(), 1..2)])
        );
    }

    #[test]
    fn a_session_knows_its_grammar_and_a_delivered_text_is_the_snapshot_parsed() {
        let fixture = Fixture::new("(a)");
        fixture.session.parse_once(&fixture.syntax);

        assert_eq!(fixture.session.grammar().as_str(), GRAMMAR);
        let parsed = fixture.session.parsed().unwrap();
        assert_eq!(parsed.snapshot.to_string(), "(a)");
    }
}
