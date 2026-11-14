//! The render loop: frames in through a mailbox, one draw at a time, on
//! demand.
//!
//! A [`RenderLoop`] owns a renderer and is run by one thread, the render
//! thread. Every other thread reaches it through a [`RenderHandle`], which
//! only leaves word: a frame in the mailbox, a dirty mark, a new size, an
//! animation deadline. The loop never calls layout, a shaper or Lean, and
//! holds no lock while it draws.
//!
//! # What is a demand
//!
//! - **A frame** that is not the one shown. Submitting the frame shown
//!   again, the same value or an equal one, is no demand: nothing is
//!   drawn.
//! - **A dirty mark** ([`RenderHandle::mark_dirty`]): the frame shown is
//!   drawn again. Any number of marks before a draw are one demand.
//! - **A new size or scale** ([`RenderHandle::resize`]): the frame shown
//!   is drawn again on the new target at once, without waiting for a frame
//!   laid out for it. The size last drawn at is no demand.
//! - **An animation deadline** ([`RenderHandle::animate_at`]) that has
//!   come.
//!
//! When to draw is [`schedule::decide`](crate::schedule::decide)'s: at
//! most one draw for each refresh interval, and with no demand a wait with
//! no deadline. Nothing is drawn before a first frame arrives.
//!
//! A mark, a new size and a deadline each ask for the frame shown to be
//! drawn again. Made before a first frame is shown they ask for nothing:
//! the first draw is on the size last asked for, and it takes the mark and
//! a deadline that has come without answering them. A deadline still
//! ahead is kept for the frame that draw shows.
//!
//! # What a draw leaves behind
//!
//! One journal [`Entry`] for each draw that presented, and none otherwise.
//! Its `input_ns` is the oldest stamp among the demands the draw served: a
//! frame's stamp is its publisher's, or the time it was submitted when the
//! publisher gave none, and where a newer frame replaced one not yet drawn
//! the older stamp is kept; a dirty mark and a resize are stamped as they
//! are made; an animation by its deadline. A draw with no frame shown
//! before it served its frame alone, so its `input_ns` is that frame's
//! stamp whatever else was asked. Its `draw_ns` is read as the draw begins
//! and its `present_ns` when the renderer returns.
//!
//! A draw that does not present leaves its demands as they were, adds no
//! entry, counts as failed, and is tried again a refresh later.
//!
//! # Stepping and running
//!
//! [`RenderLoop::step`] takes one decision and makes at most one draw, and
//! never blocks: it says what it did or how long there is to wait. Tests
//! step a loop by hand on a [`FakeClock`](crate::clock::FakeClock).
//!
//! [`RenderLoop::run`] is the render thread's whole life: it steps, and
//! waits on the loop's [`Park`] whenever a step says to. The real park,
//! [`CondvarPark`], is a lock and a condition variable, so an idle loop is
//! a thread blocked with no deadline, which costs nothing; its timeout
//! for a wait with a deadline is computed from the clock port. The fake,
//! [`RecordingPark`], never blocks. Nothing here starts a thread: whoever
//! wires the program together does.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use editor_layout::frame::Frame;

use crate::clock::Clock;
use crate::journal::{Counters, Entry, Journal};
use crate::mailbox::Mailbox;
use crate::port::{DrawRequest, Renderer, Target};
use crate::schedule::{DEFAULT_REFRESH_NS, Decision, Demands, Pace, decide};

/// The port through which the render thread waits and is woken.
pub trait Park: Send + Sync {
    /// Waits until [`Park::notify`] is called, or until the loop's clock
    /// reads `until` when there is one. A notification made since the last
    /// wait began is not lost: the wait returns at once.
    fn wait(&self, until: Option<u64>);

    /// Wakes the thread that waits, or the next that will.
    fn notify(&self);
}

/// The published fake of [`Park`]: it keeps the waits it was asked for and
/// returns from each at once, and counts the notifications.
///
/// A test that runs a loop on it ([`RenderLoop::run`]) gives it a script
/// ([`RecordingPark::then`]): one thing to do at each wait, in order, in
/// place of waiting. That is where the test leaves word for the loop or
/// moves its clock, on the loop's own thread, and its last action stops
/// the loop: a wait past the end of the script returns at once like any
/// other, so a loop nobody stops never ends.
#[derive(Default)]
pub struct RecordingPark {
    /// The deadline of each wait, in order.
    waits: Mutex<Vec<Option<u64>>>,
    /// How many times it was notified.
    notifications: AtomicU64,
    /// What is left to do at the waits to come.
    script: Mutex<VecDeque<Box<dyn FnOnce() + Send>>>,
}

impl RecordingPark {
    /// A park nobody has waited on.
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds `action` to the script: it is run at the first wait that no
    /// earlier action was run at.
    pub fn then(&self, action: impl FnOnce() + Send + 'static) {
        locked(&self.script).push_back(Box::new(action));
    }

    /// The deadline of each wait it was asked for, in order.
    pub fn waits(&self) -> Vec<Option<u64>> {
        locked(&self.waits).clone()
    }

    /// How many times it was notified.
    pub fn notifications(&self) -> u64 {
        self.notifications.load(Ordering::SeqCst)
    }
}

impl Park for RecordingPark {
    fn wait(&self, until: Option<u64>) {
        locked(&self.waits).push(until);
        // The action is taken out before it is run, so it may itself add
        // to the script.
        let next = locked(&self.script).pop_front();
        if let Some(action) = next {
            action();
        }
    }

    fn notify(&self) {
        self.notifications.fetch_add(1, Ordering::SeqCst);
    }
}

/// The real [`Park`]: a true wait, on a lock and a condition variable.
///
/// A wait with no deadline blocks the thread until it is notified. A wait
/// with one blocks for as long as the clock it was given says is left,
/// and returns at once when the deadline has passed. A notification is
/// kept until a wait takes it, so one made between a loop's step and its
/// wait is not lost. A wait may also end for no reason, as a condition
/// variable's may: the loop decides again, and waits again.
pub struct CondvarPark {
    /// The clock a deadline is on.
    clock: Arc<dyn Clock>,
    /// Whether it was notified since a wait last returned.
    notified: Mutex<bool>,
    /// What a waiting thread is woken through.
    wake: Condvar,
}

