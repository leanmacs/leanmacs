//! Typed time bounds: a bound on a wait is a value that says which kind it
//! is (AGENTS.md, "Deterministic concurrency in tests";
//! docs/design/concurrency.md, "What a test may still wait on time for").
//!
//! - **[`HangGuard::on`]**: a guard against a hang, naming the event its
//!   wait ends on. Running out is a hang, reported as one
//!   ([`HangGuard::hang`]), never a result.
//! - **[`HangGuard::held`]**: a hang guard run out on purpose, naming what
//!   is held for good. Running out is the expected outcome.
//! - **[`RealTime::under`]**: real time under test, naming the timing that
//!   is the subject.
//!
//! Their fields are private and neither converts from a [`Duration`], so
//! a wait that takes a [`HangGuard`] takes nothing else: a number, a
//! `Duration` or a struct literal is refused at compile time, and the kind
//! of a bound is a type, not a comment.
//!
//! ```compile_fail
//! // A wait that takes a guard takes no `Duration`.
//! let (_sender, receiver) = std::sync::mpsc::channel::<()>();
//! let _ = editor_wait::recv(&receiver, std::time::Duration::from_secs(1));
//! ```
//!
//! ```compile_fail
//! // Nor a guard made outside this crate by its fields.
//! let _ = editor_wait::HangGuard {
//!     what: "a reply",
//!     bound: std::time::Duration::from_secs(1),
//!     held_for_good: false,
//! };
//! ```
//!
//! ```compile_fail
//! // Nor real time made by its fields.
//! let _ = editor_wait::RealTime {
//!     timing: "the debounce",
//!     span: std::time::Duration::from_millis(1),
//! };
//! ```
//!
//! Every constructor is a `const fn`, so a test's guard is a constant:
//!
//! ```
//! use std::time::Duration;
//! use editor_wait::HangGuard;
//!
//! const DEADLINE: HangGuard = HangGuard::on("a reply", Duration::from_secs(5));
//! let (sender, receiver) = std::sync::mpsc::channel();
//! sender.send(7).unwrap();
//! assert_eq!(editor_wait::recv(&receiver, DEADLINE), Ok(7));
//! ```
//!
//! The crate owns the bounded primitives a test waits with: a channel's
//! receive ([`recv`]), a Condvar's wait while a condition holds
//! ([`wait_while`]), a guard's deadline and what is left of it
//! ([`HangGuard::deadline`], [`HangGuard::start`], [`Deadline::rest`]),
//! real time's sleep ([`RealTime::sleep`]) and real time measured from a
//! start ([`Stopwatch`]). `mise run lint` bans std's raw
//! timed primitives everywhere else (the root `clippy.toml` and each
//! crate's), so these wrappers are where a time bound meets the clock.
//!
//! # Why our own code
//!
//! AGENTS.md ("Prefer an existing library, behind a port") asks for a
//! library where one exists. None does this: the crates that bound a wait
//! (`crossbeam-channel`'s `recv_timeout`, `parking_lot`'s `wait_for`,
//! `tokio::time::timeout`) all take a bare `Duration`, which is exactly
//! what this crate exists to refuse, and none names the event a bound
//! guards or tells a hang from a bound run out on purpose. What is here
//! is a few lines over std's own primitives, with no dependency.

use std::fmt;
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::sync::{Condvar, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

/// A bound on a wait that is a guard against a hang. Built by
/// [`on`](Self::on) or [`held`](Self::held); nothing else makes one.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct HangGuard {
    /// The event the wait ends on, or what is held for good.
    what: &'static str,
    /// How long the wait may last.
    bound: Duration,
    /// Whether running out is the expected outcome: what the wait is on is
    /// held for good ([`held`](Self::held)).
    held_for_good: bool,
}

impl HangGuard {
    /// A hang guard on a wait that ends on `event`, of `bound`. Only a
    /// hang reaches it: a caller that runs out reports
    /// [`hang`](Self::hang). A bound past what the clock can count, such
    /// as [`Duration::MAX`], is no bound.
    pub const fn on(event: &'static str, bound: Duration) -> Self {
        Self {
            what: event,
            bound,
            held_for_good: false,
        }
    }

    /// A hang guard run out on purpose: `what` is held for good, and the
    /// wait on it runs out after `bound`.
    pub const fn held(what: &'static str, bound: Duration) -> Self {
        Self {
            what,
            bound,
            held_for_good: true,
        }
    }

