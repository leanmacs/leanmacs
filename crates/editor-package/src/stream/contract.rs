//! The stream port's own contract: the rules every [`StreamSource`] a
//! package's library reads keeps, as a check that takes children over,
//! pulls and writes them.
//!
//! It holds the published fake ([`ScriptedSource`]) and the real adapter
//! (the runtime's `Runtime` and `Child`, over any runtime's members) to the
//! same rules, so a package's tests on the fake see the child the runtime
//! hands it. [`check`] runs every property and answers the names of those
//! that fail. Each needs a child of a [`Scenario`], in the contract's own
//! terms, which the [`Ground`] opens: the scripted source scripts one, and
//! a ground over the core's runtime steps a child of the core's stream
//! source.
//!
//! **Not its properties:** framing (lines, bytes, `Content-Length`), the
//! bound and a job's pending read. They are the core's process service's
//! rules, pinned by `editor-service`'s stream contract and, through the
//! runtime's members, by the runtime's contract (`editor-package-library`'s
//! `CHILD_FRAMED`). A package's library is handed frames already made, so a
//! scripted child delivers frames as scripted.
//!
//! **A pull that never blocks is not allowed.** [`PULL_WAITS_FOR_DELIVERY`]
//! and [`CANCEL_REACHES_A_PARKED_PULL`] each wait for a pull parked with
//! nothing to deliver ([`Ground::wait_pulling`]); a source whose pull
//! answers at once never parks, and fails them. So the scripted child
//! parks, as the core's does.
//!
//! Every thread the check starts is scoped and joined before a property is
//! decided. Each wait is bounded only by the ground's hang guard
//! ([`Ground::deadline`]): a pull or write that does not answer by then
//! fails its property as a hang, and the check cancels its child
//! ([`Ground::cancel`]) so that the call returns and its thread is joined.
//! The parked interleavings are forced every time through
//! [`Ground::wait_pulling`], never by a sleep.
//!
//! # Where an addition goes
//!
//! A new rule is a named `pub const`, an entry of [`PROPERTIES`], a step of
//! [`check`], a [`Scenario`] for each child it needs, and each ground's
//! mapping of that scenario (the scripted source's, and
//! `editor-package-check`'s over the core's stream source).

use std::sync::mpsc;
use std::thread;

use editor_wait::HangGuard;

use super::{ChildStreams, Delivery, Ended, InputClosed, Pulled, Refused, StreamSource};
use crate::frame::Frames;

#[cfg(doc)]
use super::fake::ScriptedSource;

/// What [`check`] needs done that the port has no method for: a child
/// opened, a child cancelled, and whether a reader is parked in a pull.
pub trait Ground {
    /// The source checked.
    fn source(&self) -> &dyn StreamSource;

    /// Opens the child of `scenario` as a live streaming child, as a job
    /// does, and gives its number: `None` if it cannot. Its number is
    /// never [`UNUSED`].
    fn open(&self, scenario: Scenario) -> Option<u64>;

    /// Cancels the child `child`, as the job's end does: the process
    /// service stays the owner of the child, so a cancel is the ground's,
    /// not the port's.
    fn cancel(&self, child: u64);

    /// Waits until a reader of the child `child` is parked in a pull with
    /// nothing to deliver, up to [`Ground::deadline`], and says whether one
    /// was: a hang guard, for a park that must come.
    fn wait_pulling(&self, child: u64) -> bool;

    /// hang guard: each event the check waits for with it, a pull's or a
    /// write's return or a reader's park, which must come; only a hang
    /// reaches the bound, and the property then fails as a hang.
    fn deadline(&self) -> HangGuard;
}

/// A child the check needs, in the contract's terms.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Scenario {
    /// Writes `one` and `two` and exits 2. Lines, no input.
    TwoLines,
    /// Writes `taken` and exits 0. Lines, no input.
    OneLine,
    /// Writes nothing until it reads a line; then writes it back and exits
    /// 0. Lines, with an input.
    AwaitsLine,
    /// Writes nothing and never ends until it is cancelled. Lines, with an
    /// input.
    Silent,
}