impl CondvarPark {
    /// A park whose deadlines are times of `clock`.
    pub fn new(clock: Arc<dyn Clock>) -> Self {
        Self {
            clock,
            notified: Mutex::new(false),
            wake: Condvar::new(),
        }
    }
}

impl Park for CondvarPark {
    fn wait(&self, until: Option<u64>) {
        let mut notified = locked(&self.notified);
        match until {
            None => {
                while !*notified {
                    notified = self
                        .wake
                        .wait(notified)
                        .unwrap_or_else(PoisonError::into_inner);
                }
            }
            Some(until) => {
                let left = until.saturating_sub(self.clock.now_ns());
                if !*notified && left > 0 {
                    // Once, for as long as the clock says is left: the
                    // loop reads its clock again when this returns.
                    notified = self
                        .wake
                        .wait_timeout(notified, Duration::from_nanos(left))
                        .unwrap_or_else(PoisonError::into_inner)
                        .0;
                }
            }
        }
        *notified = false;
    }

    fn notify(&self) {
        *locked(&self.notified) = true;
        self.wake.notify_one();
    }
}

/// `mutex`, locked. A poisoned lock is used as it is: what these locks
/// guard is replaced whole or only added to.
fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The target asked for, and since when it has been another than the one
/// drawn on.
#[derive(Debug, Clone, Copy)]
struct Asked {
    /// The target to draw on.
    target: Target,
    /// When it first changed since the last draw.
    since: Option<u64>,
}

/// What the render thread writes for others to read.
#[derive(Debug, Default)]
struct Record {
    /// The frame journal.
    journal: Journal,
    /// What the loop has done, but for the frames submitted and replaced.
    counters: Counters,
}

/// What a loop and its handles share.
struct Shared {
    /// The loop's clock.
    clock: Arc<dyn Clock>,
    /// What the render thread waits on.
    park: Arc<dyn Park>,
    /// The frame submitted and not yet taken.
    mailbox: Mailbox<Arc<Frame>>,
    /// When the frame shown was first marked dirty since the last draw; 0
    /// when it is not.
    dirty_since: AtomicU64,
    /// The animation deadline; 0 when there is none.
    animate_at: AtomicU64,
    /// The refresh interval.
    refresh_ns: AtomicU64,
    /// The target asked for.
    asked: Mutex<Asked>,
    /// Whether the loop was told to stop.
    stopped: AtomicBool,
    /// How many frames were submitted.
    frames_submitted: AtomicU64,
    /// How many frames a newer one replaced before they were drawn.
    frames_replaced: AtomicU64,
    /// The journal and the counters.
    record: Mutex<Record>,
}

/// The way every other thread reaches a render loop: it leaves word and
/// wakes the render thread, and never waits for a draw.
#[derive(Clone)]
pub struct RenderHandle {
    /// What it shares with the loop.
    shared: Arc<Shared>,
}

impl RenderHandle {
    /// Hands the loop `frame` to show. `input_ns` is when the input it
    /// answers was stamped, on the loop's clock; with `None` it is stamped
    /// now. A frame submitted before the last one was drawn replaces it.
    pub fn submit(&self, frame: Arc<Frame>, input_ns: Option<u64>) {
        let shared = &self.shared;
        let stamp = input_ns.unwrap_or_else(|| shared.clock.now_ns());
        shared.frames_submitted.fetch_add(1, Ordering::SeqCst);
        if shared.mailbox.post(frame, stamp) {
            shared.frames_replaced.fetch_add(1, Ordering::SeqCst);
        }
        shared.park.notify();
    }

    /// Says the frame shown must be drawn again.
    pub fn mark_dirty(&self) {
        let now = self.shared.clock.now_ns();
        keep_older(&self.shared.dirty_since, now);
        self.shared.park.notify();
    }

    /// Says the target is now `target`: another size, or another scale.
    pub fn resize(&self, target: Target) {
        let now = self.shared.clock.now_ns();
        {
            let mut asked = locked(&self.shared.asked);
            if asked.target != target {
                asked.target = target;
                asked.since.get_or_insert(now);
            }
        }
        self.shared.park.notify();
    }

    /// Asks for a draw when the clock reads `at`. Of two deadlines the
    /// sooner is kept.
    pub fn animate_at(&self, at: u64) {
        keep_older(&self.shared.animate_at, at);
        self.shared.park.notify();
    }

    /// Says the display refreshes every `ns` nanoseconds.
    pub fn set_refresh(&self, ns: u64) {
        self.shared.refresh_ns.store(ns, Ordering::SeqCst);
        self.shared.park.notify();
    }

    /// The journal's entries, oldest first, as a copy.
    pub fn journal(&self) -> Vec<Entry> {
        locked(&self.shared.record).journal.entries()
    }

    /// What the loop has done so far, as a copy.
    pub fn counters(&self) -> Counters {
        Counters {
            frames_submitted: self.shared.frames_submitted.load(Ordering::SeqCst),
            frames_replaced: self.shared.frames_replaced.load(Ordering::SeqCst),
            ..locked(&self.shared.record).counters
        }
    }

    /// Tells the loop to stop: its next step is [`Step::Stopped`].
    pub fn stop(&self) {
        self.shared.stopped.store(true, Ordering::SeqCst);
        self.shared.park.notify();
    }
}

/// Puts the time `at` in `slot`, where 0 is "none", unless an earlier time
/// is there. A time of 0 is kept as 1: no clock reads 0.
fn keep_older(slot: &AtomicU64, at: u64) {
    let at = at.max(1);
    // The closure always gives a value, so the update cannot fail.
    let _ = slot.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |held| {
        Some(if held == 0 { at } else { held.min(at) })
    });
}

/// The time in `slot`, where 0 is "none".
fn time_in(slot: &AtomicU64) -> Option<u64> {
    Some(slot.load(Ordering::SeqCst)).filter(|at| *at != 0)
}

/// Whether `frame` is the frame `shown`: the same value, or an equal one.
fn same(frame: &Arc<Frame>, shown: &Arc<Frame>) -> bool {
    Arc::ptr_eq(frame, shown) || frame == shown
}