    /// The event the wait ends on; for a guard [`held`](Self::held) for
    /// good, what is held. The same as [`what`](Self::what).
    pub const fn event(&self) -> &'static str {
        self.what
    }

    /// The event the wait ends on, or what is held for good.
    pub const fn what(&self) -> &'static str {
        self.what
    }

    /// How long the wait may last.
    pub const fn bound(&self) -> Duration {
        self.bound
    }

    /// Whether running out is the expected outcome
    /// ([`held`](Self::held)).
    pub const fn held_for_good(&self) -> bool {
        self.held_for_good
    }

    /// The same guard with another bound: for a bound computed from
    /// another (scaled, or what is left of it), which still names its
    /// event.
    pub const fn with_bound(self, bound: Duration) -> Self {
        Self { bound, ..self }
    }

    /// What running out of the guard means, for a message: a hang, naming
    /// the event and the bound, or, for a guard held for good, that it ran
    /// out as meant.
    pub fn hang(&self) -> String {
        let ms = self.bound.as_millis();
        if self.held_for_good {
            format!(
                "run out on purpose: {} is held for good, after {ms} ms",
                self.what
            )
        } else {
            format!("a hang: {} had not come within {ms} ms", self.what)
        }
    }

    /// When the guard runs out, if it is started now: `None` for a bound
    /// past what the clock can count, which is no bound.
    pub fn deadline(&self) -> Option<Instant> {
        self.start().at()
    }

    /// The guard's deadline, started now.
    pub fn start(&self) -> Deadline {
        Deadline {
            guard: *self,
            ends: now().checked_add(self.bound),
        }
    }
}

impl fmt::Display for HangGuard {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.hang())
    }
}

/// A hang guard's deadline: when its bound runs out, on the monotonic
/// clock, from when it was [started](HangGuard::start). A wait made of
/// several waits, each bounded by what is left, takes its bounds from one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Deadline {
    /// The guard it is the deadline of.
    guard: HangGuard,
    /// When it runs out: `None` for a bound past what the clock can count.
    ends: Option<Instant>,
}

impl Deadline {
    /// The guard it is the deadline of, with its whole bound.
    pub const fn guard(&self) -> HangGuard {
        self.guard
    }

    /// When it runs out: `None` for no bound.
    pub const fn at(&self) -> Option<Instant> {
        self.ends
    }

    /// Whether it has passed. A deadline of no bound never passes.
    pub fn expired(&self) -> bool {
        self.ends.is_some_and(|ends| now() >= ends)
    }

    /// What is left of it, as a guard on the same event: zero once it has
    /// passed, and the whole bound for no bound.
    pub fn rest(&self) -> HangGuard {
        match self.ends {
            None => self.guard,
            Some(ends) => self.guard.with_bound(ends.saturating_duration_since(now())),
        }
    }
}

/// A span of real time that is itself under test. Built by
/// [`under`](Self::under); nothing else makes one.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct RealTime {
    /// The timing that is the subject.
    timing: &'static str,
    /// How long.
    span: Duration,
}

impl RealTime {
    /// Real time under test: `span` of `timing`, the timing that is the
    /// subject (a lower bound, which load only makes pass more surely, or a
    /// real clock's deadline being waited out).
    pub const fn under(timing: &'static str, span: Duration) -> Self {
        Self { timing, span }
    }

    /// The timing that is the subject.
    pub const fn timing(&self) -> &'static str {
        self.timing
    }

    /// How long.
    pub const fn span(&self) -> Duration {
        self.span
    }

    /// Sleeps for the span: the one sleep of the tests.
    pub fn sleep(self) {
        #[expect(
            clippy::disallowed_methods,
            reason = "the one sleep of the tests: the span is real time under test, named by `timing`"
        )]
        std::thread::sleep(self.span);
    }
}

/// Real time measured from a start, which is itself under test: a clock
/// that moves by itself for a test of a real clock's deadline, or a timing
/// that is the subject, measured and printed or held to a lower bound.
/// Built by [`start`](Self::start); nothing else makes one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stopwatch {
    /// The timing that is the subject.
    timing: &'static str,
    /// When it started, on the monotonic clock.
    started: Instant,
}

impl Stopwatch {
    /// A stopwatch of `timing`, the timing that is the subject, started
    /// now.
    pub fn start(timing: &'static str) -> Self {
        Self {
            timing,
            started: now(),
        }
    }

    /// The timing that is the subject.
    pub const fn timing(&self) -> &'static str {
        self.timing
    }

    /// The real time since it started.
    pub fn elapsed(&self) -> Duration {
        self.started.elapsed()
    }
}

/// Why [`recv`] gave no value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Unreceived {
    /// The guard ran out first: a hang, or for a guard held for good, the
    /// expected outcome.
    Hang(HangGuard),
    /// Every sender was dropped with nothing left to receive.
    Disconnected,
}

impl Unreceived {
    /// Whether the guard ran out.
    pub const fn is_hang(&self) -> bool {
        matches!(self, Self::Hang(_))
    }
}

impl fmt::Display for Unreceived {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Hang(guard) => formatter.write_str(&guard.hang()),
            Self::Disconnected => formatter.write_str("every sender was dropped with nothing sent"),
        }
    }
}

