//! Grammar registrations as a service behind the completion queue: a
//! job's request to register a grammar from a native library, worked on
//! the syntax worker's thread and completed through the completion queue.
//!
//! The registry of grammars is state of the process's syntax service
//! ([`crate::syntax`]), held by its worker (`editor_syntax::worker`,
//! "Registrations"), so a registration is a request on the worker's queue,
//! answered before its next round. From the next phase on, answering one
//! is file I/O (a `dlopen`), and it waits behind any round in progress, so
//! the editor thread never waits for it: in Lean it is a request a job
//! awaits (`JobRequest.grammar`, `lean/Editor/Job.lean`), in the shape of
//! the other services here (the crate docs, "Services and completions").
//!
//! The rules:
//!
//! - **A start returns at once.** [`editor_ffi_grammars_start`] queues the
//!   registration on the syntax worker and returns; the worker answers it
//!   on its own thread, in order with the other registrations and before
//!   its next round. Its answer is kept under the request's id, and the
//!   request is completed: one
//!   [`EventKind::Completion`](crate::events::EventKind::Completion) from
//!   the library source [`crate::syntax::SERVICE`], whose code is the id.
//!   The caller then takes the answer ([`editor_ffi_grammars_take`]), once.
//! - **An id in use is refused**: one waiting, one cancelled whose
//!   registration has not yet been answered, and one whose answer has not
//!   been taken.
//! - **Cancelling withdraws the wait.** Its answer is dropped and never
//!   completed. A registration already queued is still worked: it is a
//!   change to the service's state the caller asked for, and a later
//!   registration of the same name overrides it. A kept answer is dropped.
//! - **A flush is a barrier** ([`editor_ffi_grammars_flush`]): completed
//!   once every registration started before it has been answered, behind
//!   their completions. It keeps no answer, and a cancel withdraws it while
//!   it waits.
//! - **The loop's end.** A registration still queued when the worker's loop
//!   ends is completed and taken as [`GrammarStatus::Dropped`].
//!
//! Which name a source registers, the default policy, the override and the
//! refusals are `editor-syntax`'s (`editor_syntax::registry`, the port's
//! `Syntax::register`); this module decides only what a *service* decides:
//! the waits, the statuses and how a source and a name cross.
//!
//! # How a source and a name cross
//!
//! A source crosses as its library's path and its symbol, each a string,
//! and its policy as a `u8` tag ([`policy_of`]): 0 none declared, 1
//! incremental, 2 whole. A take returns a [`GrammarStatus`] as its number,
//! and on [`GrammarStatus::Registered`] lends the registered name into a
//! [`RawText`], as a shipped query's source is lent.
//!
//! # The C functions
//!
//! | Function | Does |
//! |---|---|
//! | [`editor_ffi_grammars_start`] | Queues a registration under an id. False, starting nothing, for an id in use, an unknown policy tag, or a worker that cannot start |
//! | [`editor_ffi_grammars_take`] | Hands over the answer, once: a [`GrammarStatus`], and the name lent into a [`RawText`] when registered |
//! | [`editor_ffi_grammars_cancel`] | Withdraws a wait, and says whether there was anything to withdraw |
//! | [`editor_ffi_grammars_flush`] | Asks for an id to be completed once every registration started before it is answered; keeps no answer |
//! | [`editor_ffi_grammars_pending`] | Waits not completed, and answers not taken |
//!
//! None of them waits: each is called on a job's thread.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, LazyLock, Mutex, MutexGuard, PoisonError};

use editor_syntax::worker::Answer;
use editor_syntax::{
    GrammarName, GrammarSource, Handle, RegistrationRefusal, ReparsePolicy, Syntax,
};

use crate::document::RawText;
use crate::{events, syntax, text};

/// An answer kept for its taker.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Taken {
    /// The grammar is registered under this name.
    Registered(GrammarName),
    /// The registration was refused.
    Refused(RegistrationRefusal),
    /// The worker's loop ended before it answered.
    Dropped,
}

impl Taken {
    /// The answer as it crosses.
    pub fn status(&self) -> GrammarStatus {
        match self {
            Self::Registered(_) => GrammarStatus::Registered,
            Self::Refused(refusal) => GrammarStatus::from(*refusal),
            Self::Dropped => GrammarStatus::Dropped,
        }
    }
}