/// What one step of a loop did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    /// It drew a frame and presented it: the journal's new entry.
    Drew(Entry),
    /// It drew nothing: there is nothing to do until the clock reads this
    /// time, or with `None` until something more is asked for.
    Wait(Option<u64>),
    /// The loop was told to stop.
    Stopped,
}

/// A renderer with the loop that drives it: run by the render thread.
pub struct RenderLoop<R> {
    /// The renderer.
    renderer: R,
    /// What it shares with its handles, its clock among it.
    shared: Arc<Shared>,
    /// The frame taken from the mailbox and not yet drawn, with its stamp.
    pending: Option<(Arc<Frame>, u64)>,
    /// The frame last presented.
    shown: Option<Arc<Frame>>,
    /// The target it was presented on.
    drawn_on: Option<Target>,
    /// When the last draw began.
    last_draw: Option<u64>,
}

impl<R: Renderer> RenderLoop<R> {
    /// A loop over `renderer` that draws on `target` until told otherwise,
    /// with the handle the other threads reach it through. It tells the
    /// time by `clock`, and its handles wake `park`.
    pub fn new(
        renderer: R,
        clock: Arc<dyn Clock>,
        park: Arc<dyn Park>,
        target: Target,
    ) -> (Self, RenderHandle) {
        let shared = Arc::new(Shared {
            clock,
            park,
            mailbox: Mailbox::new(),
            dirty_since: AtomicU64::new(0),
            animate_at: AtomicU64::new(0),
            refresh_ns: AtomicU64::new(DEFAULT_REFRESH_NS),
            asked: Mutex::new(Asked {
                target,
                since: None,
            }),
            stopped: AtomicBool::new(false),
            frames_submitted: AtomicU64::new(0),
            frames_replaced: AtomicU64::new(0),
            record: Mutex::new(Record::default()),
        });
        let handle = RenderHandle {
            shared: Arc::clone(&shared),
        };
        let render_loop = Self {
            renderer,
            shared,
            pending: None,
            shown: None,
            drawn_on: None,
            last_draw: None,
        };
        (render_loop, handle)
    }

    /// The renderer.
    pub fn renderer(&self) -> &R {
        &self.renderer
    }

    /// The renderer, to change.
    pub fn renderer_mut(&mut self) -> &mut R {
        &mut self.renderer
    }

    /// Takes one decision, and draws once if that is the decision. It
    /// never waits.
    pub fn step(&mut self) -> Step {
        let shared = Arc::clone(&self.shared);
        if shared.stopped.load(Ordering::SeqCst) {
            return Step::Stopped;
        }
        // The newest frame submitted replaces one taken and not yet drawn,
        // and the stamp kept is the older.
        if let Some((frame, stamp)) = shared.mailbox.take() {
            let stamp = self.pending.take().map_or(stamp, |(_, older)| {
                shared.frames_replaced.fetch_add(1, Ordering::SeqCst);
                older.min(stamp)
            });
            self.pending = Some((frame, stamp));
        }
        // The frame shown, submitted again, is no demand.
        if let (Some((frame, _)), Some(shown)) = (&self.pending, &self.shown)
            && same(frame, shown)
        {
            self.pending = None;
        }
        // What a draw would show: the newest frame, or the one shown again.
        // Before a first frame there is nothing to draw.
        let newest = self.pending.as_ref().map(|(frame, _)| frame);
        let Some(frame) = newest.or(self.shown.as_ref()).cloned() else {
            return Step::Wait(None);
        };
        let resized = {
            let mut asked = locked(&shared.asked);
            let resized = self.shown.is_some() && self.drawn_on != Some(asked.target);
            if !resized {
                // The size drawn on, asked for again: nothing to answer.
                asked.since = None;
            }
            resized
        };
        let demands = Demands {
            frame: self.pending.is_some(),
            dirty_since: time_in(&shared.dirty_since),
            resized,
            animate_at: time_in(&shared.animate_at),
        };
        let pace = Pace {
            last_draw: self.last_draw,
            refresh_ns: shared.refresh_ns.load(Ordering::SeqCst),
        };
        let now = shared.clock.now_ns();
        match decide(&demands, &pace, now) {
            Decision::Idle => Step::Wait(None),
            Decision::WaitUntil(until) => Step::Wait(Some(until)),
            Decision::Draw => self.draw(frame, now, pace.refresh_ns),
        }
    }

    /// Runs the loop on the calling thread until it is told to stop, and
    /// gives the renderer back: it steps, and waits on its park whenever a
    /// step says there is nothing to do yet.
    pub fn run(mut self) -> R {
        let shared = Arc::clone(&self.shared);
        loop {
            match self.step() {
                Step::Drew(_) => {}
                Step::Wait(until) => shared.park.wait(until),
                Step::Stopped => return self.renderer,
            }
        }
    }

    /// Draws `frame` once, serving every demand there is at `now`.
    fn draw(&mut self, frame: Arc<Frame>, now: u64, refresh_ns: u64) -> Step {
        let shared = Arc::clone(&self.shared);
        // Take the demands this draw serves, each with its stamp. What is
        // asked for from here on is for the next draw.
        let pending = self.pending.take();
        let dirty = Some(shared.dirty_since.swap(0, Ordering::SeqCst)).filter(|at| *at != 0);
        let due = shared
            .animate_at
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |at| {
                (at != 0 && at <= now).then_some(0)
            })
            .ok();
        let (target, resized) = {
            let mut asked = locked(&shared.asked);
            (asked.target, asked.since.take())
        };
        // A mark, a deadline and a new size ask for the frame shown to be
        // drawn again. With none shown they asked for nothing: the draw
        // takes them, and answers its frame alone.
        let again = [dirty, due, resized].into_iter().flatten();
        let again = again.filter(|_| self.shown.is_some());
        let submitted = pending.as_ref().map(|(_, stamp)| *stamp);
        let draw_ns = shared.clock.now_ns();
        let input_ns = submitted.into_iter().chain(again).min();
        let input_ns = input_ns.unwrap_or(draw_ns);
        self.last_draw = Some(draw_ns);
        let drawn = self.renderer.draw(&DrawRequest {
            frame: &frame,
            target,
        });
        if !drawn.presented {
            // Every demand is left as it was, with the older of its
            // stamps, to be served a refresh from now.
            self.pending = pending;
            for (slot, taken) in [(&shared.dirty_since, dirty), (&shared.animate_at, due)] {
                if let Some(at) = taken {
                    keep_older(slot, at);
                }
            }
            if let Some(at) = resized {
                let mut asked = locked(&shared.asked);
                asked.since = Some(asked.since.map_or(at, |since| since.min(at)));
            }
            locked(&shared.record).counters.count(&drawn);
            return Step::Wait(Some(draw_ns.saturating_add(refresh_ns)));
        }
        let present_ns = shared.clock.now_ns();
        self.shown = Some(frame);
        self.drawn_on = Some(target);
        let mut record = locked(&shared.record);
        record.counters.count(&drawn);
        let entry = Entry {
            serial: record.counters.draws,
            input_ns,
            draw_ns,
            present_ns,
            rows_rebuilt: drawn.rows_rebuilt,
            rows_reused: drawn.rows_reused,
        };
        record.journal.record(entry);
        record.counters.journal_dropped = record.journal.dropped();
        Step::Drew(entry)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::mpsc::{Receiver, channel};
    use std::time::Duration;

