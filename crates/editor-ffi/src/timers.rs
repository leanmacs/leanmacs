//! The timer service: waits on a clock, completed through the completion
//! queue.
//!
//! This is the first service behind the completion queue, and the shape
//! every later one follows (the crate docs, "Services and completions"). A
//! job in Lean asks for a wait with an id and a deadline. [`Timers::start`]
//! returns at once, and when the clock reaches the deadline the service
//! thread completes the wait: for the process's instance, by queueing an
//! [`EventKind::Completion`](crate::events::EventKind::Completion) whose
//! code is the id. Rust never calls Lean.
//!
//! The pieces:
//!
//! - [`Clock`] is the port time is read through, in milliseconds since the
//!   clock began. [`Monotonic`] is the real one, and [`FakeClock`] the fake,
//!   which a test moves by hand. It is public, not `cfg(test)`, like the
//!   scripted event source.
//! - [`Schedule`] is the waits not yet due, and the flushes. It is pure:
//!   which wait is due when, where a flush comes out among them, and what
//!   cancelling means, are decided here and tested with no thread and no
//!   clock.
//!
//! **A flush is a barrier** ([`Timers::flush`]): due at the clock's reading
//! when it is asked, it comes out in the same turn as every wait due by
//! then, after them, so its completion is queued behind theirs. A wait not
//! yet due is not covered, since it is no work the service can finish now.
//! - [`Timers`] is the service over a clock: it holds a schedule, and its
//!   loop, [`Timers::run`], completes due waits through a closure it is
//!   given, and otherwise parks until the next deadline, a new wait, or
//!   [`Timers::wake`].
//!
//! The process has one instance, on the real clock, a `const`-initialised
//! static like the queues. Its thread starts on the first
//! [`editor_ffi_timers_start`], so nothing runs when the library is loaded.
//! The C functions at the bottom only forward to it.

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, PoisonError};
use std::thread;
use std::time::{Duration, Instant};

use crate::events;

/// The waits that are not yet due, each an id and a deadline in milliseconds
/// on some clock.
#[derive(Debug, Default)]
pub struct Schedule {
    /// Every wait as `(deadline, id)`, so the first is the next one due.
    by_deadline: BTreeSet<(u64, u64)>,
    /// The deadline of every wait, by id.
    deadlines: BTreeMap<u64, u64>,
    /// Every flush as `(deadline, id)`, in the order they were asked.
    flushes: VecDeque<(u64, u64)>,
}

impl Schedule {
    /// A schedule with no waits.
    pub const fn new() -> Self {
        Self {
            by_deadline: BTreeSet::new(),
            deadlines: BTreeMap::new(),
            flushes: VecDeque::new(),
        }
    }

    /// Adds the wait `id`, due at `deadline`, and returns whether it was
    /// added. An id that is already waiting is refused, and keeps the
    /// deadline it has.
    pub fn start(&mut self, id: u64, deadline: u64) -> bool {
        if self.holds(id) {
            return false;
        }
        self.deadlines.insert(id, deadline);
        self.by_deadline.insert((deadline, id));
        true
    }

    /// Adds the flush `id`, due at `deadline`, and returns whether it was
    /// added. It comes out of [`take_due`](Self::take_due) in the same
    /// turn as every wait due by `deadline`, after them, whatever their
    /// ids. An id that is waiting, as a wait or a flush, is refused.
    pub fn start_flush(&mut self, id: u64, deadline: u64) -> bool {
        if self.holds(id) {
            return false;
        }
        self.flushes.push_back((deadline, id));
        true
    }

    /// Whether `id` is waiting, as a wait or a flush.
    fn holds(&self, id: u64) -> bool {
        self.deadlines.contains_key(&id) || self.flushes.iter().any(|&(_, flush)| flush == id)
    }