/// How a registration ended, as it crosses the boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GrammarStatus {
    /// The grammar is registered; the name is lent beside it.
    Registered = 0,
    /// No file is at the library's path.
    NotFound = 1,
    /// The file is not a library this platform can open.
    NotLoadable = 2,
    /// The grammar is of an ABI the parsing library does not speak.
    UnsupportedAbi = 3,
    /// The library exports no such symbol.
    MissingSymbol = 4,
    /// The syntax loads no grammar at run time.
    Unsupported = 5,
    /// The service keeps no answer for the id: none started, not yet
    /// answered, withdrawn, or taken already.
    NoAnswer = 6,
    /// The worker's loop ended before it answered.
    Dropped = 7,
}

impl From<RegistrationRefusal> for GrammarStatus {
    /// Each refusal crosses as a status of its own, so this matches every
    /// variant: a new refusal is a new status, which Lean's binding then
    /// reads (`Ffi.grammarsTake`).
    fn from(refusal: RegistrationRefusal) -> Self {
        match refusal {
            RegistrationRefusal::NotFound => Self::NotFound,
            RegistrationRefusal::NotLoadable => Self::NotLoadable,
            RegistrationRefusal::UnsupportedAbi => Self::UnsupportedAbi,
            RegistrationRefusal::MissingSymbol => Self::MissingSymbol,
            RegistrationRefusal::Unsupported => Self::Unsupported,
        }
    }
}

/// The policy a tag names: `Some(None)` for 0, none declared;
/// `Some(Some(..))` for 1, incremental, and 2, whole; `None` for any other.
pub const fn policy_of(tag: u8) -> Option<Option<ReparsePolicy>> {
    match tag {
        0 => Some(None),
        1 => Some(Some(ReparsePolicy::Incremental)),
        2 => Some(Some(ReparsePolicy::Whole)),
        _ => None,
    }
}

/// The source of the grammar `symbol` in the library at `library`,
/// declaring `policy`.
pub fn source_of(library: &str, symbol: &str, policy: Option<ReparsePolicy>) -> GrammarSource {
    GrammarSource {
        library: PathBuf::from(library),
        symbol: symbol.to_owned(),
        policy,
    }
}

/// Where a request's id stands.
enum Wait {
    /// A registration queued, not yet answered.
    Waiting,
    /// A flush queued, not yet reached.
    Flushing,
    /// A registration or a flush whose wait was withdrawn, not yet reached:
    /// its answer is dropped.
    Withdrawn,
    /// An answer kept, not yet taken.
    Answered(Taken),
}

/// The grammar registrations' waits, by id, and how a wait is completed.
pub struct Grammars {
    /// Each id in use, with where it stands.
    waits: Arc<Mutex<BTreeMap<u64, Wait>>>,
    /// Completes a wait: for the process's instance, a completion event on
    /// the completion queue; for a unit test, a recorder.
    complete: Arc<dyn Fn(u64) + Send + Sync>,
}