    use editor_layout::Layout;
    use editor_layout::frame::Frame;
    use editor_layout::scene::{Rect, Scene};
    use editor_layout::shaper::fake::CellShaper;

    use super::{CondvarPark, Park, RecordingPark, RenderHandle, RenderLoop, Step};
    use crate::clock::{Clock, FakeClock};
    use crate::fake::RecordingRenderer;
    use crate::journal::{Counters, Entry, JOURNAL_CAPACITY};
    use crate::port::Target;
    use crate::schedule::DEFAULT_REFRESH_NS;

    /// A refresh interval for the tests: a round number, so the times read
    /// easily.
    const REFRESH: u64 = 1000;

    /// The target the loops begin on.
    const TARGET: Target = Target {
        width: 400,
        height: 300,
        scale: 1.0,
    };

    /// A loop under test, with the fakes it runs on.
    struct Rig {
        /// The loop, over the recording renderer.
        render: RenderLoop<RecordingRenderer>,
        /// Its handle.
        handle: RenderHandle,
        /// Its clock.
        clock: FakeClock,
        /// Its park.
        park: Arc<RecordingPark>,
    }

    /// A loop on `clock` that refreshes every [`REFRESH`] nanoseconds.
    fn rig_on(clock: FakeClock) -> Rig {
        let park = Arc::new(RecordingPark::new());
        let waited_on: Arc<dyn Park> = park.clone();
        let renderer = RecordingRenderer::new();
        let (render, handle) =
            RenderLoop::new(renderer, Arc::new(clock.clone()), waited_on, TARGET);
        handle.set_refresh(REFRESH);
        Rig {
            render,
            handle,
            clock,
            park,
        }
    }

    /// A loop on a clock that stays where a test puts it.
    fn rig() -> Rig {
        rig_on(FakeClock::new())
    }

    /// The frame of `text` in one view, laid out on the fake shaper.
    fn frame_of(text: &str) -> Arc<Frame> {
        let rect = Rect {
            x: 0,
            y: 0,
            width: 400,
            height: 300,
        };
        Arc::new(Layout::new(CellShaper::new(10.0, 16.0)).frame(&Scene::of_text(text, rect)))
    }

    impl Rig {
        /// Steps the loop, which must draw: the entry.
        fn drew(&mut self) -> Entry {
            match self.render.step() {
                Step::Drew(entry) => entry,
                other => panic!("the loop did not draw: {other:?}"),
            }
        }

        /// How many requests the renderer was given.
        fn requests(&self) -> usize {
            self.render.renderer().requests().len()
        }

        /// A loop that has shown `frame`, a refresh and more ago.
        fn showing(frame: &Arc<Frame>) -> Self {
            let mut rig = rig();
            rig.handle.submit(Arc::clone(frame), None);
            rig.drew();
            rig.clock.advance(REFRESH * 3);
            rig
        }
    }

    #[test]
    fn nothing_is_drawn_before_a_first_frame() {
        let mut rig = rig();
        assert_eq!(rig.render.step(), Step::Wait(None));
        // Not for a mark, a new size or a deadline either: there is
        // nothing to draw them with.
        rig.handle.mark_dirty();
        rig.handle.resize(Target {
            width: 800,
            ..TARGET
        });
        rig.handle.animate_at(1);
        rig.clock.advance(REFRESH);
        assert_eq!(rig.render.step(), Step::Wait(None));
        assert_eq!(rig.requests(), 0);
        assert!(rig.handle.journal().is_empty());
        assert_eq!(rig.handle.counters(), Counters::default());
    }

    #[test]
    fn what_was_asked_before_a_first_frame_is_shown_is_no_part_of_its_latency() {
        let wider = Target {
            width: 800,
            ..TARGET
        };
        // Whether or not the loop steps between what is asked and the
        // frame.
        for stepped in [true, false] {
            let mut rig = rig();
            rig.clock.set(10);
            rig.handle.mark_dirty();
            rig.handle.animate_at(20);
            rig.handle.resize(wider);
            if stepped {
                assert_eq!(rig.render.step(), Step::Wait(None));
            }
            // Five seconds on, the first frame, drawn at once.
            let arrived = 5_000_000_000;
            rig.clock.set(arrived);
            rig.handle.submit(frame_of("one"), None);
            let entry = rig.drew();
            // It answers its own frame alone: the mark, the deadline and
            // the size were of no frame shown.
            assert_eq!(
                (entry.input_ns, entry.draw_ns),
                (arrived, arrived),
                "stepped: {stepped}"
            );
            // It is drawn on the size asked for, and all three are served.
            assert_eq!(rig.render.renderer().requests()[0].target, wider);
            rig.clock.advance(REFRESH);
            assert_eq!(rig.render.step(), Step::Wait(None));
            assert_eq!(rig.requests(), 1);
        }
    }

    #[test]
    fn a_first_present_that_fails_keeps_what_was_asked_before_it_out_of_the_latency() {
        let mut rig = rig();
        rig.clock.set(10);
        rig.handle.mark_dirty();
        rig.handle.animate_at(20);
        rig.clock.set(7000);
        rig.handle.submit(frame_of("one"), None);
        rig.render.renderer_mut().fail_next_present();
        assert_eq!(rig.render.step(), Step::Wait(Some(7000 + REFRESH)));
        // Nothing is shown yet: a mark made now is of no frame either.
        rig.handle.mark_dirty();
        rig.clock.set(7000 + REFRESH);
        assert_eq!(rig.drew().input_ns, 7000);
        rig.clock.advance(REFRESH);
        assert_eq!(rig.render.step(), Step::Wait(None));
    }