    /// Removes the wait or flush `id`, and returns whether it was waiting.
    pub fn cancel(&mut self, id: u64) -> bool {
        match self.deadlines.remove(&id) {
            Some(deadline) => self.by_deadline.remove(&(deadline, id)),
            None => {
                let before = self.flushes.len();
                self.flushes.retain(|&(_, flush)| flush != id);
                self.flushes.len() != before
            }
        }
    }

    /// Removes and returns the ids of the waits due at `now`: those whose
    /// deadline is `now` or earlier, earliest deadline first, and of two
    /// with one deadline the lower id first; then the ids of the flushes
    /// due at `now`, in the order they were asked.
    pub fn take_due(&mut self, now: u64) -> Vec<u64> {
        let mut due = Vec::new();
        while let Some(&(deadline, id)) = self.by_deadline.first() {
            if deadline > now {
                break;
            }
            self.by_deadline.remove(&(deadline, id));
            self.deadlines.remove(&id);
            due.push(id);
        }
        self.flushes.retain(|&(deadline, id)| {
            let is_due = deadline <= now;
            if is_due {
                due.push(id);
            }
            !is_due
        });
        due
    }

    /// The earliest deadline a wait or a flush is waiting for, if any is.
    pub fn next_deadline(&self) -> Option<u64> {
        let wait = self.by_deadline.first().map(|&(deadline, _)| deadline);
        let flush = self.flushes.iter().map(|&(deadline, _)| deadline).min();
        wait.into_iter().chain(flush).min()
    }

    /// How many waits and flushes are waiting.
    pub fn pending(&self) -> usize {
        self.deadlines.len() + self.flushes.len()
    }
}

/// The port time is read through.
pub trait Clock: Send + Sync {
    /// The time, in milliseconds since the clock began. It never goes back.
    fn now_ms(&self) -> u64;
}

impl<C: Clock> Clock for Arc<C> {
    fn now_ms(&self) -> u64 {
        (**self).now_ms()
    }
}

/// The real clock: monotonic, and beginning the first time it is read.
#[derive(Debug, Default)]
pub struct Monotonic {
    /// When the clock was first read.
    began: OnceLock<Instant>,
}

impl Monotonic {
    /// A clock that begins when it is first read.
    pub const fn new() -> Self {
        Self {
            began: OnceLock::new(),
        }
    }
}

impl Clock for Monotonic {
    fn now_ms(&self) -> u64 {
        let elapsed = self.began.get_or_init(Instant::now).elapsed();
        u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX)
    }
}

/// A fake clock: it reads 0 until a test moves it.
#[derive(Debug, Default)]
pub struct FakeClock {
    /// The clock's reading.
    now: AtomicU64,
}

impl FakeClock {
    /// A clock that reads 0.
    pub const fn new() -> Self {
        Self {
            now: AtomicU64::new(0),
        }
    }

    /// Moves the clock on by `ms` milliseconds. A service parked on the old
    /// reading does not notice by itself: tell it with [`Timers::wake`].
    pub fn advance(&self, ms: u64) {
        self.now.fetch_add(ms, Ordering::SeqCst);
    }
}

impl Clock for FakeClock {
    fn now_ms(&self) -> u64 {
        self.now.load(Ordering::SeqCst)
    }
}

/// The timer service over the clock `C`: waits that
/// [`run`](Self::run) completes when the clock reaches their deadlines.
pub struct Timers<C> {
    /// Where the time is read.
    clock: C,
    /// The waits, and whether the service has been stopped.
    state: Mutex<State>,
    /// Signalled when a wait is added, the service is stopped, or
    /// [`wake`](Self::wake) is called.
    changed: Condvar,
}

/// The longest the service parks before it looks at the clock again. A
/// deadline may be as far away as a `u64` of milliseconds, which no platform
/// timeout holds, so a park is cut to this and the loop simply parks again.
const LONGEST_PARK: Duration = Duration::from_secs(3600);

/// What [`Timers::state`] guards.
struct State {
    /// The waits not yet due.
    schedule: Schedule,
    /// Whether [`Timers::stop`] has been called.
    stopped: bool,
}