impl std::error::Error for Unreceived {}

/// A value from `receiver`, or why there is none: the guard ran out
/// first, or every sender was dropped. A guard past what the clock can
/// count is no bound: the receive then waits for a value or a disconnect.
pub fn recv<T>(receiver: &Receiver<T>, guard: HangGuard) -> Result<T, Unreceived> {
    if guard.deadline().is_none() {
        return receiver.recv().map_err(|_| Unreceived::Disconnected);
    }
    #[expect(
        clippy::disallowed_methods,
        reason = "the one bounded receive: `guard` names the event it ends on"
    )]
    receiver
        .recv_timeout(guard.bound())
        .map_err(|error| match error {
            RecvTimeoutError::Timeout => Unreceived::Hang(guard),
            RecvTimeoutError::Disconnected => Unreceived::Disconnected,
        })
}

/// Waits on `condvar` while `condition` holds of what `lock` guards, and
/// says whether it ended: false only once `guard` has run out with the
/// condition still holding. `condition` is read under the lock, first at
/// once and again at each wake-up. A guard past what the clock can count
/// is no bound. A poisoned lock is taken as it is: every lock waited on
/// here guards a state that stays consistent while held.
pub fn wait_while<'a, T, F>(
    condvar: &Condvar,
    lock: MutexGuard<'a, T>,
    guard: HangGuard,
    condition: F,
) -> (MutexGuard<'a, T>, bool)
where
    F: FnMut(&mut T) -> bool,
{
    if guard.deadline().is_none() {
        let lock = condvar
            .wait_while(lock, condition)
            .unwrap_or_else(PoisonError::into_inner);
        return (lock, true);
    }
    #[expect(
        clippy::disallowed_methods,
        reason = "the one bounded Condvar wait: `guard` names the event it ends on"
    )]
    let (lock, waited) = condvar
        .wait_timeout_while(lock, guard.bound(), condition)
        .unwrap_or_else(PoisonError::into_inner);
    (lock, !waited.timed_out())
}