    #[test]
    fn a_deadline_ahead_of_the_first_draw_is_kept_for_the_frame_it_shows() {
        let mut rig = rig();
        rig.clock.set(100);
        rig.handle.animate_at(9000);
        rig.handle.submit(frame_of("one"), None);
        assert_eq!(rig.drew().input_ns, 100);
        assert_eq!(rig.render.step(), Step::Wait(Some(9000)));
        rig.clock.set(9000);
        assert_eq!(rig.drew().input_ns, 9000);
    }

    #[test]
    fn a_submitted_frame_is_drawn_on_the_target_and_shown() {
        let mut rig = rig();
        let frame = frame_of("one");
        rig.clock.set(500);
        rig.handle.submit(Arc::clone(&frame), None);
        let entry = rig.drew();
        assert_eq!(
            (
                entry.serial,
                entry.input_ns,
                entry.draw_ns,
                entry.present_ns
            ),
            (1, 500, 500, 500)
        );
        let requests = rig.render.renderer().requests();
        assert_eq!(requests.len(), 1);
        assert!(Arc::ptr_eq(&requests[0].frame, &frame));
        assert_eq!(requests[0].target, TARGET);
        assert_eq!(rig.handle.journal(), vec![entry]);
        let counters = rig.handle.counters();
        assert_eq!((counters.draws, counters.frames_submitted), (1, 1));
        assert_eq!(counters.rows_rebuilt, entry.rows_rebuilt);
        // And then there is nothing to do.
        assert_eq!(rig.render.step(), Step::Wait(None));
    }

    #[test]
    fn submitting_the_frame_shown_again_draws_nothing() {
        let frame = frame_of("one\ntwo");
        let mut rig = Rig::showing(&frame);
        // The same value.
        rig.handle.submit(Arc::clone(&frame), None);
        assert_eq!(rig.render.step(), Step::Wait(None));
        // An equal frame, laid out again.
        let again = frame_of("one\ntwo");
        assert!(!Arc::ptr_eq(&again, &frame));
        rig.handle.submit(again, None);
        assert_eq!(rig.render.step(), Step::Wait(None));
        assert_eq!(rig.handle.counters().draws, 1);
        assert_eq!(rig.requests(), 1);
        assert_eq!(rig.handle.journal().len(), 1);
        // They were submitted, and replaced nothing.
        let counters = rig.handle.counters();
        assert_eq!(
            (counters.frames_submitted, counters.frames_replaced),
            (3, 0)
        );
    }

    #[test]
    fn a_dirty_mark_draws_the_frame_shown_again() {
        let frame = frame_of("one");
        let mut rig = Rig::showing(&frame);
        let marked = rig.clock.peek();
        rig.handle.mark_dirty();
        rig.clock.advance(7);
        let entry = rig.drew();
        assert_eq!((entry.serial, entry.input_ns), (2, marked));
        assert_eq!(rig.requests(), 2);
        assert!(Arc::ptr_eq(
            &rig.render.renderer().requests()[1].frame,
            &frame
        ));
        assert_eq!(rig.handle.counters().draws, 2);
        // The mark is served.
        assert_eq!(rig.render.step(), Step::Wait(None));
    }

    #[test]
    fn an_idle_loop_waits_with_no_deadline() {
        let mut rig = Rig::showing(&frame_of("one"));
        let before = (rig.handle.journal(), rig.handle.counters());
        for _ in 0..5 {
            rig.clock.advance(1_000_000_000);
            assert_eq!(rig.render.step(), Step::Wait(None));
        }
        assert_eq!((rig.handle.journal(), rig.handle.counters()), before);
        assert_eq!(rig.requests(), 1);
    }

    #[test]
    fn marks_within_one_refresh_are_one_draw() {
        let mut rig = Rig::showing(&frame_of("one"));
        rig.handle.mark_dirty();
        let first = rig.drew();
        // Three marks within the refresh after that draw.
        let mut marked = Vec::new();
        for _ in 0..3 {
            rig.clock.advance(100);
            marked.push(rig.clock.peek());
            rig.handle.mark_dirty();
            assert_eq!(rig.render.step(), Step::Wait(Some(first.draw_ns + REFRESH)));
        }
        rig.clock.set(first.draw_ns + REFRESH);
        let second = rig.drew();
        // One draw, which answers the first of them.
        assert_eq!(second.input_ns, marked[0]);
        assert_eq!(rig.render.step(), Step::Wait(None));
        assert_eq!(rig.handle.counters().draws, 3);
        assert_eq!(rig.requests(), 3);
    }

    #[test]
    fn two_frames_before_a_draw_are_one_draw_of_the_second() {
        let mut rig = rig();
        let (first, second) = (frame_of("one"), frame_of("two"));
        rig.clock.set(100);
        rig.handle.submit(first, None);
        rig.clock.set(200);
        rig.handle.submit(Arc::clone(&second), None);
        rig.clock.set(300);
        let entry = rig.drew();
        assert_eq!(rig.requests(), 1);
        assert!(Arc::ptr_eq(
            &rig.render.renderer().requests()[0].frame,
            &second
        ));
        // The stamp is the older one's.
        assert_eq!(entry.input_ns, 100);
        let counters = rig.handle.counters();
        assert_eq!(
            (
                counters.draws,
                counters.frames_submitted,
                counters.frames_replaced
            ),
            (1, 2, 1)
        );
        assert_eq!(rig.render.step(), Step::Wait(None));
    }

    #[test]
    fn a_frame_replaced_while_it_waits_for_the_refresh_keeps_the_older_stamp() {
        let mut rig = rig();
        rig.handle.submit(frame_of("one"), None);
        let first = rig.drew();
        let (second, third) = (frame_of("two"), frame_of("three"));
        let due = first.draw_ns + REFRESH;
        rig.handle.submit(second, Some(40));
        assert_eq!(rig.render.step(), Step::Wait(Some(due)));
        rig.handle.submit(Arc::clone(&third), Some(60));
        assert_eq!(rig.render.step(), Step::Wait(Some(due)));
        rig.clock.set(due);
        let entry = rig.drew();
        assert_eq!(entry.input_ns, 40);
        assert!(Arc::ptr_eq(
            &rig.render.renderer().requests()[1].frame,
            &third
        ));
        assert_eq!(rig.handle.counters().frames_replaced, 1);
    }