impl<C: Clock> Timers<C> {
    /// A service with no waits, whose loop is not running.
    pub const fn new(clock: C) -> Self {
        Self {
            clock,
            state: Mutex::new(State {
                schedule: Schedule::new(),
                stopped: false,
            }),
            changed: Condvar::new(),
        }
    }

    /// The clock's reading, in milliseconds.
    pub fn now_ms(&self) -> u64 {
        self.clock.now_ms()
    }

    /// Asks for the wait `id` to be completed once the clock reads
    /// `deadline` or later, and returns whether it was accepted. It returns
    /// at once. An id that is already waiting is refused.
    pub fn start(&self, id: u64, deadline: u64) -> bool {
        let started = self.state().schedule.start(id, deadline);
        // The new wait may be due before the one the service is parked for.
        self.changed.notify_all();
        started
    }

    /// Asks for the request `id` to be completed once every wait due when
    /// this is called has been completed, and returns whether it was
    /// accepted: it is due at the clock's reading now, and is completed in
    /// the same turn as every wait due by then, after them. A wait not yet
    /// due is not waited for: it is no work the service can finish now. It
    /// returns at once. An id that is waiting is refused, and a cancel
    /// withdraws it.
    pub fn flush(&self, id: u64) -> bool {
        let now = self.clock.now_ms();
        let started = self.state().schedule.start_flush(id, now);
        self.changed.notify_all();
        started
    }

    /// Withdraws the wait `id`, and returns whether it was waiting. A wait
    /// that is withdrawn is not completed. It is safe for an id that is
    /// unknown or already completed, and it returns false for one.
    pub fn cancel(&self, id: u64) -> bool {
        self.state().schedule.cancel(id)
    }

    /// How many waits are waiting.
    pub fn pending(&self) -> usize {
        self.state().schedule.pending()
    }

    /// Has the service look at the clock again. A real clock needs no
    /// telling; this is for a fake clock a test has moved.
    pub fn wake(&self) {
        // Under the lock, so the service is either parked, and hears this,
        // or has yet to read the clock, and reads the new time.
        let _state = self.state();
        self.changed.notify_all();
    }

    /// Ends [`run`](Self::run), for good. The waits that are left are never
    /// completed.
    pub fn stop(&self) {
        self.state().stopped = true;
        self.changed.notify_all();
    }

    /// The service loop: completes each wait once the clock has reached its
    /// deadline, by calling `complete` with its id, earliest deadline first,
    /// and otherwise parks the calling thread until the next deadline, a new
    /// wait or [`wake`](Self::wake). It returns after [`stop`](Self::stop).
    ///
    /// `complete` is called with no lock held.
    pub fn run(&self, complete: impl Fn(u64)) {
        let mut state = self.state();
        loop {
            if state.stopped {
                return;
            }
            let now = self.clock.now_ms();
            let due = state.schedule.take_due(now);
            if !due.is_empty() {
                drop(state);
                for id in due {
                    complete(id);
                }
                state = self.state();
                continue;
            }
            state = match state.schedule.next_deadline() {
                None => self
                    .changed
                    .wait(state)
                    .unwrap_or_else(PoisonError::into_inner),
                Some(deadline) => {
                    let park =
                        Duration::from_millis(deadline.saturating_sub(now)).min(LONGEST_PARK);
                    self.changed
                        .wait_timeout(state, park)
                        .unwrap_or_else(PoisonError::into_inner)
                        .0
                }
            };
        }
    }