/// The monotonic clock, read for a deadline or a stopwatch.
fn now() -> Instant {
    #[expect(
        clippy::disallowed_methods,
        reason = "the one read of the clock: a guard's deadline and a stopwatch's start"
    )]
    Instant::now()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::sync::{Arc, Mutex};
    use std::thread;

    /// hang guard: a value sent, or a flag set, by another thread of the
    /// test.
    const DEADLINE: HangGuard = HangGuard::on("the other thread's step", Duration::from_secs(60));

    /// No bound: a bound past what the clock can count.
    const NO_BOUND: HangGuard = HangGuard::on("a step that must come", Duration::MAX);

    #[test]
    fn a_guard_names_its_event_and_bound_and_whether_it_is_held_for_good() {
        const ON: HangGuard = HangGuard::on("a reply", Duration::from_millis(250));
        const HELD: HangGuard = HangGuard::held("the lock", Duration::from_millis(40));
        assert_eq!(ON.event(), "a reply");
        assert_eq!(ON.what(), "a reply");
        assert_eq!(ON.bound(), Duration::from_millis(250));
        assert!(!ON.held_for_good());
        assert_eq!(HELD.what(), "the lock");
        assert!(HELD.held_for_good());
        assert_eq!(
            ON.with_bound(Duration::ZERO),
            HangGuard::on("a reply", Duration::ZERO)
        );
    }

    #[test]
    fn a_hang_says_what_had_not_come_and_a_held_guard_that_it_ran_out_as_meant() {
        assert_eq!(
            HangGuard::on("a reply", Duration::from_millis(250)).hang(),
            "a hang: a reply had not come within 250 ms"
        );
        assert_eq!(
            HangGuard::held("the lock", Duration::from_millis(40)).to_string(),
            "run out on purpose: the lock is held for good, after 40 ms"
        );
    }

    #[test]
    fn a_bound_past_what_the_clock_can_count_has_no_deadline() {
        assert_eq!(NO_BOUND.deadline(), None);
        assert!(DEADLINE.deadline().is_some());
        assert!(HangGuard::on("a step", Duration::ZERO).deadline().is_some());
    }

    #[test]
    fn a_deadline_of_no_time_has_passed_and_one_of_no_bound_never_does() {
        let passed = HangGuard::on("a step", Duration::ZERO).start();
        assert!(passed.expired());
        assert_eq!(passed.rest().bound(), Duration::ZERO);
        assert_eq!(passed.rest().what(), "a step");

        let unbounded = NO_BOUND.start();
        assert!(!unbounded.expired());
        assert_eq!(unbounded.rest(), NO_BOUND);
        assert_eq!(unbounded.at(), None);

        let started = DEADLINE.start();
        assert!(!started.expired());
        assert!(started.rest().bound() <= DEADLINE.bound());
        assert_eq!(started.guard(), DEADLINE);
    }

    #[test]
    fn recv_gives_a_value_sent_before_or_while_it_waits() {
        let (sender, receiver) = mpsc::channel();
        sender.send(1).unwrap();
        assert_eq!(recv(&receiver, DEADLINE), Ok(1));
        let sending = thread::spawn(move || sender.send(2).unwrap());
        assert_eq!(recv(&receiver, DEADLINE), Ok(2));
        sending.join().unwrap();
    }

    #[test]
    fn recv_says_the_guard_ran_out_with_nothing_sent() {
        let (_sender, receiver) = mpsc::channel::<u8>();
        let guard = HangGuard::held("the sender, which sends nothing", Duration::ZERO);
        let missed = recv(&receiver, guard);
        assert_eq!(missed, Err(Unreceived::Hang(guard)));
        assert!(missed.is_err_and(|missed| missed.is_hang()));
    }

    #[test]
    fn recv_says_every_sender_was_dropped_bounded_or_not() {
        let (sender, receiver) = mpsc::channel::<u8>();
        drop(sender);
        assert_eq!(recv(&receiver, DEADLINE), Err(Unreceived::Disconnected));
        assert_eq!(recv(&receiver, NO_BOUND), Err(Unreceived::Disconnected));
    }

    #[test]
    fn recv_with_no_bound_waits_for_the_value() {
        let (sender, receiver) = mpsc::channel();
        let sending = thread::spawn(move || sender.send(3).unwrap());
        assert_eq!(recv(&receiver, NO_BOUND), Ok(3));
        sending.join().unwrap();
    }

    /// A flag another thread sets, notifying the Condvar as it does.
    fn set_on_another_thread(flag: &Arc<(Mutex<bool>, Condvar)>) -> thread::JoinHandle<()> {
        let flag = Arc::clone(flag);
        thread::spawn(move || {
            *flag.0.lock().unwrap() = true;
            flag.1.notify_all();
        })
    }

    #[test]
    fn wait_while_ends_once_the_condition_does() {
        for guard in [DEADLINE, NO_BOUND] {
            let flag = Arc::new((Mutex::new(false), Condvar::new()));
            let setting = set_on_another_thread(&flag);
            let (set, ended) = wait_while(&flag.1, flag.0.lock().unwrap(), guard, |set| !*set);
            assert!(ended);
            assert!(*set);
            drop(set);
            setting.join().unwrap();
        }
    }

    #[test]
    fn wait_while_reads_the_condition_at_once_and_waits_not_when_it_does_not_hold() {
        let flag = (Mutex::new(true), Condvar::new());
        let mut reads = 0;
        let (_set, ended) = wait_while(
            &flag.1,
            flag.0.lock().unwrap(),
            HangGuard::on("nothing", Duration::ZERO),
            |set| {
                reads += 1;
                !*set
            },
        );
        assert!(ended);
        assert_eq!(reads, 1);
    }

    #[test]
    fn wait_while_says_the_guard_ran_out_with_the_condition_still_holding() {
        let flag = (Mutex::new(false), Condvar::new());
        let guard = HangGuard::held("the flag, which nothing sets", Duration::ZERO);
        let (set, ended) = wait_while(&flag.1, flag.0.lock().unwrap(), guard, |set| !*set);
        assert!(!ended);
        assert!(!*set);
    }

    #[test]
    fn wait_while_takes_a_poisoned_lock_as_it_is() {
        let flag = Arc::new((Mutex::new(true), Condvar::new()));
        let poisoning = Arc::clone(&flag);
        let _ = thread::spawn(move || {
            let _held = poisoning.0.lock().unwrap();
            panic!("poisons the lock");
        })
        .join();
        let lock = flag.0.lock().unwrap_or_else(PoisonError::into_inner);
        let (set, ended) = wait_while(&flag.1, lock, DEADLINE, |set| !*set);
        assert!(ended);
        assert!(*set);
    }

    #[test]
    fn a_stopwatch_names_its_timing_and_measures_at_least_the_real_time_slept() {
        const SPAN: RealTime = RealTime::under("a sleep, measured", Duration::from_millis(2));
        let stopwatch = Stopwatch::start("a sleep");
        assert_eq!(stopwatch.timing(), "a sleep");
        SPAN.sleep();
        // real time under test: a lower bound, which load only makes
        // surer.
        assert!(stopwatch.elapsed() >= SPAN.span());
    }

    #[test]
    fn real_time_names_its_timing_and_span() {
        const SPAN: RealTime = RealTime::under("a debounce", Duration::from_millis(3));
        assert_eq!(SPAN.timing(), "a debounce");
        assert_eq!(SPAN.span(), Duration::from_millis(3));
        RealTime::under("no time at all", Duration::ZERO).sleep();
    }
}