    #[test]
    fn a_frame_stamped_by_its_publisher_keeps_that_stamp() {
        let mut rig = rig();
        rig.clock.set(900);
        rig.handle.submit(frame_of("one"), Some(250));
        assert_eq!(rig.drew().input_ns, 250);
    }

    #[test]
    fn a_new_size_or_scale_draws_the_frame_shown_again() {
        let frame = frame_of("one");
        let mut rig = Rig::showing(&frame);
        let wider = Target {
            width: 800,
            ..TARGET
        };
        let asked = rig.clock.peek();
        rig.handle.resize(wider);
        rig.clock.advance(5);
        let entry = rig.drew();
        assert_eq!(entry.input_ns, asked);
        let requests = rig.render.renderer().requests();
        assert!(Arc::ptr_eq(&requests[1].frame, &frame));
        assert_eq!(requests[1].target, wider);
        assert_eq!(rig.render.step(), Step::Wait(None));
        // Another scale at the same size.
        rig.clock.advance(REFRESH);
        let denser = Target {
            scale: 2.0,
            ..wider
        };
        rig.handle.resize(denser);
        rig.drew();
        assert_eq!(rig.render.renderer().requests()[2].target, denser);
        // The size drawn at is no demand, and neither is a size left again
        // before a draw.
        rig.clock.advance(REFRESH);
        rig.handle.resize(denser);
        assert_eq!(rig.render.step(), Step::Wait(None));
        rig.handle.resize(TARGET);
        rig.handle.resize(denser);
        assert_eq!(rig.render.step(), Step::Wait(None));
        assert_eq!(rig.requests(), 3);
    }

    #[test]
    fn a_size_left_and_come_back_to_before_a_draw_leaves_no_stamp_behind() {
        let mut rig = Rig::showing(&frame_of("one"));
        let wider = Target {
            width: 800,
            ..TARGET
        };
        // There and back with no draw between: nothing to answer.
        rig.handle.resize(wider);
        rig.handle.resize(TARGET);
        assert_eq!(rig.render.step(), Step::Wait(None));
        // A second later the size changes for good: the draw answers that
        // change, and not the one that came to nothing.
        rig.clock.advance(1_000_000_000);
        let asked = rig.clock.peek();
        rig.handle.resize(wider);
        let entry = rig.drew();
        assert_eq!(entry.input_ns, asked);
        assert_eq!(rig.render.renderer().requests()[1].target, wider);
    }

    #[test]
    fn a_frame_and_a_new_size_are_one_draw_of_the_frame_on_the_size() {
        let mut rig = Rig::showing(&frame_of("one"));
        let next = frame_of("two");
        let wider = Target {
            width: 800,
            ..TARGET
        };
        rig.handle.resize(wider);
        rig.handle.submit(Arc::clone(&next), None);
        rig.drew();
        let requests = rig.render.renderer().requests();
        assert_eq!(requests.len(), 2);
        assert!(Arc::ptr_eq(&requests[1].frame, &next));
        assert_eq!(requests[1].target, wider);
        assert_eq!(rig.render.step(), Step::Wait(None));
    }

    #[test]
    fn a_frame_is_drawn_at_an_animation_deadline() {
        let frame = frame_of("one");
        let mut rig = Rig::showing(&frame);
        let deadline = rig.clock.peek() + 5000;
        rig.handle.animate_at(deadline);
        // Of two deadlines the sooner is kept.
        rig.handle.animate_at(deadline + 900);
        assert_eq!(rig.render.step(), Step::Wait(Some(deadline)));
        rig.clock.set(deadline - 1);
        assert_eq!(rig.render.step(), Step::Wait(Some(deadline)));
        rig.clock.set(deadline + 3);
        let entry = rig.drew();
        assert_eq!(entry.input_ns, deadline);
        assert_eq!(entry.draw_ns, deadline + 3);
        // The deadline is served: there is no other.
        assert_eq!(rig.render.step(), Step::Wait(None));
    }

    #[test]
    fn a_deadline_ahead_outlives_a_draw_made_before_it() {
        let mut rig = Rig::showing(&frame_of("one"));
        let deadline = rig.clock.peek() + 5000;
        rig.handle.animate_at(deadline);
        rig.handle.mark_dirty();
        rig.drew();
        assert_eq!(rig.render.step(), Step::Wait(Some(deadline)));
    }

    #[test]
    fn a_present_that_fails_leaves_the_demand_adds_no_entry_and_is_tried_again_after_a_refresh() {
        let mut rig = Rig::showing(&frame_of("one"));
        let next = frame_of("two");
        rig.handle.submit(Arc::clone(&next), Some(77));
        rig.handle.mark_dirty();
        rig.render.renderer_mut().fail_next_present();
        let tried = rig.clock.peek();
        assert_eq!(rig.render.step(), Step::Wait(Some(tried + REFRESH)));
        assert_eq!(rig.requests(), 2);
        assert_eq!(rig.handle.journal().len(), 1);
        let counters = rig.handle.counters();
        assert_eq!((counters.draws, counters.draws_failed), (1, 1));
        // Not before a refresh has passed.
        rig.clock.advance(REFRESH - 1);
        assert_eq!(rig.render.step(), Step::Wait(Some(tried + REFRESH)));
        rig.clock.advance(1);
        let entry = rig.drew();
        // The same frame, answering the same input.
        assert!(Arc::ptr_eq(
            &rig.render.renderer().requests()[2].frame,
            &next
        ));
        assert_eq!((entry.serial, entry.input_ns), (2, 77));
        assert_eq!(rig.handle.journal().len(), 2);
        assert_eq!(rig.render.step(), Step::Wait(None));
    }

