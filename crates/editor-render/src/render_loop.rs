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
//! # What a draw leaves behind
//!
//! One journal [`Entry`] for each draw that presented, and none otherwise.
//! Its `input_ns` is the oldest stamp among the demands the draw served: a
//! frame's stamp is its publisher's, or the time it was submitted when the
//! publisher gave none, and where a newer frame replaced one not yet drawn
//! the older stamp is kept; a dirty mark and a resize are stamped as they
//! are made; an animation by its deadline. Its `draw_ns` is read as the
//! draw begins and its `present_ns` when the renderer returns.
//!
//! A draw that does not present leaves its demands as they were, adds no
//! entry, counts as failed, and is tried again a refresh later.
//!
//! # Stepping and running
//!
//! [`RenderLoop::step`] takes one decision and makes at most one draw, and
//! never blocks: it says what it did or how long there is to wait. Tests
//! step a loop by hand on a [`FakeClock`](crate::clock::FakeClock).

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

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
#[derive(Debug, Default)]
pub struct RecordingPark {
    /// The deadline of each wait, in order.
    waits: Mutex<Vec<Option<u64>>>,
    /// How many times it was notified.
    notifications: AtomicU64,
}

impl RecordingPark {
    /// A park nobody has waited on.
    pub fn new() -> Self {
        Self::default()
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
    }

    fn notify(&self) {
        self.notifications.fetch_add(1, Ordering::SeqCst);
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
        let stamps = [
            pending.as_ref().map(|(_, stamp)| *stamp),
            dirty,
            due,
            resized,
        ];
        let draw_ns = shared.clock.now_ns();
        let input_ns = stamps.into_iter().flatten().min().unwrap_or(draw_ns);
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

    use editor_layout::Layout;
    use editor_layout::frame::Frame;
    use editor_layout::scene::{Rect, Scene};
    use editor_layout::shaper::fake::CellShaper;

    use super::{Park, RecordingPark, RenderHandle, RenderLoop, Step};
    use crate::clock::{Clock, FakeClock};
    use crate::fake::RecordingRenderer;
    use crate::journal::{Counters, Entry};
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

    /// The handle crosses to other threads; the loop moves to its own.
    #[test]
    fn a_handle_is_shared_between_threads_and_a_loop_is_sent_to_one() {
        fn shared<T: Clone + Send + Sync>() {}
        fn sent<T: Send>() {}
        shared::<RenderHandle>();
        sent::<RenderLoop<RecordingRenderer>>();
    }
}