/// The waits, locked. No code runs under the lock, so a poisoned one still
/// guards a consistent table.
fn lock(waits: &Mutex<BTreeMap<u64, Wait>>) -> MutexGuard<'_, BTreeMap<u64, Wait>> {
    waits.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Grammars {
    /// A service with no waits, which completes each with `complete`.
    pub fn new(complete: impl Fn(u64) + Send + Sync + 'static) -> Self {
        Self {
            waits: Arc::new(Mutex::new(BTreeMap::new())),
            complete: Arc::new(complete),
        }
    }

    /// Queues the registration of `source` on the worker `handle` reaches,
    /// as the wait `id`, and returns whether it was accepted. It returns at
    /// once. An id in use is refused.
    pub fn start<S: Syntax>(&self, handle: &Handle<S>, id: u64, source: GrammarSource) -> bool {
        if !self.claim(id, Wait::Waiting) {
            return false;
        }
        let waits = self.waits.clone();
        let complete = self.complete.clone();
        handle.register(
            source,
            Box::new(move |answer: Answer| {
                let taken = match answer {
                    Some(Ok(name)) => Taken::Registered(name),
                    Some(Err(refusal)) => Taken::Refused(refusal),
                    None => Taken::Dropped,
                };
                let mut table = lock(&waits);
                // A withdrawn wait's answer is dropped, and its id is free.
                if let Some(Wait::Waiting) = table.remove(&id) {
                    table.insert(id, Wait::Answered(taken));
                    drop(table);
                    complete(id);
                }
            }),
        );
        true
    }

    /// Asks for the wait `id` to be completed once every registration
    /// started before this call has been answered, and returns whether it
    /// was accepted. It returns at once, and keeps no answer. An id in use
    /// is refused.
    pub fn flush<S: Syntax>(&self, handle: &Handle<S>, id: u64) -> bool {
        if !self.claim(id, Wait::Flushing) {
            return false;
        }
        let waits = self.waits.clone();
        let complete = self.complete.clone();
        handle.flush_registrations(Box::new(move || {
            let reached = matches!(lock(&waits).remove(&id), Some(Wait::Flushing));
            if reached {
                complete(id);
            }
        }));
        true
    }

    /// Puts `id` in the table as `wait`, unless it is in use.
    fn claim(&self, id: u64, wait: Wait) -> bool {
        let mut table = lock(&self.waits);
        if table.contains_key(&id) {
            return false;
        }
        table.insert(id, wait);
        true
    }

    /// Hands over the answer of the wait `id`, once. `None` when it keeps
    /// none.
    pub fn take(&self, id: u64) -> Option<Taken> {
        let mut table = lock(&self.waits);
        match table.remove(&id)? {
            Wait::Answered(taken) => Some(taken),
            other => {
                table.insert(id, other);
                None
            }
        }
    }

    /// Withdraws the wait `id`, and returns whether there was anything to
    /// withdraw: its answer is dropped and never completed, and a kept
    /// answer is dropped. A registration already queued is still worked.
    /// Safe for any id.
    pub fn cancel(&self, id: u64) -> bool {
        let mut table = lock(&self.waits);
        match table.get(&id) {
            Some(Wait::Waiting | Wait::Flushing) => {
                table.insert(id, Wait::Withdrawn);
                true
            }
            Some(Wait::Answered(_)) => {
                table.remove(&id);
                true
            }
            Some(Wait::Withdrawn) | None => false,
        }
    }

    /// How many waits are not completed, withdrawn ones still queued among
    /// them, and how many answers are not taken, together.
    pub fn pending(&self) -> usize {
        lock(&self.waits).len()
    }
}

/// The process's grammar registrations, completed on the completion queue
/// from the syntax service's source.
fn grammars() -> &'static Grammars {
    /// The one service.
    static GRAMMARS: LazyLock<Grammars> = LazyLock::new(|| {
        Grammars::new(|id| {
            events::complete(syntax::SERVICE, id);
        })
    });
    &GRAMMARS
}

/// Asks the process's syntax service to register the grammar the symbol
/// spelled by the `symbol_len` bytes at `symbol` hands out, in the library
/// whose path is the `library_len` bytes at `library`, with the policy the
/// tag `policy` names ([`policy_of`]), as the request `id`, and returns
/// whether it was accepted. It returns at once and never blocks; the
/// registration is answered on the syntax worker's thread, and the request
/// is completed from [`crate::syntax::SERVICE`] with the code `id`. Its
/// answer is then taken with [`editor_ffi_grammars_take`].
///
/// Returns false, starting nothing, for an id in use, an unknown policy
/// tag, or a worker whose thread cannot start.
///
/// # Safety
///
/// `library` points to `library_len` readable bytes, and `symbol` to
/// `symbol_len`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_grammars_start(
    id: u64,
    library: *const u8,
    library_len: usize,
    symbol: *const u8,
    symbol_len: usize,
    policy: u8,
) -> bool {
    let Some(policy) = policy_of(policy) else {
        return false;
    };
    // SAFETY: the caller guarantees both pointers and lengths.
    let (library, symbol) = unsafe {
        (
            text::borrow(library, library_len),
            text::borrow(symbol, symbol_len),
        )
    };
    let Some(handle) = syntax::syntaxes().handle() else {
        return false;
    };
    grammars().start(&handle, id, source_of(&library, &symbol, policy))
}

/// Hands over the answer of the registration `id`, once, and returns its
/// [`GrammarStatus`] as its number: on [`GrammarStatus::Registered`] the
/// name is lent into `out`, which the caller hands back with
/// `editor_ffi_text_free`; on any other status `out` is untouched.
///
/// # Safety
///
/// `out` points to a writable [`RawText`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_grammars_take(id: u64, out: *mut RawText) -> u64 {
    let Some(taken) = grammars().take(id) else {
        return GrammarStatus::NoAnswer as u64;
    };
    if let Taken::Registered(name) = &taken {
        let (text, text_len) = text::lend(name.as_str().to_owned());
        // SAFETY: the caller guarantees `out` is writable.
        unsafe { out.write(RawText { text, text_len }) };
    }
    taken.status() as u64
}