    #[test]
    fn a_failed_present_keeps_a_new_size_and_a_deadline_to_serve() {
        let mut rig = Rig::showing(&frame_of("one"));
        let wider = Target {
            width: 800,
            ..TARGET
        };
        let asked = rig.clock.peek();
        rig.handle.resize(wider);
        rig.handle.animate_at(asked + 1);
        rig.clock.advance(10);
        rig.render.renderer_mut().fail_next_present();
        assert!(matches!(rig.render.step(), Step::Wait(Some(_))));
        rig.clock.advance(REFRESH);
        let entry = rig.drew();
        assert_eq!(entry.input_ns, asked);
        assert_eq!(rig.render.renderer().requests()[2].target, wider);
        assert_eq!(rig.render.step(), Step::Wait(None));
    }

    #[test]
    fn a_failed_present_keeps_a_dirty_mark_to_serve() {
        // A mark and nothing else: no frame and no new size asks for the
        // draw to be tried again.
        let frame = frame_of("one");
        let mut rig = Rig::showing(&frame);
        let marked = rig.clock.peek();
        rig.handle.mark_dirty();
        rig.clock.advance(10);
        rig.render.renderer_mut().fail_next_present();
        let tried = rig.clock.peek();
        assert_eq!(rig.render.step(), Step::Wait(Some(tried + REFRESH)));
        rig.clock.advance(REFRESH);
        let entry = rig.drew();
        // The frame shown again, answering the mark as it was stamped.
        assert_eq!(entry.input_ns, marked);
        assert_eq!(rig.requests(), 3);
        assert!(Arc::ptr_eq(
            &rig.render.renderer().requests()[2].frame,
            &frame
        ));
        // And the mark is served once.
        rig.clock.advance(REFRESH);
        assert_eq!(rig.render.step(), Step::Wait(None));
    }

    #[test]
    fn a_failed_present_keeps_a_deadline_that_had_come_to_serve() {
        // A deadline and nothing else.
        let mut rig = Rig::showing(&frame_of("one"));
        let deadline = rig.clock.peek() + 5;
        rig.handle.animate_at(deadline);
        rig.clock.set(deadline + 5);
        rig.render.renderer_mut().fail_next_present();
        let tried = rig.clock.peek();
        assert_eq!(rig.render.step(), Step::Wait(Some(tried + REFRESH)));
        rig.clock.advance(REFRESH);
        let entry = rig.drew();
        assert_eq!(entry.input_ns, deadline);
        assert_eq!(rig.requests(), 3);
        // And the deadline is served once.
        rig.clock.advance(REFRESH);
        assert_eq!(rig.render.step(), Step::Wait(None));
    }

    #[test]
    fn every_drawn_frame_has_an_entry_with_its_three_stamps() {
        // A clock that moves on a nanosecond at every reading, and a
        // renderer that takes 250 more to draw.
        let clock = FakeClock::stepping(1);
        let mut rig = rig_on(clock.clone());
        *rig.render.renderer_mut() = RecordingRenderer::new().taking(clock, 250);
        let mut stamps = Vec::new();
        for text in ["one", "two", "three"] {
            let stamp = rig.clock.now_ns();
            stamps.push(stamp);
            rig.handle.submit(frame_of(text), Some(stamp));
            let entry = rig.drew();
            assert_eq!(entry.input_ns, stamp);
            assert!(entry.input_ns < entry.draw_ns, "{entry:?}");
            assert!(entry.draw_ns + 250 <= entry.present_ns, "{entry:?}");
            rig.clock.advance(REFRESH);
        }
        let journal = rig.handle.journal();
        assert_eq!(journal.len(), 3);
        let serials: Vec<u64> = journal.iter().map(|entry| entry.serial).collect();
        assert_eq!(serials, vec![1, 2, 3]);
        let inputs: Vec<u64> = journal.iter().map(|entry| entry.input_ns).collect();
        assert_eq!(inputs, stamps);
        // An idle stretch adds none.
        rig.clock.advance(1_000_000_000);
        assert_eq!(rig.render.step(), Step::Wait(None));
        assert_eq!(rig.handle.journal(), journal);
    }

    #[test]
    fn the_counters_add_up_what_each_presented_draw_cost() {
        let mut rig = rig();
        let mut rebuilt = 0;
        for text in ["one\ntwo", "one\ntwo\nthree", "four"] {
            rig.handle.submit(frame_of(text), None);
            let entry = rig.drew();
            rebuilt += entry.rows_rebuilt;
            rig.clock.advance(REFRESH);
        }
        let counters = rig.handle.counters();
        assert_eq!(counters.draws, 3);
        assert_eq!(counters.rows_rebuilt, rebuilt);
        assert!(rebuilt > 0);
    }

    #[test]
    fn the_counters_say_how_many_entries_the_journal_let_go() {
        // One draw, and then as many as the journal keeps: none let go.
        let mut rig = Rig::showing(&frame_of("one"));
        let mut redraw = |times: usize| {
            for _ in 0..times {
                rig.handle.mark_dirty();
                rig.drew();
                rig.clock.advance(REFRESH);
            }
            (rig.handle.counters(), rig.handle.journal())
        };
        let (counters, kept) = redraw(JOURNAL_CAPACITY - 1);
        assert_eq!(kept.len() as u64, counters.draws);
        assert_eq!(counters.journal_dropped, 0);
        // Ten more: the journal keeps the last of them, and the counters
        // say how many presented frames have no entry any more.
        let (counters, kept) = redraw(10);
        assert_eq!(counters.journal_dropped, 10);
        assert_eq!(kept.len() as u64 + counters.journal_dropped, counters.draws);
        assert_eq!(kept.first().map(|entry| entry.serial), Some(11));
    }

    #[test]
    fn the_refresh_interval_is_the_one_last_set() {
        let park = Arc::new(RecordingPark::new());
        let clock = FakeClock::new();
        let (mut render, handle) = RenderLoop::new(
            RecordingRenderer::new(),
            Arc::new(clock.clone()),
            park,
            TARGET,
        );
        handle.submit(frame_of("one"), None);
        let Step::Drew(first) = render.step() else {
            panic!("the loop did not draw");
        };
        // Before any is set, the default.
        handle.mark_dirty();
        assert_eq!(
            render.step(),
            Step::Wait(Some(first.draw_ns + DEFAULT_REFRESH_NS))
        );
        handle.set_refresh(REFRESH);
        assert_eq!(render.step(), Step::Wait(Some(first.draw_ns + REFRESH)));
    }