impl Scenario {
    /// Every scenario.
    pub const ALL: [Self; 4] = [
        Self::TwoLines,
        Self::OneLine,
        Self::AwaitsLine,
        Self::Silent,
    ];
}

/// A number no ground gives a child.
pub const UNUSED: u64 = u64::MAX - 1;

/// [`Scenario::TwoLines`]'s pulls give `one`, `two` in order and exactly
/// one end, `Exited { code: 2 }`, in the last delivery; the pull after it
/// answers [`Pulled::Cancelled`].
pub const DELIVERED_IN_ORDER_THEN_END: &str =
    "a child's frames arrive in order, its one end in its last delivery, then cancelled";
/// A pull of [`Scenario::AwaitsLine`], parked with nothing to deliver,
/// answers the delivery a write from another thread makes deliverable,
/// never [`Pulled::Cancelled`], and the child's exit follows.
pub const PULL_WAITS_FOR_DELIVERY: &str =
    "a pull with nothing to deliver parks until something is deliverable";
/// A pull of [`Scenario::Silent`], parked, answers [`Pulled::Cancelled`]
/// once the child is cancelled, and so does every pull after.
pub const CANCEL_REACHES_A_PARKED_PULL: &str =
    "a cancel of the child reaches a pull parked on it, which answers cancelled";
/// A second take-over of a child taken over is refused as
/// [`Refused::Taken`].
pub const REFUSED_TAKEN: &str = "a second take-over is refused as taken";
/// A number never opened, and a child whose last delivery was pulled, are
/// refused as [`Refused::NoSuchChild`].
pub const REFUSED_NO_SUCH_CHILD: &str =
    "an unknown child, and one whose last delivery was pulled, is no such child";
/// A write to [`Scenario::OneLine`], which has no input, is refused as
/// [`InputClosed`] with words, and its line and exit still arrive.
pub const WRITE_WITHOUT_INPUT_REFUSED: &str =
    "a write to a child with no input is refused as input closed, with words";
/// After [`Scenario::AwaitsLine`]'s last delivery, a write is refused as
/// [`InputClosed`] with words, though it had an input.
pub const WRITE_AFTER_END_REFUSED: &str =
    "a write after the last delivery was pulled is refused as input closed, with words";

/// Every property, by name, in the order [`check`] runs them.
pub const PROPERTIES: [&str; 7] = [
    DELIVERED_IN_ORDER_THEN_END,
    PULL_WAITS_FOR_DELIVERY,
    CANCEL_REACHES_A_PARKED_PULL,
    REFUSED_TAKEN,
    REFUSED_NO_SUCH_CHILD,
    WRITE_WITHOUT_INPUT_REFUSED,
    WRITE_AFTER_END_REFUSED,
];

/// Holds the source of `ground` to the contract, and answers the names of
/// the properties that fail: none when it keeps them all.
pub fn check(ground: &impl Ground) -> Vec<&'static str> {
    let check = Check { ground };
    let results = [
        (DELIVERED_IN_ORDER_THEN_END, check.delivered_in_order()),
        (PULL_WAITS_FOR_DELIVERY, check.pull_waits()),
        (CANCEL_REACHES_A_PARKED_PULL, check.cancel_reaches()),
        (REFUSED_TAKEN, check.refused_taken()),
        (REFUSED_NO_SUCH_CHILD, check.refused_no_such_child()),
        (WRITE_WITHOUT_INPUT_REFUSED, check.write_without_input()),
        (WRITE_AFTER_END_REFUSED, check.write_after_end()),
    ];
    results
        .into_iter()
        .filter_map(|(name, holds)| (!holds.unwrap_or(false)).then_some(name))
        .collect()
}

/// A child taken over.
type Streams = Box<dyn ChildStreams>;

/// A check in progress.
struct Check<'a, G> {
    /// The ground.
    ground: &'a G,
}