/// Withdraws the registration wait `id`, and returns whether there was
/// anything to withdraw. A registration already queued is still worked.
/// Safe for an id that is unknown.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_grammars_cancel(id: u64) -> bool {
    grammars().cancel(id)
}

/// Asks for the request `id` to be completed once every registration
/// started before this call has been answered, and returns whether it was
/// accepted. It returns at once and keeps no answer. False, starting
/// nothing, for an id in use or a worker whose thread cannot start.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_grammars_flush(id: u64) -> bool {
    let Some(handle) = syntax::syntaxes().handle() else {
        return false;
    };
    grammars().flush(&handle, id)
}

/// How many registration waits are not completed, and how many answers
/// are not taken, together. A readout for tests.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_grammars_pending() -> u64 {
    grammars().pending() as u64
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use editor_syntax::clock::ManualClock;
    use editor_syntax::fake::Parens;
    use editor_syntax::fake::libraries::{self, Libraries};
    use editor_syntax::{
        GrammarName, GrammarSource, RegistrationRefusal, ReparsePolicy, Syntax, Worker,
    };

    use super::*;

    /// A worker over `syntax`, stepped by the test.
    fn worker_of<S: Syntax>(syntax: S) -> Worker<S> {
        worker_over(Arc::new(syntax))
    }

    /// A worker over `syntax`, which the test holds too.
    fn worker_over<S: Syntax>(syntax: Arc<S>) -> Worker<S> {
        Worker::new(
            syntax,
            Arc::new(ManualClock::new()),
            Duration::from_millis(500),
        )
    }

    /// A service whose completions are recorded, and the ids it completed.
    fn recorded() -> (Grammars, Arc<Mutex<Vec<u64>>>) {
        let completed = Arc::new(Mutex::new(Vec::new()));
        let service = Grammars::new({
            let completed = completed.clone();
            move |id| completed.lock().unwrap().push(id)
        });
        (service, completed)
    }

    #[test]
    fn a_registration_started_returns_at_once_and_is_completed_once_the_worker_steps_and_taken_once()
     {
        let worker = worker_of(Libraries::new(libraries::table()));
        let (service, completed) = recorded();

        assert!(service.start(&worker.handle(), 1, libraries::corpus().new));
        assert_eq!(*completed.lock().unwrap(), [0_u64; 0]);
        assert_eq!(service.take(1), None);
        worker.step();

        assert_eq!(*completed.lock().unwrap(), [1]);
        assert_eq!(
            service.take(1),
            Some(Taken::Registered(GrammarName::new("brackets")))
        );
        assert_eq!(service.take(1), None);
    }

    #[test]
    fn each_refusal_is_kept_and_taken_as_its_status() {
        let worker = worker_of(Libraries::new(libraries::table()));
        let (service, _) = recorded();
        let corpus = libraries::corpus();
        let handle = worker.handle();
        service.start(&handle, 1, corpus.not_found);
        service.start(&handle, 2, corpus.not_loadable);
        service.start(&handle, 3, corpus.unsupported_abi);
        service.start(&handle, 4, corpus.missing_symbol);
        let parens = worker_of(Parens);
        service.start(&parens.handle(), 5, libraries::corpus().new);
        worker.step();
        parens.step();

        let statuses = [1, 2, 3, 4, 5].map(|id| service.take(id).map(|taken| taken.status()));

        assert_eq!(
            statuses,
            [
                Some(GrammarStatus::NotFound),
                Some(GrammarStatus::NotLoadable),
                Some(GrammarStatus::UnsupportedAbi),
                Some(GrammarStatus::MissingSymbol),
                Some(GrammarStatus::Unsupported),
            ]
        );
    }

    #[test]
    fn an_id_in_use_is_refused_at_start() {
        let worker = worker_of(Libraries::new(libraries::table()));
        let (service, _) = recorded();
        let handle = worker.handle();
        assert!(service.start(&handle, 7, libraries::corpus().new));

        assert!(!service.start(&handle, 7, libraries::corpus().overriding));
        assert!(!service.flush(&handle, 7));
        worker.step();
        assert!(!service.start(&handle, 7, libraries::corpus().overriding));
        assert!(service.take(7).is_some());
        assert!(service.start(&handle, 7, libraries::corpus().overriding));
    }

    #[test]
    fn a_cancelled_registration_is_worked_but_neither_completed_nor_kept() {
        let syntax = Arc::new(Libraries::new(libraries::table()));
        let worker = worker_over(syntax.clone());
        let (service, completed) = recorded();
        service.start(&worker.handle(), 3, libraries::corpus().new);

        assert!(service.cancel(3));
        assert!(!service.cancel(3));
        worker.step();

        assert!(syntax.grammars().contains(&GrammarName::new("brackets")));
        assert_eq!(*completed.lock().unwrap(), [0_u64; 0]);
        assert_eq!(service.take(3), None);
        assert_eq!(service.pending(), 0);
    }

    #[test]
    fn a_flush_is_completed_behind_every_registration_started_before_it() {
        let worker = worker_of(Libraries::new(libraries::table()));
        let (service, completed) = recorded();
        let handle = worker.handle();
        service.start(&handle, 1, libraries::corpus().new);
        assert!(service.flush(&handle, 2));
        service.start(&handle, 3, libraries::corpus().not_found);

        assert_eq!(*completed.lock().unwrap(), [0_u64; 0]);
        worker.step();

        assert_eq!(*completed.lock().unwrap(), [1, 2, 3]);
        // It keeps no answer.
        assert_eq!(service.take(2), None);
    }

    #[test]
    fn a_registration_the_loop_dropped_is_completed_and_taken_as_dropped() {
        let worker = worker_of(Libraries::new(libraries::table()));
        let (service, completed) = recorded();
        let handle = worker.handle();
        service.start(&handle, 4, libraries::corpus().new);
        handle.stop();

        worker.run();

        assert_eq!(*completed.lock().unwrap(), [4]);
        assert_eq!(service.take(4), Some(Taken::Dropped));
        assert_eq!(Taken::Dropped.status(), GrammarStatus::Dropped);
    }

    #[test]
    fn pending_counts_waits_not_completed_and_answers_not_taken() {
        let worker = worker_of(Libraries::new(libraries::table()));
        let (service, _) = recorded();
        let handle = worker.handle();
        service.start(&handle, 1, libraries::corpus().new);
        service.flush(&handle, 2);

        assert_eq!(service.pending(), 2);
        worker.step();
        assert_eq!(service.pending(), 1);
        service.take(1);
        assert_eq!(service.pending(), 0);
    }

    #[test]
    fn each_registration_refusal_crosses_as_a_status_of_its_own() {
        let statuses = [
            GrammarStatus::Registered,
            GrammarStatus::NotFound,
            GrammarStatus::NotLoadable,
            GrammarStatus::UnsupportedAbi,
            GrammarStatus::MissingSymbol,
            GrammarStatus::Unsupported,
            GrammarStatus::NoAnswer,
            GrammarStatus::Dropped,
        ];
        assert_eq!(
            statuses.map(|status| status as u64),
            [0, 1, 2, 3, 4, 5, 6, 7]
        );
        assert_eq!(
            [
                RegistrationRefusal::NotFound,
                RegistrationRefusal::NotLoadable,
                RegistrationRefusal::UnsupportedAbi,
                RegistrationRefusal::MissingSymbol,
                RegistrationRefusal::Unsupported,
            ]
            .map(GrammarStatus::from),
            [
                GrammarStatus::NotFound,
                GrammarStatus::NotLoadable,
                GrammarStatus::UnsupportedAbi,
                GrammarStatus::MissingSymbol,
                GrammarStatus::Unsupported,
            ]
        );
    }

    #[test]
    fn each_policy_tag_names_a_policy_and_another_tag_none() {
        assert_eq!(
            [0, 1, 2, 3].map(policy_of),
            [
                Some(None),
                Some(Some(ReparsePolicy::Incremental)),
                Some(Some(ReparsePolicy::Whole)),
                None
            ]
        );
    }

    #[test]
    fn a_source_crosses_as_its_library_and_symbol() {
        assert_eq!(
            source_of("/lib/x.so", "tree_sitter_x", Some(ReparsePolicy::Whole)),
            GrammarSource {
                library: PathBuf::from("/lib/x.so"),
                symbol: "tree_sitter_x".to_owned(),
                policy: Some(ReparsePolicy::Whole),
            }
        );
    }
}