    #[test]
    fn every_word_left_wakes_the_render_thread() {
        let rig = rig();
        let before = rig.park.notifications();
        rig.handle.submit(frame_of("one"), None);
        rig.handle.mark_dirty();
        rig.handle.resize(Target {
            width: 800,
            ..TARGET
        });
        rig.handle.animate_at(50);
        rig.handle.set_refresh(REFRESH);
        rig.handle.stop();
        assert_eq!(rig.park.notifications(), before + 6);
        // The fake park keeps the waits it is asked for.
        rig.park.wait(Some(5));
        rig.park.wait(None);
        assert_eq!(rig.park.waits(), vec![Some(5), None]);
    }

    #[test]
    fn a_stopped_loop_steps_no_more() {
        let mut rig = rig();
        let clone = rig.handle.clone();
        rig.handle.submit(frame_of("one"), None);
        clone.stop();
        assert_eq!(rig.render.step(), Step::Stopped);
        assert_eq!(rig.render.step(), Step::Stopped);
        assert_eq!(rig.requests(), 0);
    }

    #[test]
    fn a_running_loop_waits_as_each_step_says_and_gives_its_renderer_back_when_stopped() {
        let rig = rig();
        rig.handle.submit(frame_of("one"), None);
        // The script, run on the loop's own thread at each wait. After the
        // first draw there is nothing to do: a mark is made, within the
        // refresh of that draw.
        let handle = rig.handle.clone();
        rig.park.then(move || handle.mark_dirty());
        // The loop waits for the refresh: the time passes.
        let clock = rig.clock.clone();
        rig.park.then(move || clock.advance(REFRESH));
        // It draws again, and there is nothing to do: it is stopped.
        let handle = rig.handle.clone();
        rig.park.then(move || handle.stop());
        let begun = rig.clock.peek();
        let renderer = rig.render.run();
        assert_eq!(rig.park.waits(), vec![None, Some(begun + REFRESH), None]);
        assert_eq!(renderer.requests().len(), 2);
        assert_eq!(rig.handle.counters().draws, 2);
    }

    /// A real park on `clock`.
    fn condvar_park(clock: &FakeClock) -> Arc<CondvarPark> {
        Arc::new(CondvarPark::new(Arc::new(clock.clone())))
    }

    /// Begins a wait on `park` on another thread: what receives a word
    /// once the wait has returned.
    fn waiting(park: &Arc<CondvarPark>, until: Option<u64>) -> Receiver<()> {
        let (done, returned) = channel();
        let park = Arc::clone(park);
        std::thread::spawn(move || {
            park.wait(until);
            let _ = done.send(());
        });
        returned
    }

    /// Whether the wait behind `returned` has not returned, a little
    /// while on: it is still waiting, or its thread has yet to begin.
    fn still_waits(returned: &Receiver<()>) -> bool {
        returned.recv_timeout(Duration::from_millis(30)).is_err()
    }

    /// Whether the wait behind `returned` returns. The bound is only so
    /// that a wait that never ends fails its test and hangs nothing.
    fn ends(returned: &Receiver<()>) -> bool {
        returned.recv_timeout(Duration::from_secs(10)).is_ok()
    }

    #[test]
    fn a_wait_with_no_deadline_ends_only_when_it_is_notified() {
        let park = condvar_park(&FakeClock::new());
        let returned = waiting(&park, None);
        assert!(still_waits(&returned));
        park.notify();
        assert!(ends(&returned));
    }

    #[test]
    fn a_notification_made_before_a_wait_is_not_lost_and_wakes_one_wait() {
        let park = condvar_park(&FakeClock::new());
        park.notify();
        park.notify();
        assert!(ends(&waiting(&park, None)));
        // The two were one notification: the next wait has none to take.
        let returned = waiting(&park, None);
        assert!(still_waits(&returned));
        park.notify();
        assert!(ends(&returned));
    }

    #[test]
    fn a_wait_whose_deadline_has_passed_returns_at_once() {
        let clock = FakeClock::new();
        clock.set(5000);
        let park = condvar_park(&clock);
        assert!(ends(&waiting(&park, Some(4000))));
        assert!(ends(&waiting(&park, Some(5000))));
    }

    #[test]
    fn a_wait_ends_at_its_deadline_by_the_clock_it_was_given() {
        // Two milliseconds of the clock away, and nobody notifies.
        let clock = FakeClock::new();
        let park = condvar_park(&clock);
        assert!(ends(&waiting(&park, Some(clock.peek() + 2_000_000))));
    }

    /// An hour of `clock` from where it is: a deadline no test waits out,
    /// on a clock that does not move.
    fn an_hour_on(clock: &FakeClock) -> u64 {
        clock.peek() + 3_600_000_000_000
    }

    #[test]
    fn a_notification_made_before_a_wait_with_a_deadline_is_not_lost() {
        let clock = FakeClock::new();
        let park = condvar_park(&clock);
        let far = an_hour_on(&clock);
        park.notify();
        // The wait returns at once, an hour before its deadline.
        assert!(ends(&waiting(&park, Some(far))));
        // And it took the notification: the next wait has none to take.
        let returned = waiting(&park, None);
        assert!(still_waits(&returned));
        park.notify();
        assert!(ends(&returned));
    }

    #[test]
    fn a_wait_with_a_deadline_ahead_waits_and_is_woken_by_a_notification() {
        let clock = FakeClock::new();
        let park = condvar_park(&clock);
        let far = an_hour_on(&clock);
        // A wait with a deadline may end for no reason, as a condition
        // variable's may: one that does is begun again, so that a wait
        // that never lasts fails here and one stray wake-up does not.
        let lasting = (0..3).map(|_| waiting(&park, Some(far))).find(still_waits);
        let returned = lasting.expect("a wait with its deadline ahead that lasts");
        park.notify();
        assert!(ends(&returned));
    }

    /// The handle crosses to other threads; the loop moves to its own.
    #[test]
    fn a_handle_is_shared_between_threads_and_a_loop_is_sent_to_one() {
        fn shared<T: Clone + Send + Sync>() {}
        fn sent<T: Send>() {}
        shared::<RenderHandle>();
        sent::<RenderLoop<RecordingRenderer>>();
    }
}