impl<G: Ground> Check<'_, G> {
    /// Opens `scenario`'s child and takes it over.
    fn opened(&self, scenario: Scenario) -> Option<(u64, Streams)> {
        let child = self.ground.open(scenario)?;
        Some((child, self.ground.source().take_over(child).ok()?))
    }

    /// What `call` answers, run on a scoped thread of the check's and
    /// waited for up to the deadline: `None` if it does not answer by then
    /// or panics. A call that has not answered by then has its child
    /// cancelled, so that it returns, and its thread is joined either way.
    fn bounded<T: Send>(&self, child: u64, call: impl FnOnce() -> T + Send) -> Option<T> {
        thread::scope(|scope| {
            let (sender, answer) = mpsc::channel();
            let calling = thread::Builder::new()
                .name("package-stream-contract".into())
                .spawn_scoped(scope, move || {
                    let _ = sender.send(call());
                })
                .ok()?;
            let answered = editor_wait::recv(&answer, self.ground.deadline()).ok();
            if answered.is_none() {
                self.ground.cancel(child);
            }
            let _ = calling.join();
            answered
        })
    }

    /// The next pull of `streams`, the child `child`.
    fn pull(&self, child: u64, streams: &dyn ChildStreams) -> Option<Pulled> {
        self.bounded(child, || streams.pull())
    }

    /// A write of `bytes` to `streams`, the child `child`.
    fn write(
        &self,
        child: u64,
        streams: &dyn ChildStreams,
        bytes: &[u8],
    ) -> Option<Result<(), InputClosed>> {
        self.bounded(child, || streams.write(bytes.to_vec()))
    }

    /// Every delivery of `streams` to its last: `None` if a pull does not
    /// answer, or answers cancelled, first.
    fn to_the_end(&self, child: u64, streams: &dyn ChildStreams) -> Option<Vec<Delivery>> {
        let mut deliveries = Vec::new();
        loop {
            let Pulled::Delivered(delivery) = self.pull(child, streams)? else {
                return None;
            };
            let ended = delivery.ended.is_some();
            deliveries.push(delivery);
            if ended {
                return Some(deliveries);
            }
        }
    }

    /// A pull of `streams` started on a scoped thread, then `meanwhile` on
    /// the check's thread once [`Ground::wait_pulling`] has said whether
    /// the pull parked: whether it parked, what `meanwhile` gave and what
    /// the pull answered (`None` past the deadline).
    fn beside_a_parked_pull<T>(
        &self,
        child: u64,
        streams: &dyn ChildStreams,
        meanwhile: impl FnOnce() -> T,
    ) -> Option<(bool, T, Option<Pulled>)> {
        thread::scope(|scope| {
            let (sender, answer) = mpsc::channel();
            let pulling = thread::Builder::new()
                .name("package-stream-contract".into())
                .spawn_scoped(scope, move || {
                    let _ = sender.send(streams.pull());
                })
                .ok()?;
            let parked = self.ground.wait_pulling(child);
            let done = meanwhile();
            let pulled = editor_wait::recv(&answer, self.ground.deadline()).ok();
            if pulled.is_none() {
                self.ground.cancel(child);
            }
            let _ = pulling.join();
            Some((parked, done, pulled))
        })
    }

    /// [`DELIVERED_IN_ORDER_THEN_END`].
    fn delivered_in_order(&self) -> Option<bool> {
        let (child, streams) = self.opened(Scenario::TwoLines)?;
        let deliveries = self.to_the_end(child, &*streams)?;
        let after = self.pull(child, &*streams)?;
        let ends = deliveries
            .iter()
            .filter(|delivery| delivery.ended.is_some())
            .count();
        Some(
            lines(&deliveries) == Some(vec![b"one".to_vec(), b"two".to_vec()])
                && ends == 1
                && last_end(&deliveries) == Some(Ended::Exited { code: 2 })
                && after == Pulled::Cancelled,
        )
    }

    /// [`PULL_WAITS_FOR_DELIVERY`].
    fn pull_waits(&self) -> Option<bool> {
        let (child, streams) = self.opened(Scenario::AwaitsLine)?;
        let (parked, written, first) =
            self.beside_a_parked_pull(child, &*streams, || self.write(child, &*streams, b"go\n"))?;
        let Some(Pulled::Delivered(first)) = first else {
            return Some(false);
        };
        let mut deliveries = vec![first];
        if deliveries[0].ended.is_none() {
            deliveries.extend(self.to_the_end(child, &*streams)?);
        }
        Some(
            parked
                && written == Some(Ok(()))
                && lines(&deliveries) == Some(vec![b"go".to_vec()])
                && last_end(&deliveries) == Some(Ended::Exited { code: 0 }),
        )
    }

    /// [`CANCEL_REACHES_A_PARKED_PULL`].
    fn cancel_reaches(&self) -> Option<bool> {
        let (child, streams) = self.opened(Scenario::Silent)?;
        let (parked, (), first) =
            self.beside_a_parked_pull(child, &*streams, || self.ground.cancel(child))?;
        let after = self.pull(child, &*streams)?;
        Some(parked && first == Some(Pulled::Cancelled) && after == Pulled::Cancelled)
    }

    /// [`REFUSED_TAKEN`].
    fn refused_taken(&self) -> Option<bool> {
        let (child, _streams) = self.opened(Scenario::OneLine)?;
        let again = self.ground.source().take_over(child);
        Some(matches!(again, Err(Refused::Taken)))
    }

    /// [`REFUSED_NO_SUCH_CHILD`].
    fn refused_no_such_child(&self) -> Option<bool> {
        let unknown = self.ground.source().take_over(UNUSED);
        let (child, streams) = self.opened(Scenario::OneLine)?;
        self.to_the_end(child, &*streams)?;
        let ended = self.ground.source().take_over(child);
        Some(
            matches!(unknown, Err(Refused::NoSuchChild))
                && matches!(ended, Err(Refused::NoSuchChild)),
        )
    }

    /// [`WRITE_WITHOUT_INPUT_REFUSED`].
    fn write_without_input(&self) -> Option<bool> {
        let (child, streams) = self.opened(Scenario::OneLine)?;
        let written = self.write(child, &*streams, b"x\n")?;
        let deliveries = self.to_the_end(child, &*streams)?;
        Some(
            refused_with_words(&written)
                && lines(&deliveries) == Some(vec![b"taken".to_vec()])
                && last_end(&deliveries) == Some(Ended::Exited { code: 0 }),
        )
    }

    /// [`WRITE_AFTER_END_REFUSED`].
    fn write_after_end(&self) -> Option<bool> {
        let (child, streams) = self.opened(Scenario::AwaitsLine)?;
        let written = self.write(child, &*streams, b"go\n")?;
        let deliveries = self.to_the_end(child, &*streams)?;
        let after = self.write(child, &*streams, b"again\n")?;
        Some(
            written == Ok(())
                && last_end(&deliveries) == Some(Ended::Exited { code: 0 })
                && refused_with_words(&after),
        )
    }
}

/// Standard output's lines across `deliveries`, in order: `None` if one is
/// framed otherwise.
fn lines(deliveries: &[Delivery]) -> Option<Vec<Vec<u8>>> {
    let mut lines = Vec::new();
    for delivery in deliveries {
        let Frames::Lines(out) = &delivery.out else {
            return None;
        };
        lines.extend(out.iter().cloned());
    }
    Some(lines)
}

/// How the last of `deliveries` says the child ended.
fn last_end(deliveries: &[Delivery]) -> Option<Ended> {
    deliveries.last()?.ended.clone()
}

/// Whether `written` is a refusal as input closed, with words.
fn refused_with_words(written: &Result<(), InputClosed>) -> bool {
    matches!(written, Err(InputClosed(words)) if !words.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_properties_are_seven_and_each_is_named_once() {
        let mut names = PROPERTIES.to_vec();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), 7);
    }
}