    /// Locks the state. The lock is never held while other code runs, so a
    /// poisoned lock still guards a consistent state.
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// The id of the timer service as an event's source: a completion of a timer
/// request comes from the library source with this id.
pub const SERVICE: u64 = 1;

/// The process's timer service, on the real clock.
static TIMERS: Timers<Monotonic> = Timers::new(Monotonic::new());

/// Whether the thread that runs the process's service loop was started:
/// set once, by the first request.
static STARTED: OnceLock<bool> = OnceLock::new();

/// Starts the thread that runs the process's service loop, if no earlier
/// call has, and returns whether there is one. The thread completes a wait
/// by queueing its completion, and never ends: nothing in this crate joins a
/// thread, and once the queues are quit its completions are dropped.
fn service_started() -> bool {
    *STARTED.get_or_init(|| {
        thread::Builder::new()
            .name("editor-timers".into())
            .spawn(|| {
                TIMERS.run(|id| {
                    events::complete(SERVICE, id);
                });
            })
            .is_ok()
    })
}

/// The time on the process's timer clock, in milliseconds since the clock
/// began. It never goes back.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_timers_now() -> u64 {
    TIMERS.now_ms()
}

/// Asks the process's timer service to complete the request `id` once its
/// clock reads `deadline` or later, and returns whether it was accepted. It
/// returns at once and never blocks.
///
/// The completion is one [`EventKind::Completion`] on the completion queue,
/// from the library source [`SERVICE`], whose code is `id`; there is none if
/// the request is cancelled first.
///
/// Returns false, starting nothing, if `id` is already waiting, or if the
/// operating system refused the service its thread.
///
/// [`EventKind::Completion`]: crate::events::EventKind::Completion
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_timers_start(id: u64, deadline: u64) -> bool {
    service_started() && TIMERS.start(id, deadline)
}

/// Withdraws the timer request `id`, and returns whether it was waiting. It
/// is safe for an id that is unknown or already completed, and returns
/// false for one.
///
/// A request that was waiting is not completed. One whose completion is
/// already on the queue is still delivered, and the caller ignores it.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_timers_cancel(id: u64) -> bool {
    TIMERS.cancel(id)
}

/// Asks the process's timer service for the request `id` to be completed
/// once every timer request due when this is called has been completed
/// ([`Timers::flush`]), and returns whether it was accepted. It returns at
/// once and never blocks. Its completion is queued from [`SERVICE`] behind
/// those of the waits it covers. A wait not yet due is not covered.
///
/// Returns false, starting nothing, if `id` is already waiting, or if the
/// operating system refused the service its thread.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_timers_flush(id: u64) -> bool {
    service_started() && TIMERS.flush(id)
}

/// How many timer requests are waiting. A readout for tests, which use it
/// to see that a request reached the service and that a cancel removed it.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_timers_pending() -> u64 {
    TIMERS.pending() as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::{self, Receiver};

    use editor_service::Worker;

    /// hang guard: the next completion of the service, or the release a held test gives; only a hang reaches the bound, and the test then fails as a hang. Each wait on it is for something that
    /// should happen at once.
    const DEADLINE: Duration = Duration::from_secs(5);

    /// A timer service with its loop on a thread of the test's own and its
    /// completions on a channel.
    struct Rig<C> {
        /// The service.
        timers: Arc<Timers<C>>,
        /// The ids the service completed, in order.
        completed: Receiver<u64>,
        /// The thread the loop runs on, stopped and joined when the rig is
        /// dropped, a panicking test's rig included.
        service: Worker,
    }

    impl<C: Clock + 'static> Rig<C> {
        /// Starts the loop of a service over `clock`.
        fn over(clock: C) -> Self {
            let timers = Arc::new(Timers::new(clock));
            let (done, completed) = mpsc::channel();
            let service = Worker::spawn(
                "editor-timers-test",
                {
                    let timers = Arc::clone(&timers);
                    move || timers.stop()
                },
                {
                    let timers = Arc::clone(&timers);
                    move || {
                        timers.run(|id| {
                            let _ = done.send(id);
                        });
                    }
                },
            )
            .expect("the service's thread starts");
            Self {
                timers,
                completed,
                service,
            }
        }

        /// The next wait the service completes; panics if it completes none
        /// by the deadline.
        fn next(&self) -> u64 {
            self.completed
                .recv_timeout(DEADLINE)
                .unwrap_or_else(|_| panic!("no wait was completed within {DEADLINE:?}"))
        }

        /// Shows that the service has completed nothing that has not been
        /// taken with [`next`](Self::next), and still holds `waiting` waits:
        /// starts the wait `marker`, due now, and requires it to be the next
        /// completion, with that many waits left. A test never sleeps to see
        /// that something did not happen.
        ///
        /// The count matters. A service that took a wait early, in the same
        /// pass as the marker, would complete the marker first all the same,
        /// since it is due earlier; but the wait would be gone.
        fn nothing_else_completed(&self, marker: u64, waiting: usize) {
            assert!(self.timers.start(marker, self.timers.now_ms()));
            assert_eq!(self.next(), marker);
            assert_eq!(self.timers.pending(), waiting);
        }

        /// Stops the service and joins its loop's thread; panics if the
        /// loop panicked. A rig that is dropped does the same, and ignores
        /// a panic.
        fn stop(self) {
            self.service.join().expect("the service loop returns");
        }
    }

    impl Rig<Arc<FakeClock>> {
        /// Starts the loop of a service over a fake clock, which is
        /// returned too.
        fn fake() -> (Arc<FakeClock>, Self) {
            let clock = Arc::new(FakeClock::new());
            (Arc::clone(&clock), Self::over(clock))
        }
    }

    #[test]
    fn a_rig_left_by_a_panicking_test_stops_and_joins_its_loop() {
        let mut kept = None;
        let unwound = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let (_clock, rig) = Rig::fake();
            kept = Some(Arc::downgrade(&rig.timers));
            panic!("a test failed with its rig running");
        }));
        assert!(unwound.is_err());

        // The loop's thread held the other owner of the service: it has
        // returned once the rig is dropped.
        let kept = kept.expect("the rig was built");
        assert!(
            kept.upgrade().is_none(),
            "the rig's loop was still running after the test unwound"
        );
    }

    #[test]
    fn a_fake_clock_reads_zero_until_it_is_moved() {
        let clock = FakeClock::new();
        assert_eq!(clock.now_ms(), 0);

        clock.advance(7);
        clock.advance(3);

        assert_eq!(clock.now_ms(), 10);
    }

    #[test]
    fn the_real_clock_does_not_go_back() {
        let clock = Monotonic::new();

        let first = clock.now_ms();
        let second = clock.now_ms();

        assert!(first <= second);
    }

    #[test]
    fn the_service_completes_a_wait_when_the_clock_reaches_its_deadline_and_not_before() {
        let (clock, rig) = Rig::fake();
        assert!(rig.timers.start(7, 100));

        clock.advance(99);
        rig.timers.wake();
        // The marker is the next completion and 7 is still waiting, so 7 was
        // not completed at 99.
        rig.nothing_else_completed(1, 1);

        clock.advance(1);
        rig.timers.wake();
        assert_eq!(rig.next(), 7);
        rig.stop();
    }

    #[test]
    fn the_service_completes_due_waits_earliest_deadline_first() {
        let (clock, rig) = Rig::fake();
        rig.timers.start(1, 30);
        rig.timers.start(2, 10);
        rig.timers.start(3, 20);
        rig.timers.start(4, 31);

        clock.advance(30);
        rig.timers.wake();

        assert_eq!([rig.next(), rig.next(), rig.next()], [2, 3, 1]);
        assert_eq!(rig.timers.pending(), 1);
        rig.stop();
    }

    #[test]
    fn the_service_never_completes_a_cancelled_wait() {
        let (clock, rig) = Rig::fake();
        rig.timers.start(8, 50);
        rig.timers.start(9, 60);
        assert_eq!(rig.timers.pending(), 2);

        assert!(rig.timers.cancel(8));
        assert!(!rig.timers.cancel(8));
        assert!(!rig.timers.cancel(99));
        assert_eq!(rig.timers.pending(), 1);

        clock.advance(50);
        rig.timers.wake();
        // At 50 the cancelled wait would have been due.
        rig.nothing_else_completed(1, 1);
        clock.advance(10);
        rig.timers.wake();
        assert_eq!(rig.next(), 9);
        rig.stop();
    }

    #[test]
    fn the_service_refuses_an_id_that_is_already_waiting() {
        let (clock, rig) = Rig::fake();
        assert!(rig.timers.start(7, 10));

        assert!(!rig.timers.start(7, 0));

        // The refused start did not make the wait due.
        rig.nothing_else_completed(1, 1);
        clock.advance(10);
        rig.timers.wake();
        assert_eq!(rig.next(), 7);
        rig.stop();
    }

    #[test]
    fn stop_ends_the_service_loop_with_waits_left() {
        let (_clock, rig) = Rig::fake();
        rig.timers.start(7, 100);

        rig.stop();
    }

    #[test]
    fn on_the_real_clock_a_wait_due_now_is_completed_while_later_ones_wait() {
        let rig = Rig::over(Monotonic::new());
        let now = rig.timers.now_ms();
        // An hour away, and as far away as a deadline can be.
        assert!(rig.timers.start(1, now + 3_600_000));
        assert!(rig.timers.start(2, u64::MAX));

        assert!(rig.timers.start(3, now));

        assert_eq!(rig.next(), 3);
        assert_eq!(rig.timers.pending(), 2);
        rig.stop();
    }

    #[test]
    fn on_the_real_clock_a_wait_is_completed_no_earlier_than_its_deadline() {
        let rig = Rig::over(Monotonic::new());
        let deadline = rig.timers.now_ms() + 3;

        assert!(rig.timers.start(1, deadline));

        assert_eq!(rig.next(), 1);
        // real time under test: the real clock's deadline, a lower bound
        // that load only makes surer.
        assert!(rig.timers.now_ms() >= deadline);
        rig.stop();
    }

    #[test]
    fn waits_come_out_earliest_deadline_first_and_the_lower_id_first_of_two_with_one_deadline() {
        let mut schedule = Schedule::new();
        assert!(schedule.start(1, 30));
        assert!(schedule.start(2, 10));
        assert!(schedule.start(4, 20));
        assert!(schedule.start(3, 20));
        assert_eq!(schedule.pending(), 4);

        assert_eq!(schedule.take_due(30), [2, 3, 4, 1]);

        assert_eq!(schedule.pending(), 0);
        assert_eq!(schedule.next_deadline(), None);
    }

    #[test]
    fn a_flush_comes_out_after_every_wait_due_at_its_deadline_whatever_their_ids() {
        let mut schedule = Schedule::new();
        assert!(schedule.start(5, 10));
        assert!(schedule.start(4, 3));
        // Lower than both waits' ids, and asked before one of them.
        assert!(schedule.start_flush(1, 10));
        assert!(schedule.start(6, 10));
        assert!(schedule.start(7, 11));
        assert!(schedule.start_flush(2, 10));
        // Its id is in use, for a flush and a wait alike.
        assert!(!schedule.start_flush(1, 0));
        assert!(!schedule.start(1, 0));
        assert!(!schedule.start_flush(5, 0));
        assert_eq!(schedule.pending(), 6);
        assert_eq!(schedule.next_deadline(), Some(3));

        // The waits due, earliest first, then the flushes in the order asked.
        assert_eq!(schedule.take_due(10), [4, 5, 6, 1, 2]);
        assert_eq!(schedule.pending(), 1);
        assert_eq!(schedule.next_deadline(), Some(11));
    }

    #[test]
    fn a_flush_is_not_due_before_its_deadline_and_a_cancelled_one_never_comes_out() {
        let mut schedule = Schedule::new();
        assert!(schedule.start_flush(1, 10));
        assert!(schedule.start_flush(2, 10));
        assert_eq!(schedule.next_deadline(), Some(10));
        assert_eq!(schedule.take_due(9), [] as [u64; 0]);

        assert!(schedule.cancel(1));
        assert!(!schedule.cancel(1));
        assert_eq!(schedule.pending(), 1);
        assert_eq!(schedule.take_due(10), [2]);
        assert_eq!(schedule.next_deadline(), None);
    }

    /// The service's thread is held inside the completion of wait 1 while
    /// wait 2 (due now), wait 3 (due later) and the flush are asked. The held
    /// thread is the only completer, so a flush completed at its call, or
    /// ahead of wait 2, is seen every time.
    #[test]
    fn a_flush_is_completed_after_every_wait_due_when_it_was_asked_and_not_before() {
        let clock = Arc::new(FakeClock::new());
        let timers = Arc::new(Timers::new(Arc::clone(&clock)));
        let (done, completed) = mpsc::channel();
        let (release, released) = mpsc::channel::<()>();
        let service = Worker::spawn(
            "editor-timers-test",
            {
                let timers = Arc::clone(&timers);
                move || timers.stop()
            },
            {
                let timers = Arc::clone(&timers);
                move || {
                    timers.run(|id| {
                        let _ = done.send(id);
                        if id == 1 {
                            let _ = released.recv_timeout(DEADLINE);
                        }
                    });
                }
            },
        )
        .expect("the service's thread starts");
        let next = || {
            completed
                .recv_timeout(DEADLINE)
                .unwrap_or_else(|_| panic!("no wait was completed within {DEADLINE:?}"))
        };
        assert!(timers.start(1, 0));
        assert_eq!(next(), 1);
        assert!(timers.start(2, 0));
        assert!(timers.start(3, 10));
        assert!(timers.flush(9));
        assert!(!timers.flush(9));

        assert!(completed.try_recv().is_err());
        let _ = release.send(());

        assert_eq!([next(), next()], [2, 9]);
        // Wait 3 is not due, so the flush did not wait for it: a marker
        // due now is the next completion, and 3 is still waiting.
        assert!(timers.start(4, 0));
        assert_eq!(next(), 4);
        assert_eq!(timers.pending(), 1);
        service.join().expect("the service loop returns");
    }

    #[test]
    fn nothing_is_due_before_its_deadline() {
        let mut schedule = Schedule::new();
        schedule.start(1, 10);
        schedule.start(2, 11);

        assert_eq!(schedule.take_due(9), [] as [u64; 0]);
        assert_eq!(schedule.next_deadline(), Some(10));

        // Due at its deadline, not only after it, and the later one stays.
        assert_eq!(schedule.take_due(10), [1]);
        assert_eq!(schedule.next_deadline(), Some(11));
        assert_eq!(schedule.pending(), 1);
    }

    #[test]
    fn a_cancelled_wait_never_comes_out_and_cancel_says_whether_it_was_waiting() {
        let mut schedule = Schedule::new();
        schedule.start(1, 10);
        schedule.start(2, 10);

        assert!(schedule.cancel(1));
        assert!(!schedule.cancel(1), "it is no longer waiting");
        assert!(!schedule.cancel(99), "it never was");

        assert_eq!(schedule.pending(), 1);
        assert_eq!(schedule.take_due(u64::MAX), [2]);
        assert!(!schedule.cancel(2), "a wait that came out is not waiting");
    }

    #[test]
    fn an_id_that_is_already_waiting_is_refused_and_keeps_its_deadline() {
        let mut schedule = Schedule::new();
        assert!(schedule.start(1, 10));

        assert!(!schedule.start(1, 5));

        assert_eq!(schedule.pending(), 1);
        assert_eq!(schedule.next_deadline(), Some(10));
        // Once it has come out, the id can wait again.
        assert_eq!(schedule.take_due(10), [1]);
        assert!(schedule.start(1, 20));
    }
}
